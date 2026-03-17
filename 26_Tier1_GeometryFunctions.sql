-- ============================================================================
--
-- Tier 1 Geometry Functions  —  Quick Wins
--
-- Pure PL/pgSQL PostGIS equivalents for YugabyteDB YSQL.
-- No extensions required.
--
-- Requires : 10_CreateGeometryType.sql  (geometry type + constructors)
--            20_GeohashFunctions.sql    (point_in_polygon)
--            25_GeometryFunctions.sql   (ST_XMin/xmax/ymin/ymax, etc.)
--
-- Functions in this file:
--    1) ST_X             -> ST_X
--    2) ST_Y             -> ST_Y
--    3) ST_NPoints       -> ST_NPoints
--    4) GeometryType    -> GeometryType
--    5) ST_GeometryType  -> ST_GeometryType
--    6) ST_StartPoint    -> ST_StartPoint
--    7) ST_EndPoint      -> ST_EndPoint
--    8) ST_PointN        -> ST_PointN
--    9) ST_IsClosed      -> ST_IsClosed
--   10) ST_IsEmpty       -> ST_IsEmpty
--   11) ST_Envelope      -> ST_Envelope
--   12) ST_MakeLine      -> ST_MakeLine
--   13) ST_Reverse       -> ST_Reverse
--   14) ST_FlipCoordinates -> ST_FlipCoordinates
--   15) ST_Within        -> ST_Within
--   16) ST_Disjoint      -> ST_Disjoint
--   17) ST_Area          -> ST_Area
--   18) ST_Azimuth       -> ST_Azimuth
--   19) ST_IsPolygonCCW  -> ST_IsPolygonCCW
--   20) ST_IsPolygonCW   -> ST_IsPolygonCW
--   21) ST_ForcePolygonCCW -> ST_ForcePolygonCCW
--   22) ST_ForcePolygonCW  -> ST_ForcePolygonCW
--   23) ST_Scale         -> ST_Scale
--   24) ST_PointInsideCircle -> ST_PointInsideCircle
--   25) ST_AsText        -> ST_AsText
--   26) ST_AsGeoJSON     -> ST_AsGeoJSON
--
-- ============================================================================


-- ============================================================
-- 1)  ST_X  —  PostGIS ST_X equivalent
--     Returns the X (longitude) of a point geometry.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_X(p_geom geometry)
RETURNS double precision
LANGUAGE sql IMMUTABLE
AS $$
   SELECT (p_geom).lon[1];
$$;

-- Example:
--   SELECT ST_X(ST_MakePoint(-111.97, 40.52));
--   -- Returns: -111.97


-- ============================================================
-- 2)  ST_Y  —  PostGIS ST_Y equivalent
--     Returns the Y (latitude) of a point geometry.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Y(p_geom geometry)
RETURNS double precision
LANGUAGE sql IMMUTABLE
AS $$
   SELECT (p_geom).lat[1];
$$;

-- Example:
--   SELECT ST_Y(ST_MakePoint(-111.97, 40.52));
--   -- Returns: 40.52


-- ============================================================
-- 3)  ST_NPoints  —  PostGIS ST_NPoints equivalent
--     Returns the total number of vertices in the geometry.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_NPoints(p_geom geometry)
RETURNS integer
LANGUAGE sql IMMUTABLE
AS $$
   SELECT coalesce(array_length((p_geom).lon, 1), 0);
$$;

-- Example:
--   SELECT ST_NPoints(ST_MakeEnvelope(-112, 40, -111, 41));
--   -- Returns: 4


-- ============================================================
-- 4)  GeometryType  —  PostGIS GeometryType equivalent
--     Returns 'POINT', 'LINESTRING', or 'POLYGON'.
-- ============================================================
CREATE OR REPLACE FUNCTION GeometryType(p_geom geometry)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
   SELECT CASE coalesce(array_length((p_geom).lon, 1), 0)
      WHEN 0 THEN 'EMPTY'
      WHEN 1 THEN 'POINT'
      WHEN 2 THEN 'LINESTRING'
      ELSE        'POLYGON'
   END;
$$;

-- Example:
--   SELECT GeometryType(ST_MakePoint(-111.97, 40.52));
--   -- Returns: 'POINT'


-- ============================================================
-- 5)  ST_GeometryType  —  PostGIS ST_GeometryType equivalent
--     Returns 'ST_Point', 'ST_LineString', or 'ST_Polygon'.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_GeometryType(p_geom geometry)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
   SELECT CASE coalesce(array_length((p_geom).lon, 1), 0)
      WHEN 0 THEN 'ST_Empty'
      WHEN 1 THEN 'ST_Point'
      WHEN 2 THEN 'ST_LineString'
      ELSE        'ST_Polygon'
   END;
$$;


