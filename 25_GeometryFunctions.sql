-- ============================================================================
--
-- YugabyteDB YSQL / PostgreSQL-compatible geometry functions
-- (pure SQL + PL/pgSQL; no extensions required)
--
-- PostGIS-compatible spatial functions.  Every function has two overloads:
--   - Array style:    ST_Contains(lon_a[], lat_a[], lon_b[], lat_b[])
--   - Geometry style: ST_Contains(a geometry, b geometry)
--
-- Requires : 10_CreateGeometryType.sql  (geometry type + constructors)
--            20_GeohashFunctions.sql    (point_in_polygon)
--
-- What you get in this file:
--   1) ST_XMin            -> min longitude
--   2) ST_XMax            -> max longitude
--   3) ST_YMin            -> min latitude
--   4) ST_YMax            -> max latitude
--   5) ST_Translate        -> shifted polygon / geometry
--   6) ST_Intersects       -> boolean
--   7) ST_Contains         -> boolean
--
-- Internal helpers (not for direct use):
--   - lm__on_segment(...)
--   - lm__segments_cross(...)
--
-- Conventions:
--   X = longitude, Y = latitude  (matches PostGIS ST_X / ST_Y).
--
-- ============================================================================


-- ============================================================
-- 1)  ST_XMin  --  PostGIS ST_XMin equivalent
-- ============================================================

-- Array version
--
-- Example:
--   SELECT ST_XMin(ARRAY[-112.0, -111.9, -111.9, -112.0]);
--   -- Returns: -112.0
--
CREATE OR REPLACE FUNCTION ST_XMin(p_lon double precision[])
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length(p_lon, 1), 0);
   v double precision; result double precision; i integer;
BEGIN
   IF n = 0 THEN RAISE EXCEPTION 'ST_XMin: lon array must not be empty'; END IF;
   result := p_lon[1];
   FOR i IN 2..n LOOP
      v := p_lon[i]; IF v < result THEN result := v; END IF;
   END LOOP;
   RETURN result;
END;
$$;

-- Geometry version
--
-- Example:
--   SELECT ST_XMin(ST_MakePolygon(
--       ARRAY[-112.0, -111.9, -111.9, -112.0],
--       ARRAY[40.5,   40.5,   40.55,  40.55]));
--   -- Returns: -112.0
--
CREATE OR REPLACE FUNCTION ST_XMin(p_geom geometry)
RETURNS double precision LANGUAGE sql IMMUTABLE
AS $$ SELECT ST_XMin((p_geom).lon); $$;


-- ============================================================
-- 2)  ST_XMax  --  PostGIS ST_XMax equivalent
-- ============================================================

-- Array version
CREATE OR REPLACE FUNCTION ST_XMax(p_lon double precision[])
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length(p_lon, 1), 0);
   v double precision; result double precision; i integer;
BEGIN
   IF n = 0 THEN RAISE EXCEPTION 'ST_XMax: lon array must not be empty'; END IF;
   result := p_lon[1];
   FOR i IN 2..n LOOP
      v := p_lon[i]; IF v > result THEN result := v; END IF;
   END LOOP;
   RETURN result;
END;
$$;

-- Geometry version
CREATE OR REPLACE FUNCTION ST_XMax(p_geom geometry)
RETURNS double precision LANGUAGE sql IMMUTABLE
AS $$ SELECT ST_XMax((p_geom).lon); $$;


-- ============================================================
-- 3)  ST_YMin  --  PostGIS ST_YMin equivalent
-- ============================================================

-- Array version
CREATE OR REPLACE FUNCTION ST_YMin(p_lat double precision[])
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length(p_lat, 1), 0);
   v double precision; result double precision; i integer;
BEGIN
   IF n = 0 THEN RAISE EXCEPTION 'ST_YMin: lat array must not be empty'; END IF;
   result := p_lat[1];
   FOR i IN 2..n LOOP
      v := p_lat[i]; IF v < result THEN result := v; END IF;
   END LOOP;
   RETURN result;
END;
$$;

-- Geometry version
CREATE OR REPLACE FUNCTION ST_YMin(p_geom geometry)
RETURNS double precision LANGUAGE sql IMMUTABLE
AS $$ SELECT ST_YMin((p_geom).lat); $$;


-- ============================================================
-- 4)  ST_YMax  --  PostGIS ST_YMax equivalent
-- ============================================================

