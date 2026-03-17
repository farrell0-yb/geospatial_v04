
-- ============================================================================
--
-- Purpose  : Define a custom 'geometry' composite type for YugabyteDB YSQL,
--            plus GeoServer compatibility layer (PostGIS metadata functions,
--            WKB encoding, bbox operator, and ST_Extent aggregate).
--
--            This is a lightweight geometry type modeled after PostGIS's
--            geometry column type, but implemented as a pure SQL composite
--            type requiring no C extensions.
--
--            Internally it stores parallel arrays of lon[] and lat[] vertices.
--            A point is a single-element array.  A polygon is 3+ vertices
--            listed in order (CW or CCW); explicit closing is not required.
--
-- Conventions:
--   X = longitude,  Y = latitude   (matches PostGIS ST_X / ST_Y)
--
-- ============================================================================

-- Drop dependents first (functions that use the type) so the
-- CREATE TYPE can run cleanly on repeated executions.
--
DROP TYPE IF EXISTS geometry CASCADE;

CREATE TYPE geometry AS (
   lon   double precision[],
   lat   double precision[]
);


-- ============================================================================
-- Constructor functions  (PostGIS-compatible names)
-- ============================================================================

-- ------------------------------------------------------------
-- ST_MakePoint(lon, lat)
--   Creates a geometry representing a single point.
--
-- Example:
--   SELECT ST_MakePoint(-111.97, 40.52);
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_MakePoint(
   p_lon double precision,
   p_lat double precision
)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ROW(ARRAY[p_lon], ARRAY[p_lat])::geometry;
$$;