-- ============================================================
-- 6)  ST_StartPoint  —  PostGIS ST_StartPoint equivalent
--     Returns the first vertex as a point geometry.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_StartPoint(p_geom geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_MakePoint((p_geom).lon[1], (p_geom).lat[1]);
$$;


-- ============================================================
-- 7)  ST_EndPoint  —  PostGIS ST_EndPoint equivalent
--     Returns the last vertex as a point geometry.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_EndPoint(p_geom geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_MakePoint(
      (p_geom).lon[array_length((p_geom).lon, 1)],
      (p_geom).lat[array_length((p_geom).lat, 1)]
   );
$$;


-- ============================================================
-- 8)  ST_PointN  —  PostGIS ST_PointN equivalent
--     Returns the Nth vertex (1-based) as a point geometry.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_PointN(p_geom geometry, p_n integer)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
BEGIN
   IF p_n < 1 OR p_n > n THEN
      RETURN NULL;
   END IF;
   RETURN ST_MakePoint((p_geom).lon[p_n], (p_geom).lat[p_n]);
END;
$$;


-- ============================================================
-- 9)  ST_IsClosed  —  PostGIS ST_IsClosed equivalent
--     Returns true if first vertex equals last vertex.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_IsClosed(p_geom geometry)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT (p_geom).lon[1] = (p_geom).lon[array_length((p_geom).lon, 1)]
      AND (p_geom).lat[1] = (p_geom).lat[array_length((p_geom).lat, 1)];
$$;


-- ============================================================
-- 10) ST_IsEmpty  —  PostGIS ST_IsEmpty equivalent
--     Returns true if the geometry has no vertices.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_IsEmpty(p_geom geometry)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT coalesce(array_length((p_geom).lon, 1), 0) = 0;
$$;


-- ============================================================
-- 11) ST_Envelope  —  PostGIS ST_Envelope equivalent
--     Returns the bounding box as a polygon geometry.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Envelope(p_geom geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_MakeEnvelope(
      ST_XMin(p_geom), ST_YMin(p_geom),
      ST_XMax(p_geom), ST_YMax(p_geom)
   );
$$;

-- Example:
--   SELECT ST_Envelope(ST_MakePolygon(
--       ARRAY[-112.0, -111.9, -111.85],
--       ARRAY[40.5,   40.55,  40.48]));


-- ============================================================
-- 12) ST_MakeLine  —  PostGIS ST_MakeLine equivalent
--     Creates a LineString from two point geometries.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_MakeLine(p_a geometry, p_b geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ROW(
      (p_a).lon || (p_b).lon,
      (p_a).lat || (p_b).lat
   )::geometry;
$$;

-- Aggregate version: from an array of point geometries
CREATE OR REPLACE FUNCTION ST_MakeLine(p_points geometry[])
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length(p_points, 1), 0);
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   i integer;
BEGIN
   IF n < 2 THEN
      RAISE EXCEPTION 'ST_MakeLine: need at least 2 points';
   END IF;
   FOR i IN 1..n LOOP
      out_lon := out_lon || (p_points[i]).lon;
      out_lat := out_lat || (p_points[i]).lat;
   END LOOP;
   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 13) ST_Reverse  —  PostGIS ST_Reverse equivalent
--     Reverses the order of vertices.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Reverse(p_geom geometry)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   i integer;
BEGIN
   FOR i IN REVERSE n..1 LOOP
      out_lon := out_lon || (p_geom).lon[i];
      out_lat := out_lat || (p_geom).lat[i];
   END LOOP;
   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 14) ST_FlipCoordinates  —  PostGIS ST_FlipCoordinates
--     Swaps X (lon) and Y (lat) for all vertices.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_FlipCoordinates(p_geom geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ROW((p_geom).lat, (p_geom).lon)::geometry;
$$;


-- ============================================================
-- 15) ST_Within  —  PostGIS ST_Within equivalent
--     Returns true if A is fully within B.
--     This is ST_Contains with arguments swapped.
-- ============================================================

-- Array version
CREATE OR REPLACE FUNCTION ST_Within(
   p_lon_a double precision[], p_lat_a double precision[],
   p_lon_b double precision[], p_lat_b double precision[]
)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_Contains(p_lon_b, p_lat_b, p_lon_a, p_lat_a);
$$;

-- Geometry version
CREATE OR REPLACE FUNCTION ST_Within(p_a geometry, p_b geometry)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_Contains(p_b, p_a);
$$;


-- ============================================================
-- 16) ST_Disjoint  —  PostGIS ST_Disjoint equivalent
--     Returns true if geometries do not intersect at all.
-- ============================================================

-- Array version
CREATE OR REPLACE FUNCTION ST_Disjoint(
   p_lon_a double precision[], p_lat_a double precision[],
   p_lon_b double precision[], p_lat_b double precision[]
)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT NOT ST_Intersects(p_lon_a, p_lat_a, p_lon_b, p_lat_b);
$$;