-- Array version
CREATE OR REPLACE FUNCTION ST_YMax(p_lat double precision[])
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length(p_lat, 1), 0);
   v double precision; result double precision; i integer;
BEGIN
   IF n = 0 THEN RAISE EXCEPTION 'ST_YMax: lat array must not be empty'; END IF;
   result := p_lat[1];
   FOR i IN 2..n LOOP
      v := p_lat[i]; IF v > result THEN result := v; END IF;
   END LOOP;
   RETURN result;
END;
$$;

-- Geometry version
CREATE OR REPLACE FUNCTION ST_YMax(p_geom geometry)
RETURNS double precision LANGUAGE sql IMMUTABLE
AS $$ SELECT ST_YMax((p_geom).lat); $$;


-- ============================================================
-- 5)  ST_Translate  --  PostGIS ST_Translate equivalent
-- ============================================================

-- Array version -- returns TABLE(out_lon[], out_lat[])
--
-- Example:
--   SELECT * FROM ST_Translate(
--       ARRAY[-112.0, -111.9, -111.9, -112.0],
--       ARRAY[40.5,   40.5,   40.55,  40.55],
--       0.01, -0.02);
--
CREATE OR REPLACE FUNCTION ST_Translate(
   p_lon double precision[], p_lat double precision[],
   p_dx  double precision,   p_dy  double precision
)
RETURNS TABLE(out_lon double precision[], out_lat double precision[])
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length(p_lon, 1), 0);
   i integer;
BEGIN
   IF n = 0 OR n <> coalesce(array_length(p_lat, 1), 0) THEN
      RAISE EXCEPTION 'ST_Translate: lon[] and lat[] must be same length and non-empty';
   END IF;
   out_lon := ARRAY[]::double precision[];
   out_lat := ARRAY[]::double precision[];
   FOR i IN 1..n LOOP
      out_lon := out_lon || (p_lon[i] + p_dx);
      out_lat := out_lat || (p_lat[i] + p_dy);
   END LOOP;
   RETURN NEXT;
END;
$$;

-- Geometry version -- returns geometry
--
-- Example:
--   SELECT ST_Translate(
--       ST_MakePolygon(ARRAY[-112.0, -111.9, -111.9, -112.0],
--                       ARRAY[40.5,   40.5,   40.55,  40.55]),
--       0.01, -0.02);
--
CREATE OR REPLACE FUNCTION ST_Translate(
   p_geom geometry,
   p_dx   double precision,
   p_dy   double precision
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   src_lon double precision[] := (p_geom).lon;
   src_lat double precision[] := (p_geom).lat;
   n integer := coalesce(array_length(src_lon, 1), 0);
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   i integer;
BEGIN
   IF n = 0 OR n <> coalesce(array_length(src_lat, 1), 0) THEN
      RAISE EXCEPTION 'ST_Translate: geometry must not be empty';
   END IF;
   FOR i IN 1..n LOOP
      out_lon := out_lon || (src_lon[i] + p_dx);
      out_lat := out_lat || (src_lat[i] + p_dy);
   END LOOP;
   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ------------------------------------------------------------
-- Internal helper: is point (px,py) on segment (sx1,sy1)-(sx2,sy2)?
-- Assumes the three points are already known to be collinear.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION lm__on_segment(
   sx1 double precision, sy1 double precision,
   sx2 double precision, sy2 double precision,
   px  double precision, py  double precision
)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN px >= least(sx1, sx2)
      AND px <= greatest(sx1, sx2)
      AND py >= least(sy1, sy2)
      AND py <= greatest(sy1, sy2);
END;
$$;


-- ------------------------------------------------------------
-- Internal helper: do two line segments properly cross?
-- Uses the orientation / cross-product method.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION lm__segments_cross(
   ax1 double precision, ay1 double precision,
   ax2 double precision, ay2 double precision,
   bx1 double precision, by1 double precision,
   bx2 double precision, by2 double precision
)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   d1 double precision; d2 double precision;
   d3 double precision; d4 double precision;
BEGIN
   d1 := (bx2 - bx1) * (ay1 - by1) - (by2 - by1) * (ax1 - bx1);
   d2 := (bx2 - bx1) * (ay2 - by1) - (by2 - by1) * (ax2 - bx1);
   d3 := (ax2 - ax1) * (by1 - ay1) - (ay2 - ay1) * (bx1 - ax1);
   d4 := (ax2 - ax1) * (by2 - ay1) - (ay2 - ay1) * (bx2 - ax1);
   IF ((d1 > 0 AND d2 < 0) OR (d1 < 0 AND d2 > 0))
      AND ((d3 > 0 AND d4 < 0) OR (d3 < 0 AND d4 > 0))
   THEN RETURN true; END IF;
   IF d1 = 0 AND lm__on_segment(bx1, by1, bx2, by2, ax1, ay1) THEN RETURN true; END IF;
   IF d2 = 0 AND lm__on_segment(bx1, by1, bx2, by2, ax2, ay2) THEN RETURN true; END IF;
   IF d3 = 0 AND lm__on_segment(ax1, ay1, ax2, ay2, bx1, by1) THEN RETURN true; END IF;
   IF d4 = 0 AND lm__on_segment(ax1, ay1, ax2, ay2, bx2, by2) THEN RETURN true; END IF;
   RETURN false;
END;
$$;


-- ============================================================
-- 6)  ST_Intersects  --  PostGIS ST_Intersects equivalent
-- ============================================================