-- ------------------------------------------------------------
-- ST_MakePolygon(lon[], lat[])
--   Creates a geometry from parallel vertex arrays.
--
-- Example:
--   SELECT ST_MakePolygon(
--       ARRAY[-112.0, -111.9, -111.9, -112.0],
--       ARRAY[40.5,   40.5,   40.55,  40.55]
--   );
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_MakePolygon(
   p_lon double precision[],
   p_lat double precision[]
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   IF coalesce(array_length(p_lon, 1), 0) < 1 THEN
      RAISE EXCEPTION 'ST_MakePolygon: lon array must not be empty';
   END IF;
   IF array_length(p_lon, 1) <> coalesce(array_length(p_lat, 1), 0) THEN
      RAISE EXCEPTION 'ST_MakePolygon: lon[] and lat[] must be same length';
   END IF;
   RETURN ROW(p_lon, p_lat)::geometry;
END;
$$;


-- ------------------------------------------------------------
-- ST_MakeEnvelope(lon_min, lat_min, lon_max, lat_max)
--   Creates a geometry rectangle from bounding-box corners.
--   Vertex order: SW, SE, NE, NW  (counter-clockwise).
--
-- Example:
--   SELECT ST_MakeEnvelope(-112.0, 40.5, -111.9, 40.55);
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_MakeEnvelope(
   p_lon_min double precision,
   p_lat_min double precision,
   p_lon_max double precision,
   p_lat_max double precision
)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ROW(
      ARRAY[p_lon_min, p_lon_max, p_lon_max, p_lon_min],
      ARRAY[p_lat_min, p_lat_min, p_lat_max, p_lat_max]
   )::geometry;
$$;

-- 5-argument version (SRID parameter accepted but ignored; always 4326)
-- GeoServer calls: ST_MakeEnvelope(xmin, ymin, xmax, ymax, 4326)
CREATE OR REPLACE FUNCTION ST_MakeEnvelope(
   p_lon_min double precision,
   p_lat_min double precision,
   p_lon_max double precision,
   p_lat_max double precision,
   p_srid    integer
)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_MakeEnvelope(p_lon_min, p_lat_min, p_lon_max, p_lat_max);
$$;


-- ============================================================================
-- GeoServer PostGIS compatibility — version detection
-- ============================================================================

CREATE OR REPLACE FUNCTION PostGIS_Version()
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
   SELECT '2.1 USE_GEOS=0';
$$;

CREATE OR REPLACE FUNCTION PostGIS_Lib_Version()
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
   SELECT '2.1.8';
$$;

CREATE OR REPLACE FUNCTION PostGIS_Full_Version()
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
   SELECT 'POSTGIS="2.1.8" [EXTENSION] PGSQL="150" (YugabyteDB YSQL shim, pure PL/pgSQL, no GEOS)';
$$;

CREATE OR REPLACE FUNCTION PostGIS_GEOS_Version()
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
   SELECT NULL::text;
$$;


-- ============================================================================
-- GeoServer PostGIS compatibility — SRID functions
--
-- All data is EPSG:4326.  These functions accept but ignore SRID arguments.
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_SRID(p_geom geometry)
RETURNS integer
LANGUAGE sql IMMUTABLE
AS $$
   SELECT 4326;
$$;

CREATE OR REPLACE FUNCTION ST_SetSRID(p_geom geometry, p_srid integer)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT p_geom;
$$;

CREATE OR REPLACE FUNCTION ST_Transform(p_geom geometry, p_srid integer)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT p_geom;
$$;


-- ============================================================================
-- GeoServer PostGIS compatibility — ST_AsBinary (WKB encoding)
--
-- Encodes our geometry composite type to OGC Well-Known Binary (WKB).
-- Uses little-endian (NDR) byte order.
--
-- WKB Point:   01 01000000 <lon_f64_le> <lat_f64_le>       (21 bytes)
-- WKB Polygon: 01 03000000 01000000 <npts+1(4)> <coords>
-- WKB Line:    01 02000000 <npts(4)> <coords>
--
-- GeoServer reads geometries via ST_AsBinary().
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_AsBinary(p_geom geometry)
RETURNS bytea
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   wkb bytea;
   i integer;
   -- Little-endian helpers: we build bytea by concatenation
   le_byte_order constant bytea := '\x01';
   wkb_point   constant bytea := '\x01000000';
   wkb_line    constant bytea := '\x02000000';
   wkb_polygon constant bytea := '\x03000000';
BEGIN
   IF n = 0 THEN
      -- Empty geometry collection: byte_order + type(7) + 0 geoms
      RETURN le_byte_order || '\x07000000' || '\x00000000';
   END IF;

   IF n = 1 THEN
      -- POINT
      wkb := le_byte_order || wkb_point;
      -- Append lon as float8 little-endian
      wkb := wkb || lm__float8_to_le_bytea((p_geom).lon[1]);
      wkb := wkb || lm__float8_to_le_bytea((p_geom).lat[1]);
      RETURN wkb;
   END IF;

   IF n = 2 THEN
      -- LINESTRING
      wkb := le_byte_order || wkb_line;
      wkb := wkb || lm__int32_to_le_bytea(n);
      FOR i IN 1..n LOOP
         wkb := wkb || lm__float8_to_le_bytea((p_geom).lon[i]);
         wkb := wkb || lm__float8_to_le_bytea((p_geom).lat[i]);
      END LOOP;
      RETURN wkb;
   END IF;

   -- POLYGON (close the ring: n+1 points)
   wkb := le_byte_order || wkb_polygon;
   wkb := wkb || lm__int32_to_le_bytea(1);       -- 1 ring
   wkb := wkb || lm__int32_to_le_bytea(n + 1);   -- n vertices + closing
   FOR i IN 1..n LOOP
      wkb := wkb || lm__float8_to_le_bytea((p_geom).lon[i]);
      wkb := wkb || lm__float8_to_le_bytea((p_geom).lat[i]);
   END LOOP;
   -- Close the ring
   wkb := wkb || lm__float8_to_le_bytea((p_geom).lon[1]);
   wkb := wkb || lm__float8_to_le_bytea((p_geom).lat[1]);
   RETURN wkb;
END;
$$;


-- Internal helpers for WKB byte encoding
CREATE OR REPLACE FUNCTION lm__float8_to_le_bytea(val double precision)
RETURNS bytea
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   be bytea;
   le bytea := '\x0000000000000000'::bytea;
BEGIN
   -- float8send returns big-endian 8 bytes
   be := decode(lpad(to_hex(
      -- Use bit manipulation via int8 reinterpretation
      -- PG provides no direct float8->bytea, so we use a workaround
      0), 16, '0'), 'hex');
   -- Actually, use the set_byte approach with overlay
   -- The simplest portable approach: send through text conversion
   -- and use the built-in float8send
   be := (SELECT float8send(val));
   -- Reverse bytes for little-endian
   le := set_byte(le, 0, get_byte(be, 7));
   le := set_byte(le, 1, get_byte(be, 6));
   le := set_byte(le, 2, get_byte(be, 5));
   le := set_byte(le, 3, get_byte(be, 4));
   le := set_byte(le, 4, get_byte(be, 3));
   le := set_byte(le, 5, get_byte(be, 2));
   le := set_byte(le, 6, get_byte(be, 1));
   le := set_byte(le, 7, get_byte(be, 0));
   RETURN le;
END;
$$;

CREATE OR REPLACE FUNCTION lm__int32_to_le_bytea(val integer)
RETURNS bytea
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   le bytea := '\x00000000'::bytea;
BEGIN
   le := set_byte(le, 0, (val       ) & 255);
   le := set_byte(le, 1, (val >>  8 ) & 255);
   le := set_byte(le, 2, (val >> 16 ) & 255);
   le := set_byte(le, 3, (val >> 24 ) & 255);
   RETURN le;
END;
$$;


-- ============================================================================
-- GeoServer PostGIS compatibility — && operator (bbox overlap)
--
-- GeoServer emits:  "geom" && ST_MakeEnvelope(...)
-- This operator tests bounding-box overlap between two geometries.
-- ============================================================================

CREATE OR REPLACE FUNCTION geometry_overlaps_bbox(a geometry, b geometry)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   a_xmin double precision; a_xmax double precision;
   a_ymin double precision; a_ymax double precision;
   b_xmin double precision; b_xmax double precision;
   b_ymin double precision; b_ymax double precision;
   a_lon double precision[] := (a).lon;
   a_lat double precision[] := (a).lat;
   b_lon double precision[] := (b).lon;
   b_lat double precision[] := (b).lat;
   na integer := coalesce(array_length(a_lon, 1), 0);
   nb integer := coalesce(array_length(b_lon, 1), 0);
   v double precision; i integer;
BEGIN
   IF na = 0 OR nb = 0 THEN RETURN false; END IF;

   -- Compute bbox of A
   a_xmin := a_lon[1]; a_xmax := a_lon[1];
   a_ymin := a_lat[1]; a_ymax := a_lat[1];
   FOR i IN 2..na LOOP
      v := a_lon[i]; IF v < a_xmin THEN a_xmin := v; END IF; IF v > a_xmax THEN a_xmax := v; END IF;
      v := a_lat[i]; IF v < a_ymin THEN a_ymin := v; END IF; IF v > a_ymax THEN a_ymax := v; END IF;
   END LOOP;

   -- Compute bbox of B
   b_xmin := b_lon[1]; b_xmax := b_lon[1];
   b_ymin := b_lat[1]; b_ymax := b_lat[1];
   FOR i IN 2..nb LOOP
      v := b_lon[i]; IF v < b_xmin THEN b_xmin := v; END IF; IF v > b_xmax THEN b_xmax := v; END IF;
      v := b_lat[i]; IF v < b_ymin THEN b_ymin := v; END IF; IF v > b_ymax THEN b_ymax := v; END IF;
   END LOOP;

   -- AABB overlap test
   RETURN NOT (a_xmax < b_xmin OR a_xmin > b_xmax
            OR a_ymax < b_ymin OR a_ymin > b_ymax);
END;
$$;

-- Drop operator if exists (for clean re-runs)
DROP OPERATOR IF EXISTS && (geometry, geometry);

CREATE OPERATOR && (
   LEFTARG    = geometry,
   RIGHTARG   = geometry,
   FUNCTION   = geometry_overlaps_bbox,
   COMMUTATOR = &&
);


-- ============================================================================
-- GeoServer PostGIS compatibility — ST_Extent aggregate
--
-- GeoServer calls: SELECT ST_Extent(geom) FROM my_table;
-- Returns the bounding box of all geometries as a geometry rectangle.
-- ============================================================================

CREATE OR REPLACE FUNCTION lm__st_extent_transfn(
   state geometry,
   val   geometry
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((val).lon, 1), 0);
   s_xmin double precision; s_xmax double precision;
   s_ymin double precision; s_ymax double precision;
   v_xmin double precision; v_xmax double precision;
   v_ymin double precision; v_ymax double precision;
   v double precision; i integer;
BEGIN
   IF n = 0 THEN RETURN state; END IF;

   -- Compute bbox of val
   v_xmin := (val).lon[1]; v_xmax := (val).lon[1];
   v_ymin := (val).lat[1]; v_ymax := (val).lat[1];
   FOR i IN 2..n LOOP
      v := (val).lon[i]; IF v < v_xmin THEN v_xmin := v; END IF; IF v > v_xmax THEN v_xmax := v; END IF;
      v := (val).lat[i]; IF v < v_ymin THEN v_ymin := v; END IF; IF v > v_ymax THEN v_ymax := v; END IF;
   END LOOP;

   IF state IS NULL OR coalesce(array_length((state).lon, 1), 0) = 0 THEN
      RETURN ST_MakeEnvelope(v_xmin, v_ymin, v_xmax, v_ymax);
   END IF;

   -- Expand existing state bbox
   s_xmin := (state).lon[1]; -- SW lon
   s_ymin := (state).lat[1]; -- SW lat
   s_xmax := (state).lon[2]; -- SE lon (= NE lon)
   s_ymax := (state).lat[3]; -- NE lat

   RETURN ST_MakeEnvelope(
      LEAST(s_xmin, v_xmin),
      LEAST(s_ymin, v_ymin),
      GREATEST(s_xmax, v_xmax),
      GREATEST(s_ymax, v_ymax)
   );
END;
$$;

DROP AGGREGATE IF EXISTS ST_Extent(geometry);

CREATE AGGREGATE ST_Extent(geometry) (
   SFUNC    = lm__st_extent_transfn,
   STYPE    = geometry
);


-- ============================================================================
-- GeoServer PostGIS compatibility — additional functions
--
-- These are functions GeoServer's PostGIS data store plugin calls during
-- connection, layer discovery, feature retrieval, and WMS rendering.
-- ============================================================================

-- ------------------------------------------------------------
-- ST_AsEWKB(geometry)
--   GeoServer's primary encoding for geometry columns in SELECT.
--   EWKB = WKB with embedded SRID.  We prepend SRID 4326 to the
--   standard WKB output.
--
--   EWKB layout (little-endian):
--     byte_order(1) | wkb_type_with_srid_flag(4) | srid(4) | coords...
--   The SRID flag is bit 0x20000000 OR'd into the type integer.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_AsEWKB(p_geom geometry)
RETURNS bytea
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n   integer := coalesce(array_length((p_geom).lon, 1), 0);
   wkb bytea;
   i   integer;
   le_byte_order constant bytea := '\x01';
   -- WKB type integers with SRID flag (0x20000000) set, little-endian
   ewkb_point   constant bytea := '\x01000020';  -- 0x20000001
   ewkb_line    constant bytea := '\x02000020';  -- 0x20000002
   ewkb_polygon constant bytea := '\x03000020';  -- 0x20000003
   srid_bytes   constant bytea := '\xa6100000';   -- 4326 as LE int32
BEGIN
   IF n = 0 THEN
      RETURN le_byte_order || '\x07000020' || srid_bytes || '\x00000000';
   END IF;

   IF n = 1 THEN
      wkb := le_byte_order || ewkb_point || srid_bytes;
      wkb := wkb || lm__float8_to_le_bytea((p_geom).lon[1]);
      wkb := wkb || lm__float8_to_le_bytea((p_geom).lat[1]);
      RETURN wkb;
   END IF;

   IF n = 2 THEN
      wkb := le_byte_order || ewkb_line || srid_bytes;
      wkb := wkb || lm__int32_to_le_bytea(n);
      FOR i IN 1..n LOOP
         wkb := wkb || lm__float8_to_le_bytea((p_geom).lon[i]);
         wkb := wkb || lm__float8_to_le_bytea((p_geom).lat[i]);
      END LOOP;
      RETURN wkb;
   END IF;

   -- POLYGON
   wkb := le_byte_order || ewkb_polygon || srid_bytes;
   wkb := wkb || lm__int32_to_le_bytea(1);       -- 1 ring
   wkb := wkb || lm__int32_to_le_bytea(n + 1);   -- n vertices + closing
   FOR i IN 1..n LOOP
      wkb := wkb || lm__float8_to_le_bytea((p_geom).lon[i]);
      wkb := wkb || lm__float8_to_le_bytea((p_geom).lat[i]);
   END LOOP;
   wkb := wkb || lm__float8_to_le_bytea((p_geom).lon[1]);
   wkb := wkb || lm__float8_to_le_bytea((p_geom).lat[1]);
   RETURN wkb;
END;
$$;


-- ------------------------------------------------------------
-- ST_Force2D(geometry)
--   GeoServer wraps geometry reads: ST_Force2D(geom)
--   Our geometry is always 2D, so this is an identity function.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_Force2D(p_geom geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT p_geom;
$$;

-- Legacy name (PostGIS < 2.1)
CREATE OR REPLACE FUNCTION ST_Force_2D(p_geom geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT p_geom;
$$;


-- ------------------------------------------------------------
-- ST_NDims(geometry)
--   GeoServer fallback for dimension detection.
--   Our geometry is always 2D.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_NDims(p_geom geometry)
RETURNS integer
LANGUAGE sql IMMUTABLE
AS $$
   SELECT 2;
$$;


-- ------------------------------------------------------------
-- ST_GeomFromText(wkt, srid)
--   2-argument version.  GeoServer passes:
--     ST_GeomFromText('POINT(-111.97 40.52)', 4326)
--   We accept the SRID but ignore it (always 4326).
--   Depends on the 1-arg ST_GeomFromText in 27_Tier2.
--   Since that file hasn't been loaded yet at this point in
--   the execution order, we define a forward-compatible wrapper
--   that will resolve at call time (not create time).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_GeomFromText(p_wkt text, p_srid integer)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_GeomFromText(p_wkt);
END;
$$;


-- ------------------------------------------------------------
-- ST_GeomFromWKB(bytea, srid)
--   GeoServer prepared-statement mode sends geometry values as
--   WKB bytes.  This function decodes OGC WKB (little-endian)
--   back to our composite geometry type.
--
--   Supports: POINT (type 1), LINESTRING (type 2), POLYGON (type 3).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_GeomFromWKB(p_wkb bytea, p_srid integer)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   wkb_type integer;
   n        integer;
   nrings   integer;
   i        integer;
   pos      integer;
   lon_arr  double precision[];
   lat_arr  double precision[];
   -- byte order: 1 = little-endian, 0 = big-endian
   bo       integer := get_byte(p_wkb, 0);
BEGIN
   -- Read type (bytes 1-4).  For simplicity, assume little-endian.
   -- Mask off the SRID flag (0x20000000) if present.
   wkb_type := (get_byte(p_wkb, 1))
             + (get_byte(p_wkb, 2) << 8)
             + (get_byte(p_wkb, 3) << 16)
             + (get_byte(p_wkb, 4) << 24);
   wkb_type := wkb_type & x'00FFFFFF'::integer;  -- mask SRID/ZM flags

   -- If SRID flag was set, skip 4 SRID bytes
   IF (get_byte(p_wkb, 3) & 32) != 0 THEN
      pos := 9;  -- 1 (bo) + 4 (type) + 4 (srid)
   ELSE
      pos := 5;  -- 1 (bo) + 4 (type)
   END IF;

   IF wkb_type = 1 THEN
      -- POINT: read 2 float8s
      RETURN ST_MakePoint(
         lm__le_bytea_to_float8(p_wkb, pos),
         lm__le_bytea_to_float8(p_wkb, pos + 8)
      );
   END IF;

   IF wkb_type = 2 THEN
      -- LINESTRING: read npoints, then coordinate pairs
      n := lm__le_bytea_to_int32(p_wkb, pos);
      pos := pos + 4;
      lon_arr := ARRAY[]::double precision[];
      lat_arr := ARRAY[]::double precision[];
      FOR i IN 1..n LOOP
         lon_arr := lon_arr || lm__le_bytea_to_float8(p_wkb, pos);
         lat_arr := lat_arr || lm__le_bytea_to_float8(p_wkb, pos + 8);
         pos := pos + 16;
      END LOOP;
      RETURN ROW(lon_arr, lat_arr)::geometry;
   END IF;

   IF wkb_type = 3 THEN
      -- POLYGON: read nrings, then first ring only
      nrings := lm__le_bytea_to_int32(p_wkb, pos);
      pos := pos + 4;
      n := lm__le_bytea_to_int32(p_wkb, pos);  -- points in first ring
      pos := pos + 4;
      lon_arr := ARRAY[]::double precision[];
      lat_arr := ARRAY[]::double precision[];
      -- Read n points but skip the closing duplicate
      FOR i IN 1..n LOOP
         IF i < n THEN
            lon_arr := lon_arr || lm__le_bytea_to_float8(p_wkb, pos);
            lat_arr := lat_arr || lm__le_bytea_to_float8(p_wkb, pos + 8);
         END IF;
         pos := pos + 16;
      END LOOP;
      RETURN ROW(lon_arr, lat_arr)::geometry;
   END IF;

   RAISE EXCEPTION 'ST_GeomFromWKB: unsupported WKB type %', wkb_type;
END;
$$;

-- ST_GeomFromWKB: 1-arg version (no SRID)
CREATE OR REPLACE FUNCTION ST_GeomFromWKB(p_wkb bytea)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_GeomFromWKB(p_wkb, 4326);
$$;


-- Internal helpers for WKB decoding (little-endian)
CREATE OR REPLACE FUNCTION lm__le_bytea_to_float8(p_wkb bytea, p_offset integer)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   be bytea := '\x0000000000000000'::bytea;
BEGIN
   -- Reverse bytes from little-endian to big-endian for float8recv
   be := set_byte(be, 0, get_byte(p_wkb, p_offset + 7));
   be := set_byte(be, 1, get_byte(p_wkb, p_offset + 6));
   be := set_byte(be, 2, get_byte(p_wkb, p_offset + 5));
   be := set_byte(be, 3, get_byte(p_wkb, p_offset + 4));
   be := set_byte(be, 4, get_byte(p_wkb, p_offset + 3));
   be := set_byte(be, 5, get_byte(p_wkb, p_offset + 2));
   be := set_byte(be, 6, get_byte(p_wkb, p_offset + 1));
   be := set_byte(be, 7, get_byte(p_wkb, p_offset));
   RETURN float8recv(be);
END;
$$;

CREATE OR REPLACE FUNCTION lm__le_bytea_to_int32(p_wkb bytea, p_offset integer)
RETURNS integer
LANGUAGE sql IMMUTABLE
AS $$
   SELECT (get_byte(p_wkb, p_offset))
        + (get_byte(p_wkb, p_offset + 1) << 8)
        + (get_byte(p_wkb, p_offset + 2) << 16)
        + (get_byte(p_wkb, p_offset + 3) << 24);
$$;


-- ------------------------------------------------------------
-- ST_MakePoint(x, y, z)
--   3-argument version for 3D.  GeoServer uses this for 3D bbox
--   construction.  We discard Z (our type is 2D only).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_MakePoint(
   p_lon double precision,
   p_lat double precision,
   p_z   double precision
)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ROW(ARRAY[p_lon], ARRAY[p_lat])::geometry;
$$;


-- ------------------------------------------------------------
-- ST_EstimatedExtent(schema, table, column)
--   GeoServer calls this for fast bbox estimation.
--   We fall back to ST_Extent (full scan) since we don't have
--   PostGIS planner statistics.  This is slow on large tables
--   but correct, and GeoServer caches the result.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_EstimatedExtent(
   p_schema text,
   p_table  text,
   p_column text
)
RETURNS geometry
LANGUAGE plpgsql STABLE
AS $$
DECLARE
   result geometry;
BEGIN
   EXECUTE format(
      'SELECT ST_Extent(%I) FROM %I.%I',
      p_column, p_schema, p_table
   ) INTO result;
   RETURN result;
END;
$$;

-- Legacy name (PostGIS < 2.1)
CREATE OR REPLACE FUNCTION ST_Estimated_Extent(
   p_schema text,
   p_table  text,
   p_column text
)
RETURNS geometry
LANGUAGE sql STABLE
AS $$
   SELECT ST_EstimatedExtent(p_schema, p_table, p_column);
$$;


-- ------------------------------------------------------------
-- ST_SimplifyPreserveTopology(geometry, tolerance)
--   GeoServer uses this for WMS rendering at lower zoom levels.
--   We delegate to ST_Simplify (which uses Douglas-Peucker).
--   True topology preservation would require GEOS; this is a
--   best-effort shim.
--   Depends on ST_Simplify from 27_Tier2 — resolved at call time.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_SimplifyPreserveTopology(
   p_geom geometry,
   p_tolerance double precision
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_Simplify(p_geom, p_tolerance);
END;
$$;


-- ------------------------------------------------------------
-- <-> operator (KNN distance)
--   GeoServer uses: ORDER BY geom <-> ST_GeomFromText(...)
--   This is a planar distance operator for nearest-neighbor sorting.
--   In PostGIS this is index-accelerated; here it is a plain
--   distance calculation.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION geometry_distance(a geometry, b geometry)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   -- Simple centroid-to-centroid distance for sorting purposes
   ax double precision; ay double precision;
   bx double precision; b_y double precision;
   na integer := coalesce(array_length((a).lon, 1), 0);
   nb integer := coalesce(array_length((b).lon, 1), 0);
   i integer;
BEGIN
   IF na = 0 OR nb = 0 THEN RETURN 'Infinity'::double precision; END IF;

   -- Centroid of A
   ax := 0; ay := 0;
   FOR i IN 1..na LOOP ax := ax + (a).lon[i]; ay := ay + (a).lat[i]; END LOOP;
   ax := ax / na; ay := ay / na;

   -- Centroid of B
   bx := 0; b_y := 0;
   FOR i IN 1..nb LOOP bx := bx + (b).lon[i]; b_y := b_y + (b).lat[i]; END LOOP;
   bx := bx / nb; b_y := b_y / nb;

   RETURN sqrt((ax - bx) * (ax - bx) + (ay - b_y) * (ay - b_y));
END;
$$;

DROP OPERATOR IF EXISTS <-> (geometry, geometry);

CREATE OPERATOR <-> (
   LEFTARG    = geometry,
   RIGHTARG   = geometry,
   FUNCTION   = geometry_distance,
   COMMUTATOR = <->
);


-- ------------------------------------------------------------
-- box2d shim
--
-- GeoServer sometimes casts to box2d:
--   ag.geom::box2d <-> ST_MakeEnvelope(...)::box2d = 0
--
-- We define box2d as a type alias and provide casts.
-- A box2d is just a bbox: (xmin, ymin, xmax, ymax).
-- ------------------------------------------------------------
DROP TYPE IF EXISTS box2d CASCADE;

CREATE TYPE box2d AS (
   xmin double precision,
   ymin double precision,
   xmax double precision,
   ymax double precision
);

CREATE OR REPLACE FUNCTION lm__geometry_to_box2d(p_geom geometry)
RETURNS box2d
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   v double precision;
   i integer;
   bx box2d;
BEGIN
   IF n = 0 THEN RETURN NULL; END IF;
   bx.xmin := (p_geom).lon[1]; bx.xmax := (p_geom).lon[1];
   bx.ymin := (p_geom).lat[1]; bx.ymax := (p_geom).lat[1];
   FOR i IN 2..n LOOP
      v := (p_geom).lon[i];
      IF v < bx.xmin THEN bx.xmin := v; END IF;
      IF v > bx.xmax THEN bx.xmax := v; END IF;
      v := (p_geom).lat[i];
      IF v < bx.ymin THEN bx.ymin := v; END IF;
      IF v > bx.ymax THEN bx.ymax := v; END IF;
   END LOOP;
   RETURN bx;
END;
$$;

CREATE OR REPLACE FUNCTION lm__box2d_to_geometry(p_box box2d)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_MakeEnvelope((p_box).xmin, (p_box).ymin,
                           (p_box).xmax, (p_box).ymax);
$$;

CREATE CAST (geometry AS box2d)
   WITH FUNCTION lm__geometry_to_box2d(geometry)
   AS IMPLICIT;

CREATE CAST (box2d AS geometry)
   WITH FUNCTION lm__box2d_to_geometry(box2d)
   AS IMPLICIT;

-- <-> operator for box2d (bbox distance)
CREATE OR REPLACE FUNCTION box2d_distance(a box2d, b box2d)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   dx double precision := 0;
   dy double precision := 0;
BEGIN
   IF a IS NULL OR b IS NULL THEN RETURN 'Infinity'::double precision; END IF;
   -- If boxes overlap, distance is 0
   IF NOT ((a).xmax < (b).xmin OR (a).xmin > (b).xmax
        OR (a).ymax < (b).ymin OR (a).ymin > (b).ymax) THEN
      RETURN 0;
   END IF;
   -- Horizontal gap
   IF (a).xmax < (b).xmin THEN dx := (b).xmin - (a).xmax;
   ELSIF (b).xmax < (a).xmin THEN dx := (a).xmin - (b).xmax;
   END IF;
   -- Vertical gap
   IF (a).ymax < (b).ymin THEN dy := (b).ymin - (a).ymax;
   ELSIF (b).ymax < (a).ymin THEN dy := (a).ymin - (b).ymax;
   END IF;
   RETURN sqrt(dx * dx + dy * dy);
END;
$$;

DROP OPERATOR IF EXISTS <-> (box2d, box2d);

CREATE OPERATOR <-> (
   LEFTARG    = box2d,
   RIGHTARG   = box2d,
   FUNCTION   = box2d_distance,
   COMMUTATOR = <->
);


-- ============================================================================
-- ST_AsTWKB — Tiny Well-Known Binary encoding
--
-- GeoServer (PostGIS >= 2.2) uses ST_AsTWKB(geom, precision) for WMS
-- rendering when simplification is active.  TWKB uses:
--   - unsigned varint for lengths/counts
--   - zigzag-encoded signed varints for coordinate deltas
--   - coordinates scaled by 10^precision, then delta-compressed
--
-- TWKB header byte: type_and_prec = (precision << 4) | geom_type
--   geom_type: 1=Point, 2=Line, 3=Polygon
-- Metadata flags byte: 0x00 (no bbox, no size, no idlist, no extended dims)
-- ============================================================================

-- Helper: encode unsigned integer as varint (protobuf style)
CREATE OR REPLACE FUNCTION lm__twkb_uvarint(val bigint)
RETURNS bytea
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   result bytea := ''::bytea;
   v bigint := val;
   b integer;
BEGIN
   IF v < 0 THEN v := 0; END IF;
   LOOP
      b := (v & 127)::integer;
      v := v >> 7;
      IF v > 0 THEN
         b := b | 128;
      END IF;
      result := result || set_byte('\x00'::bytea, 0, b);
      EXIT WHEN v = 0;
   END LOOP;
   RETURN result;
END;
$$;

-- Helper: zigzag encode a signed integer then varint-encode it
CREATE OR REPLACE FUNCTION lm__twkb_svarint(val bigint)
RETURNS bytea
LANGUAGE sql IMMUTABLE
AS $$
   SELECT lm__twkb_uvarint(CASE WHEN val >= 0 THEN val * 2 ELSE (-val) * 2 - 1 END);
$$;

-- ST_AsTWKB(geometry, integer)  — the signature GeoServer calls
CREATE OR REPLACE FUNCTION ST_AsTWKB(p_geom geometry, p_prec integer)
RETURNS bytea
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   scale double precision;
   twkb bytea;
   header_byte integer;
   geom_type integer;
   sx bigint;  sy bigint;          -- scaled coordinate
   px bigint := 0;  py bigint := 0; -- previous (for delta)
   i integer;
   prec integer := p_prec;
BEGIN
   IF prec IS NULL THEN prec := 0; END IF;
   scale := power(10, prec);

   IF n = 0 THEN
      -- Empty geometry collection
      -- type_and_prec: prec<<4 | 4 (multipoint as empty), metadata=0x10 (empty flag)
      header_byte := ((prec & 15) << 4) | 4;
      RETURN set_byte('\x00'::bytea, 0, header_byte) || '\x10'::bytea;
   END IF;

   IF n = 1 THEN
      geom_type := 1;  -- Point
   ELSIF n = 2 THEN
      geom_type := 2;  -- LineString
   ELSE
      geom_type := 3;  -- Polygon
   END IF;

   -- Header byte: precision in upper nibble, type in lower nibble
   -- Positive precision: stored directly; negative precision: use twos complement nibble
   IF prec >= 0 THEN
      header_byte := ((prec & 15) << 4) | geom_type;
   ELSE
      -- Negative precision: stored as twos complement in 4 bits
      header_byte := (((16 + prec) & 15) << 4) | geom_type;
   END IF;

   twkb := set_byte('\x00'::bytea, 0, header_byte);
   -- Metadata flags: 0x00 (no bbox, no size, no idlist, no ext dims)
   twkb := twkb || '\x00'::bytea;

   IF geom_type = 1 THEN
      -- Point: just two svarints (absolute, since no previous)
      sx := round((p_geom).lon[1] * scale)::bigint;
      sy := round((p_geom).lat[1] * scale)::bigint;
      twkb := twkb || lm__twkb_svarint(sx);
      twkb := twkb || lm__twkb_svarint(sy);
      RETURN twkb;
   END IF;

   IF geom_type = 2 THEN
      -- LineString: npoints varint, then delta-encoded coords
      twkb := twkb || lm__twkb_uvarint(n);
      FOR i IN 1..n LOOP
         sx := round((p_geom).lon[i] * scale)::bigint;
         sy := round((p_geom).lat[i] * scale)::bigint;
         twkb := twkb || lm__twkb_svarint(sx - px);
         twkb := twkb || lm__twkb_svarint(sy - py);
         px := sx;  py := sy;
      END LOOP;
      RETURN twkb;
   END IF;

   -- Polygon: nrings varint, then for each ring: npoints varint + delta coords
   -- We have 1 ring, n+1 points (close the ring)
   twkb := twkb || lm__twkb_uvarint(1);        -- 1 ring
   twkb := twkb || lm__twkb_uvarint(n + 1);    -- n vertices + closing point
   FOR i IN 1..n LOOP
      sx := round((p_geom).lon[i] * scale)::bigint;
      sy := round((p_geom).lat[i] * scale)::bigint;
      twkb := twkb || lm__twkb_svarint(sx - px);
      twkb := twkb || lm__twkb_svarint(sy - py);
      px := sx;  py := sy;
   END LOOP;
   -- Close the ring (delta back to first point)
   sx := round((p_geom).lon[1] * scale)::bigint;
   sy := round((p_geom).lat[1] * scale)::bigint;
   twkb := twkb || lm__twkb_svarint(sx - px);
   twkb := twkb || lm__twkb_svarint(sy - py);
   RETURN twkb;
END;
$$;