-- Geometry version
CREATE OR REPLACE FUNCTION ST_Disjoint(p_a geometry, p_b geometry)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT NOT ST_Intersects(p_a, p_b);
$$;


-- ============================================================
-- 17) ST_Area  —  PostGIS ST_Area equivalent
--     Computes the area of a polygon using the Shoelace formula.
--     Returns area in square degrees (planar).
-- ============================================================

-- Array version
CREATE OR REPLACE FUNCTION ST_Area(
   p_lon double precision[], p_lat double precision[]
)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length(p_lon, 1), 0);
   s double precision := 0;
   j integer;
   i integer;
BEGIN
   IF n < 3 THEN RETURN 0; END IF;
   j := n;
   FOR i IN 1..n LOOP
      s := s + (p_lon[j] + p_lon[i]) * (p_lat[j] - p_lat[i]);
      j := i;
   END LOOP;
   RETURN abs(s) / 2.0;
END;
$$;

-- Geometry version
CREATE OR REPLACE FUNCTION ST_Area(p_geom geometry)
RETURNS double precision
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_Area((p_geom).lon, (p_geom).lat);
$$;

-- Example:
--   SELECT ST_Area(ST_MakeEnvelope(-112, 40, -111, 41));
--   -- Returns: 1.0  (1 square degree)


-- ============================================================
-- 18) ST_Azimuth  —  PostGIS ST_Azimuth equivalent
--     Returns the angle in radians from point A to point B,
--     measured clockwise from north (positive Y).
--     Range: [0, 2*pi)
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Azimuth(p_a geometry, p_b geometry)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   dx double precision := (p_b).lon[1] - (p_a).lon[1];
   dy double precision := (p_b).lat[1] - (p_a).lat[1];
   az double precision;
BEGIN
   IF dx = 0 AND dy = 0 THEN RETURN NULL; END IF;
   az := atan2(dx, dy);
   IF az < 0 THEN az := az + 2.0 * pi(); END IF;
   RETURN az;
END;
$$;

-- Example:
--   SELECT ST_Azimuth(
--       ST_MakePoint(0, 0), ST_MakePoint(1, 1));
--   -- Returns: ~0.7854  (pi/4, i.e. 45 degrees = northeast)


-- ============================================================
-- Internal helper: signed area (positive = CCW, negative = CW)
-- ============================================================
CREATE OR REPLACE FUNCTION lm__signed_area(
   p_lon double precision[], p_lat double precision[]
)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length(p_lon, 1), 0);
   s double precision := 0;
   j integer;
   i integer;
BEGIN
   IF n < 3 THEN RETURN 0; END IF;
   j := n;
   FOR i IN 1..n LOOP
      s := s + (p_lon[j] - p_lon[i]) * (p_lat[j] + p_lat[i]);
      j := i;
   END LOOP;
   RETURN s / 2.0;
END;
$$;


-- ============================================================
-- 19) ST_IsPolygonCCW  —  PostGIS ST_IsPolygonCCW equivalent
--     Returns true if the polygon vertices are counter-clockwise.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_IsPolygonCCW(p_geom geometry)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT lm__signed_area((p_geom).lon, (p_geom).lat) > 0;
$$;


-- ============================================================
-- 20) ST_IsPolygonCW  —  PostGIS ST_IsPolygonCW equivalent
--     Returns true if the polygon vertices are clockwise.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_IsPolygonCW(p_geom geometry)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT lm__signed_area((p_geom).lon, (p_geom).lat) < 0;
$$;


-- ============================================================
-- 21) ST_ForcePolygonCCW  —  PostGIS ST_ForcePolygonCCW
--     Returns the polygon with vertices in CCW order.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_ForcePolygonCCW(p_geom geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT CASE
      WHEN lm__signed_area((p_geom).lon, (p_geom).lat) < 0
      THEN ST_Reverse(p_geom)
      ELSE p_geom
   END;
$$;


-- ============================================================
-- 22) ST_ForcePolygonCW  —  PostGIS ST_ForcePolygonCW
--     Returns the polygon with vertices in CW order.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_ForcePolygonCW(p_geom geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT CASE
      WHEN lm__signed_area((p_geom).lon, (p_geom).lat) > 0
      THEN ST_Reverse(p_geom)
      ELSE p_geom
   END;
$$;


-- ============================================================
-- 23) ST_Scale  —  PostGIS ST_Scale equivalent
--     Scales a geometry by sx (X factor) and sy (Y factor)
--     relative to the origin.
-- ============================================================