-- Array version
--
-- Example:
--   SELECT ST_Intersects(
--       ARRAY[-112.0, -111.9, -111.9, -112.0],
--       ARRAY[40.5,   40.5,   40.55,  40.55],
--       ARRAY[-111.95, -111.85, -111.85, -111.95],
--       ARRAY[40.52,   40.52,   40.57,   40.57]);
--   -- Returns: true
--
CREATE OR REPLACE FUNCTION ST_Intersects(
   p_lon_a double precision[], p_lat_a double precision[],
   p_lon_b double precision[], p_lat_b double precision[]
)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   na integer := coalesce(array_length(p_lon_a, 1), 0);
   nb integer := coalesce(array_length(p_lon_b, 1), 0);
   i integer; j integer; i2 integer; j2 integer;
BEGIN
   IF na < 1 OR na <> coalesce(array_length(p_lat_a, 1), 0) THEN
      RAISE EXCEPTION 'ST_Intersects: polygon A lon/lat arrays must be same length and non-empty';
   END IF;
   IF nb < 1 OR nb <> coalesce(array_length(p_lat_b, 1), 0) THEN
      RAISE EXCEPTION 'ST_Intersects: polygon B lon/lat arrays must be same length and non-empty';
   END IF;

   -- Single-point cases
   IF na = 1 AND nb = 1 THEN
      RETURN (p_lon_a[1] = p_lon_b[1] AND p_lat_a[1] = p_lat_b[1]);
   END IF;
   IF na = 1 THEN
      RETURN point_in_polygon(p_lon_a[1], p_lat_a[1], p_lon_b, p_lat_b);
   END IF;
   IF nb = 1 THEN
      RETURN point_in_polygon(p_lon_b[1], p_lat_b[1], p_lon_a, p_lat_a);
   END IF;

   -- Any vertex of A inside B?
   FOR i IN 1..na LOOP
      IF point_in_polygon(p_lon_a[i], p_lat_a[i], p_lon_b, p_lat_b) THEN RETURN true; END IF;
   END LOOP;

   -- Any vertex of B inside A?
   FOR i IN 1..nb LOOP
      IF point_in_polygon(p_lon_b[i], p_lat_b[i], p_lon_a, p_lat_a) THEN RETURN true; END IF;
   END LOOP;

   -- Any edge of A crosses any edge of B?
   FOR i IN 1..na LOOP
      i2 := CASE WHEN i = na THEN 1 ELSE i + 1 END;
      FOR j IN 1..nb LOOP
         j2 := CASE WHEN j = nb THEN 1 ELSE j + 1 END;
         IF lm__segments_cross(
               p_lon_a[i], p_lat_a[i], p_lon_a[i2], p_lat_a[i2],
               p_lon_b[j], p_lat_b[j], p_lon_b[j2], p_lat_b[j2])
         THEN RETURN true; END IF;
      END LOOP;
   END LOOP;

   RETURN false;
END;
$$;

-- Geometry version
--
-- Example:
--   SELECT ST_Intersects(
--       ST_MakePolygon(ARRAY[-112.0, -111.9, -111.9, -112.0],
--                       ARRAY[40.5,   40.5,   40.55,  40.55]),
--       ST_MakePolygon(ARRAY[-111.95, -111.85, -111.85, -111.95],
--                       ARRAY[40.52,   40.52,   40.57,   40.57]));
--   -- Returns: true
--
CREATE OR REPLACE FUNCTION ST_Intersects(p_a geometry, p_b geometry)
RETURNS boolean LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_Intersects((p_a).lon, (p_a).lat, (p_b).lon, (p_b).lat);
$$;