-- Array version
CREATE OR REPLACE FUNCTION ST_Scale(
   p_lon double precision[], p_lat double precision[],
   p_sx  double precision,   p_sy  double precision
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length(p_lon, 1), 0);
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   i integer;
BEGIN
   FOR i IN 1..n LOOP
      out_lon := out_lon || (p_lon[i] * p_sx);
      out_lat := out_lat || (p_lat[i] * p_sy);
   END LOOP;
   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;

-- Geometry version
CREATE OR REPLACE FUNCTION ST_Scale(
   p_geom geometry,
   p_sx   double precision,
   p_sy   double precision
)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_Scale((p_geom).lon, (p_geom).lat, p_sx, p_sy);
$$;


-- ============================================================
-- 24) ST_PointInsideCircle  —  PostGIS ST_PointInsideCircle
--     Tests if a point is inside a circle defined by
--     center (cx, cy) and radius r (Euclidean / planar).
-- ============================================================
CREATE OR REPLACE FUNCTION ST_PointInsideCircle(
   p_point geometry,
   p_cx    double precision,
   p_cy    double precision,
   p_r     double precision
)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ( ((p_point).lon[1] - p_cx) * ((p_point).lon[1] - p_cx)
          + ((p_point).lat[1] - p_cy) * ((p_point).lat[1] - p_cy) )
          <= (p_r * p_r);
$$;


-- ============================================================
-- 25) ST_AsText  —  PostGIS ST_AsText equivalent
--     Returns the geometry as Well-Known Text (WKT).
-- ============================================================
CREATE OR REPLACE FUNCTION ST_AsText(p_geom geometry)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   coords text := '';
   i integer;
BEGIN
   IF n = 0 THEN
      RETURN 'GEOMETRYCOLLECTION EMPTY';
   END IF;

   -- Build coordinate string
   FOR i IN 1..n LOOP
      IF i > 1 THEN coords := coords || ','; END IF;
      coords := coords || (p_geom).lon[i]::text || ' ' || (p_geom).lat[i]::text;
   END LOOP;

   IF n = 1 THEN
      RETURN 'POINT(' || coords || ')';
   ELSIF n = 2 THEN
      RETURN 'LINESTRING(' || coords || ')';
   ELSE
      -- Close the ring for WKT polygon output
      IF (p_geom).lon[1] <> (p_geom).lon[n]
         OR (p_geom).lat[1] <> (p_geom).lat[n] THEN
         coords := coords || ',' || (p_geom).lon[1]::text || ' ' || (p_geom).lat[1]::text;
      END IF;
      RETURN 'POLYGON((' || coords || '))';
   END IF;
END;
$$;

-- Example:
--   SELECT ST_AsText(ST_MakePoint(-111.97, 40.52));
--   -- Returns: 'POINT(-111.97 40.52)'
--
--   SELECT ST_AsText(ST_MakeEnvelope(-112, 40, -111, 41));
--   -- Returns: 'POLYGON((-112 40,-111 40,-111 41,-112 41,-112 40))'


-- ============================================================
-- 26) ST_AsGeoJSON  —  PostGIS ST_AsGeoJSON equivalent
--     Returns the geometry as a GeoJSON geometry object (text).
-- ============================================================
CREATE OR REPLACE FUNCTION ST_AsGeoJSON(p_geom geometry)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   coords text := '';
   i integer;
BEGIN
   IF n = 0 THEN
      RETURN '{"type":"GeometryCollection","geometries":[]}';
   END IF;

   IF n = 1 THEN
      RETURN '{"type":"Point","coordinates":['
         || (p_geom).lon[1]::text || ',' || (p_geom).lat[1]::text || ']}';
   ELSIF n = 2 THEN
      FOR i IN 1..n LOOP
         IF i > 1 THEN coords := coords || ','; END IF;
         coords := coords || '[' || (p_geom).lon[i]::text || ',' || (p_geom).lat[i]::text || ']';
      END LOOP;
      RETURN '{"type":"LineString","coordinates":[' || coords || ']}';
   ELSE
      -- Polygon: ring must be closed in GeoJSON
      FOR i IN 1..n LOOP
         IF i > 1 THEN coords := coords || ','; END IF;
         coords := coords || '[' || (p_geom).lon[i]::text || ',' || (p_geom).lat[i]::text || ']';
      END LOOP;
      -- Close ring if not already closed
      IF (p_geom).lon[1] <> (p_geom).lon[n]
         OR (p_geom).lat[1] <> (p_geom).lat[n] THEN
         coords := coords || ',[' || (p_geom).lon[1]::text || ',' || (p_geom).lat[1]::text || ']';
      END IF;
      RETURN '{"type":"Polygon","coordinates":[[' || coords || ']]}';
   END IF;
END;
$$;

-- Example:
--   SELECT ST_AsGeoJSON(ST_MakePoint(-111.97, 40.52));
--   -- Returns: '{"type":"Point","coordinates":[-111.97,40.52]}'