-- ============================================================
-- 7)  ST_Contains  --  PostGIS ST_Contains equivalent
-- ============================================================

-- Array version
--
-- Example:
--   SELECT ST_Contains(
--       ARRAY[-112.0, -111.8, -111.8, -112.0],
--       ARRAY[40.4,   40.4,   40.6,   40.6],
--       ARRAY[-111.95, -111.85, -111.85, -111.95],
--       ARRAY[40.45,   40.45,   40.55,   40.55]);
--   -- Returns: true
--
CREATE OR REPLACE FUNCTION ST_Contains(
   p_lon_a double precision[], p_lat_a double precision[],
   p_lon_b double precision[], p_lat_b double precision[]
)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   na integer := coalesce(array_length(p_lon_a, 1), 0);
   nb integer := coalesce(array_length(p_lon_b, 1), 0);
   i  integer; j  integer; i2 integer;
   on_boundary boolean; has_interior boolean := false;
   ex1 double precision; ey1 double precision;
   ex2 double precision; ey2 double precision;
   px  double precision; py  double precision;
   t   double precision; dist double precision;
   epsilon constant double precision := 1e-12;
BEGIN
   IF na < 3 OR na <> coalesce(array_length(p_lat_a, 1), 0) THEN
      RAISE EXCEPTION 'ST_Contains: polygon A must have >= 3 vertices with matching lon/lat lengths';
   END IF;
   IF nb < 1 OR nb <> coalesce(array_length(p_lat_b, 1), 0) THEN
      RAISE EXCEPTION 'ST_Contains: polygon B lon/lat arrays must be same length and non-empty';
   END IF;

   -- Every vertex of B must be inside A (or on its boundary).
   FOR i IN 1..nb LOOP
      IF NOT point_in_polygon(p_lon_b[i], p_lat_b[i], p_lon_a, p_lat_a) THEN
         RETURN false;
      END IF;
   END LOOP;

   -- At least one point of B must be strictly in the interior of A
   -- (not on any edge).  This matches PostGIS semantics.
   FOR i IN 1..nb LOOP
      px := p_lon_b[i]; py := p_lat_b[i];
      on_boundary := false;

      FOR j IN 1..na LOOP
         i2 := CASE WHEN j = na THEN 1 ELSE j + 1 END;
         ex1 := p_lon_a[j];  ey1 := p_lat_a[j];
         ex2 := p_lon_a[i2]; ey2 := p_lat_a[i2];

         t := ((px - ex1) * (ex2 - ex1) + (py - ey1) * (ey2 - ey1))
            / nullif(((ex2 - ex1) * (ex2 - ex1) + (ey2 - ey1) * (ey2 - ey1)), 0.0);

         IF t IS NULL THEN
            dist := sqrt((px - ex1)*(px - ex1) + (py - ey1)*(py - ey1));
         ELSE
            t := greatest(0.0, least(1.0, t));
            dist := sqrt(
               (px - (ex1 + t * (ex2 - ex1))) * (px - (ex1 + t * (ex2 - ex1)))
             + (py - (ey1 + t * (ey2 - ey1))) * (py - (ey1 + t * (ey2 - ey1)))
            );
         END IF;

         IF dist < epsilon THEN on_boundary := true; EXIT; END IF;
      END LOOP;

      IF NOT on_boundary THEN has_interior := true; EXIT; END IF;
   END LOOP;

   RETURN has_interior;
END;
$$;

-- Geometry version
--
-- Example:
--   SELECT ST_Contains(
--       ST_MakePolygon(ARRAY[-112.0, -111.8, -111.8, -112.0],
--                       ARRAY[40.4,   40.4,   40.6,   40.6]),
--       ST_MakePolygon(ARRAY[-111.95, -111.85, -111.85, -111.95],
--                       ARRAY[40.45,   40.45,   40.55,   40.55]));
--   -- Returns: true
--
CREATE OR REPLACE FUNCTION ST_Contains(p_a geometry, p_b geometry)
RETURNS boolean LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_Contains((p_a).lon, (p_a).lat, (p_b).lon, (p_b).lat);
$$;
