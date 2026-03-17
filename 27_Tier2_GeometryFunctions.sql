-- ============================================================================
--
-- Tier 2 Geometry Functions  —  Core Spatial Functions
--
-- Pure PL/pgSQL PostGIS equivalents for YugabyteDB YSQL.
-- No extensions required.
--
-- Requires : 10_CreateGeometryType.sql
--            20_GeohashFunctions.sql
--            25_GeometryFunctions.sql
--            26_Tier1_GeometryFunctions.sql
--
-- Functions in this file:
--    1) ST_Distance          -> ST_Distance
--    2) ST_Length            -> ST_Length
--    3) ST_Perimeter         -> ST_Perimeter
--    4) ST_Centroid          -> ST_Centroid
--    5) ST_Distancesphere    -> ST_DistanceSphere
--    6) ST_DWithin           -> ST_DWithin
--    7) ST_Simplify          -> ST_Simplify
--    8) ST_LineInterpolatePoint  -> ST_LineInterpolatePoint
--    9) ST_LineLocatePoint   -> ST_LineLocatePoint
--   10) ST_LineSubstring     -> ST_LineSubstring
--   11) ST_GeomFromText      -> ST_GeomFromText
--   12) ST_GeomFromGeoJSON   -> ST_GeomFromGeoJSON
--   13) ST_Rotate            -> ST_Rotate
--   14) ST_Affine            -> ST_Affine
--   15) ST_DumpPoints        -> ST_DumpPoints
--   16) ST_DumpSegments      -> ST_DumpSegments
--   17) ST_SnapToGrid        -> ST_SnapToGrid
--   18) ST_RemoveRepeatedPoints -> ST_RemoveRepeatedPoints
--   19) ST_Segmentize        -> ST_Segmentize
--   20) ST_ClipByBox2D       -> ST_ClipByBox2D
--   21) ST_GeneratePoints    -> ST_GeneratePoints
--   22) ST_ChaikinSmoothing  -> ST_ChaikinSmoothing
--   23) ST_Expand            -> ST_Expand
--   24) ST_Summary           -> ST_Summary
--   25) ST_AddPoint          -> ST_AddPoint
--   26) ST_RemovePoint       -> ST_RemovePoint
--   27) ST_SetPoint          -> ST_SetPoint
--   28) ST_Project           -> ST_Project
--
-- ============================================================================


-- ============================================================
-- Internal: minimum distance from point to segment
-- ============================================================
CREATE OR REPLACE FUNCTION lm__point_segment_dist(
   px double precision, py double precision,
   ax double precision, ay double precision,
   bx double precision, b_y double precision
)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   dx double precision := bx - ax;
   dy double precision := b_y - ay;
   len2 double precision := dx*dx + dy*dy;
   t double precision;
   cx double precision; cy double precision;
BEGIN
   IF len2 = 0 THEN
      RETURN sqrt((px - ax)*(px - ax) + (py - ay)*(py - ay));
   END IF;
   t := ((px - ax)*dx + (py - ay)*dy) / len2;
   t := greatest(0.0, least(1.0, t));
   cx := ax + t * dx;
   cy := ay + t * dy;
   RETURN sqrt((px - cx)*(px - cx) + (py - cy)*(py - cy));
END;
$$;


-- ============================================================
-- 1)  ST_Distance  —  PostGIS ST_Distance equivalent
--     Minimum planar distance between two geometries.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Distance(p_a geometry, p_b geometry)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   na integer := coalesce(array_length((p_a).lon, 1), 0);
   nb integer := coalesce(array_length((p_b).lon, 1), 0);
   min_d double precision := 'Infinity';
   d double precision;
   i integer; j integer; i2 integer; j2 integer;
BEGIN
   -- Point-to-point
   IF na = 1 AND nb = 1 THEN
      RETURN sqrt(((p_a).lon[1] - (p_b).lon[1])^2 + ((p_a).lat[1] - (p_b).lat[1])^2);
   END IF;

   -- Point to each segment of the other geometry
   IF na = 1 THEN
      FOR j IN 1..nb LOOP
         j2 := CASE WHEN j = nb THEN 1 ELSE j + 1 END;
         d := lm__point_segment_dist(
            (p_a).lon[1], (p_a).lat[1],
            (p_b).lon[j], (p_b).lat[j],
            (p_b).lon[j2], (p_b).lat[j2]);
         IF d < min_d THEN min_d := d; END IF;
      END LOOP;
      RETURN min_d;
   END IF;

   IF nb = 1 THEN
      FOR i IN 1..na LOOP
         i2 := CASE WHEN i = na THEN 1 ELSE i + 1 END;
         d := lm__point_segment_dist(
            (p_b).lon[1], (p_b).lat[1],
            (p_a).lon[i], (p_a).lat[i],
            (p_a).lon[i2], (p_a).lat[i2]);
         IF d < min_d THEN min_d := d; END IF;
      END LOOP;
      RETURN min_d;
   END IF;

   -- Check if geometries intersect (distance = 0)
   IF ST_Intersects(p_a, p_b) THEN RETURN 0; END IF;

   -- All vertex-to-segment combinations
   FOR i IN 1..na LOOP
      FOR j IN 1..nb LOOP
         j2 := CASE WHEN j = nb THEN 1 ELSE j + 1 END;
         d := lm__point_segment_dist(
            (p_a).lon[i], (p_a).lat[i],
            (p_b).lon[j], (p_b).lat[j],
            (p_b).lon[j2], (p_b).lat[j2]);
         IF d < min_d THEN min_d := d; END IF;
      END LOOP;
   END LOOP;
   FOR j IN 1..nb LOOP
      FOR i IN 1..na LOOP
         i2 := CASE WHEN i = na THEN 1 ELSE i + 1 END;
         d := lm__point_segment_dist(
            (p_b).lon[j], (p_b).lat[j],
            (p_a).lon[i], (p_a).lat[i],
            (p_a).lon[i2], (p_a).lat[i2]);
         IF d < min_d THEN min_d := d; END IF;
      END LOOP;
   END LOOP;

   RETURN min_d;
END;
$$;


-- ============================================================
-- 2)  ST_Length  —  PostGIS ST_Length equivalent
--     Returns the planar length of a linestring / polygon
--     perimeter.  Sum of all segment lengths.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Length(p_geom geometry)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   total double precision := 0;
   i integer;
BEGIN
   IF n < 2 THEN RETURN 0; END IF;
   FOR i IN 1..n-1 LOOP
      total := total + sqrt(
         ((p_geom).lon[i+1] - (p_geom).lon[i])^2
       + ((p_geom).lat[i+1] - (p_geom).lat[i])^2);
   END LOOP;
   RETURN total;
END;
$$;


-- ============================================================
-- 3)  ST_Perimeter  —  PostGIS ST_Perimeter equivalent
--     Sum of all edge lengths of a polygon (closed ring).
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Perimeter(p_geom geometry)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   total double precision := 0;
   i integer; i2 integer;
BEGIN
   IF n < 3 THEN RETURN 0; END IF;
   FOR i IN 1..n LOOP
      i2 := CASE WHEN i = n THEN 1 ELSE i + 1 END;
      total := total + sqrt(
         ((p_geom).lon[i2] - (p_geom).lon[i])^2
       + ((p_geom).lat[i2] - (p_geom).lat[i])^2);
   END LOOP;
   RETURN total;
END;
$$;


-- ============================================================
-- 4)  ST_Centroid  —  PostGIS ST_Centroid equivalent
--     Geometric center of mass.
--     For points: returns the point itself.
--     For polygons: weighted centroid via shoelace sums.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Centroid(p_geom geometry)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   cx double precision := 0;
   cy double precision := 0;
   a  double precision := 0;
   cross_val double precision;
   i integer; i2 integer;
   area6 double precision;
BEGIN
   IF n = 0 THEN RETURN NULL; END IF;
   IF n = 1 THEN RETURN p_geom; END IF;

   -- For line: simple average
   IF n = 2 THEN
      RETURN ST_MakePoint(
         ((p_geom).lon[1] + (p_geom).lon[2]) / 2.0,
         ((p_geom).lat[1] + (p_geom).lat[2]) / 2.0);
   END IF;

   -- Polygon centroid via shoelace
   FOR i IN 1..n LOOP
      i2 := CASE WHEN i = n THEN 1 ELSE i + 1 END;
      cross_val := (p_geom).lon[i] * (p_geom).lat[i2]
                 - (p_geom).lon[i2] * (p_geom).lat[i];
      cx := cx + ((p_geom).lon[i] + (p_geom).lon[i2]) * cross_val;
      cy := cy + ((p_geom).lat[i] + (p_geom).lat[i2]) * cross_val;
      a  := a + cross_val;
   END LOOP;

   area6 := a * 3.0;   -- 6 * (signed_area)  since a = 2*signed_area
   IF area6 = 0 THEN
      -- Degenerate polygon: fall back to average
      RETURN ST_MakePoint(
         (SELECT avg(v) FROM unnest((p_geom).lon) AS v),
         (SELECT avg(v) FROM unnest((p_geom).lat) AS v));
   END IF;

   RETURN ST_MakePoint(cx / area6, cy / area6);
END;
$$;


-- ============================================================
-- 5)  ST_Distancesphere  —  PostGIS ST_DistanceSphere
--     Great-circle distance in meters using the Haversine formula.
--     Assumes coordinates are lon/lat in degrees (SRID 4326).
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Distancesphere(p_a geometry, p_b geometry)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   R constant double precision := 6371000.0;  -- Earth mean radius in meters
   lat1 double precision := radians((p_a).lat[1]);
   lat2 double precision := radians((p_b).lat[1]);
   dlat double precision := radians((p_b).lat[1] - (p_a).lat[1]);
   dlon double precision := radians((p_b).lon[1] - (p_a).lon[1]);
   a_val double precision;
BEGIN
   a_val := sin(dlat/2) * sin(dlat/2)
          + cos(lat1) * cos(lat2) * sin(dlon/2) * sin(dlon/2);
   RETURN R * 2.0 * atan2(sqrt(a_val), sqrt(1.0 - a_val));
END;
$$;

-- Example:
--   SELECT ST_Distancesphere(
--       ST_MakePoint(-104.9903, 39.7392),   -- Denver
--       ST_MakePoint(-111.8910, 40.7608));   -- Salt Lake City
--   -- Returns: ~596,000 meters


-- ============================================================
-- 6)  ST_DWithin  —  PostGIS ST_DWithin equivalent
--     Returns true if the planar distance between two
--     geometries is less than or equal to the threshold.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_DWithin(
   p_a geometry, p_b geometry, p_distance double precision
)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_Distance(p_a, p_b) <= p_distance;
$$;


-- ============================================================
-- Internal: total length of linestring segments (for linear ref)
-- ============================================================
CREATE OR REPLACE FUNCTION lm__line_total_length(p_geom geometry)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   total double precision := 0;
   i integer;
BEGIN
   FOR i IN 1..n-1 LOOP
      total := total + sqrt(
         ((p_geom).lon[i+1] - (p_geom).lon[i])^2
       + ((p_geom).lat[i+1] - (p_geom).lat[i])^2);
   END LOOP;
   RETURN total;
END;
$$;


-- ============================================================
-- 7)  ST_Simplify  —  PostGIS ST_Simplify equivalent
--     Douglas-Peucker line simplification.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Simplify(
   p_geom geometry, p_tolerance double precision
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   keep boolean[];
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   i integer;

   -- Stack-based iterative Douglas-Peucker
   stack_start integer[];
   stack_end   integer[];
   s integer; e integer;
   max_d double precision; max_i integer;
   d double precision;
   dx double precision; dy double precision; seg_len double precision;
BEGIN
   IF n <= 2 THEN RETURN p_geom; END IF;

   keep := array_fill(false, ARRAY[n]);
   keep[1] := true;
   keep[n] := true;

   stack_start := ARRAY[1];
   stack_end   := ARRAY[n];

   WHILE array_length(stack_start, 1) > 0 LOOP
      s := stack_start[array_length(stack_start, 1)];
      e := stack_end[array_length(stack_end, 1)];
      stack_start := stack_start[1:array_length(stack_start,1)-1];
      stack_end   := stack_end[1:array_length(stack_end,1)-1];

      max_d := 0;
      max_i := s;
      dx := (p_geom).lon[e] - (p_geom).lon[s];
      dy := (p_geom).lat[e] - (p_geom).lat[s];
      seg_len := sqrt(dx*dx + dy*dy);

      FOR i IN (s+1)..(e-1) LOOP
         IF seg_len = 0 THEN
            d := sqrt(((p_geom).lon[i] - (p_geom).lon[s])^2
                    + ((p_geom).lat[i] - (p_geom).lat[s])^2);
         ELSE
            d := abs(dy * ((p_geom).lon[i] - (p_geom).lon[s])
                   - dx * ((p_geom).lat[i] - (p_geom).lat[s])) / seg_len;
         END IF;
         IF d > max_d THEN max_d := d; max_i := i; END IF;
      END LOOP;

      IF max_d > p_tolerance THEN
         keep[max_i] := true;
         IF max_i - s > 1 THEN
            stack_start := stack_start || s;
            stack_end   := stack_end || max_i;
         END IF;
         IF e - max_i > 1 THEN
            stack_start := stack_start || max_i;
            stack_end   := stack_end || e;
         END IF;
      END IF;
   END LOOP;

   FOR i IN 1..n LOOP
      IF keep[i] THEN
         out_lon := out_lon || (p_geom).lon[i];
         out_lat := out_lat || (p_geom).lat[i];
      END IF;
   END LOOP;

   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ST_Simplify 3-arg overload: ST_Simplify(geometry, tolerance, preserveCollapsed)
-- GeoServer calls this signature.  The boolean controls whether to keep
-- collapsed geometries (points/lines from simplified polygons).
-- We accept the flag but delegate to the 2-arg version.
CREATE OR REPLACE FUNCTION ST_Simplify(
   p_geom geometry, p_tolerance double precision, p_preserve_collapsed boolean
)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_Simplify(p_geom, p_tolerance);
$$;

-- ST_Simplify 3-arg overload with numeric tolerance.
-- GeoServer's JDBC driver sends the tolerance as numeric, not double precision.
-- PostgreSQL will not implicitly cast numeric -> double precision for function
-- resolution, so we need this explicit overload.
CREATE OR REPLACE FUNCTION ST_Simplify(
   p_geom geometry, p_tolerance numeric, p_preserve_collapsed boolean
)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_Simplify(p_geom, p_tolerance::double precision);
$$;


-- ============================================================
-- 8)  ST_LineInterpolatePoint  —  PostGIS equivalent
--     Returns a point at a given fraction (0..1) along a line.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_LineInterpolatePoint(
   p_geom geometry, p_fraction double precision
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   total_len double precision := 0;
   target_len double precision;
   seg_len double precision;
   running double precision := 0;
   frac double precision;
   i integer;
BEGIN
   IF n < 2 THEN RETURN p_geom; END IF;

   -- Compute total length
   FOR i IN 1..n-1 LOOP
      total_len := total_len + sqrt(
         ((p_geom).lon[i+1] - (p_geom).lon[i])^2
       + ((p_geom).lat[i+1] - (p_geom).lat[i])^2);
   END LOOP;

   target_len := total_len * greatest(0.0, least(1.0, p_fraction));

   FOR i IN 1..n-1 LOOP
      seg_len := sqrt(
         ((p_geom).lon[i+1] - (p_geom).lon[i])^2
       + ((p_geom).lat[i+1] - (p_geom).lat[i])^2);
      IF running + seg_len >= target_len THEN
         IF seg_len = 0 THEN
            RETURN ST_MakePoint((p_geom).lon[i], (p_geom).lat[i]);
         END IF;
         frac := (target_len - running) / seg_len;
         RETURN ST_MakePoint(
            (p_geom).lon[i] + frac * ((p_geom).lon[i+1] - (p_geom).lon[i]),
            (p_geom).lat[i] + frac * ((p_geom).lat[i+1] - (p_geom).lat[i]));
      END IF;
      running := running + seg_len;
   END LOOP;

   -- Fraction = 1.0
   RETURN ST_MakePoint((p_geom).lon[n], (p_geom).lat[n]);
END;
$$;


-- ============================================================
-- 9)  ST_LineLocatePoint  —  PostGIS equivalent
--     Returns fraction (0..1) of the closest point on line
--     to the given point.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_LineLocatePoint(
   p_line geometry, p_point geometry
)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_line).lon, 1), 0);
   px double precision := (p_point).lon[1];
   py double precision := (p_point).lat[1];
   total_len double precision := 0;
   running double precision := 0;
   seg_len double precision;
   min_d double precision := 'Infinity';
   min_frac double precision := 0;
   d double precision;
   dx double precision; dy double precision; t double precision;
   i integer;
BEGIN
   IF n < 2 THEN RETURN 0; END IF;

   -- Total length
   FOR i IN 1..n-1 LOOP
      total_len := total_len + sqrt(
         ((p_line).lon[i+1] - (p_line).lon[i])^2
       + ((p_line).lat[i+1] - (p_line).lat[i])^2);
   END LOOP;
   IF total_len = 0 THEN RETURN 0; END IF;

   FOR i IN 1..n-1 LOOP
      dx := (p_line).lon[i+1] - (p_line).lon[i];
      dy := (p_line).lat[i+1] - (p_line).lat[i];
      seg_len := sqrt(dx*dx + dy*dy);

      IF seg_len = 0 THEN
         d := sqrt((px - (p_line).lon[i])^2 + (py - (p_line).lat[i])^2);
         t := 0;
      ELSE
         t := ((px - (p_line).lon[i])*dx + (py - (p_line).lat[i])*dy) / (seg_len*seg_len);
         t := greatest(0.0, least(1.0, t));
         d := sqrt(
            (px - ((p_line).lon[i] + t*dx))^2
          + (py - ((p_line).lat[i] + t*dy))^2);
      END IF;

      IF d < min_d THEN
         min_d := d;
         min_frac := (running + t * seg_len) / total_len;
      END IF;

      running := running + seg_len;
   END LOOP;

   RETURN min_frac;
END;
$$;


-- ============================================================
-- 10) ST_LineSubstring  —  PostGIS equivalent
--     Returns the portion of a line between two fractions.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_LineSubstring(
   p_geom geometry,
   p_start_frac double precision,
   p_end_frac double precision
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   total_len double precision := 0;
   start_len double precision;
   end_len double precision;
   running double precision := 0;
   seg_len double precision;
   frac double precision;
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   started boolean := false;
   i integer;
BEGIN
   IF n < 2 THEN RETURN p_geom; END IF;

   FOR i IN 1..n-1 LOOP
      total_len := total_len + sqrt(
         ((p_geom).lon[i+1] - (p_geom).lon[i])^2
       + ((p_geom).lat[i+1] - (p_geom).lat[i])^2);
   END LOOP;

   start_len := total_len * greatest(0.0, least(1.0, p_start_frac));
   end_len   := total_len * greatest(0.0, least(1.0, p_end_frac));

   FOR i IN 1..n-1 LOOP
      seg_len := sqrt(
         ((p_geom).lon[i+1] - (p_geom).lon[i])^2
       + ((p_geom).lat[i+1] - (p_geom).lat[i])^2);

      -- Start point
      IF NOT started AND running + seg_len >= start_len THEN
         started := true;
         IF seg_len > 0 THEN
            frac := (start_len - running) / seg_len;
         ELSE
            frac := 0;
         END IF;
         out_lon := out_lon || ((p_geom).lon[i] + frac * ((p_geom).lon[i+1] - (p_geom).lon[i]));
         out_lat := out_lat || ((p_geom).lat[i] + frac * ((p_geom).lat[i+1] - (p_geom).lat[i]));
      END IF;

      -- End point
      IF started AND running + seg_len >= end_len THEN
         IF seg_len > 0 THEN
            frac := (end_len - running) / seg_len;
         ELSE
            frac := 0;
         END IF;
         out_lon := out_lon || ((p_geom).lon[i] + frac * ((p_geom).lon[i+1] - (p_geom).lon[i]));
         out_lat := out_lat || ((p_geom).lat[i] + frac * ((p_geom).lat[i+1] - (p_geom).lat[i]));
         RETURN ROW(out_lon, out_lat)::geometry;
      END IF;

      -- Intermediate vertices
      IF started THEN
         out_lon := out_lon || (p_geom).lon[i+1];
         out_lat := out_lat || (p_geom).lat[i+1];
      END IF;

      running := running + seg_len;
   END LOOP;

   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 11) ST_GeomFromText  —  PostGIS ST_GeomFromText equivalent
--     Parses WKT strings: POINT, LINESTRING, POLYGON.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_GeomFromText(p_wkt text)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   wkt text := trim(upper(p_wkt));
   coords_str text;
   pairs text[];
   pair text;
   parts text[];
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   i integer;
BEGIN
   -- Normalize: collapse any spaces between keyword and '('
   wkt := regexp_replace(wkt, '^(POINT|LINESTRING|POLYGON|MULTIPOINT|MULTILINESTRING|MULTIPOLYGON)\s+\(', '\1(');

   IF wkt LIKE 'POINT(%' THEN
      coords_str := trim(substring(wkt FROM 'POINT\s*\((.+)\)'));
      coords_str := trim(coords_str);
      parts := string_to_array(coords_str, ' ');
      RETURN ST_MakePoint(parts[1]::double precision, parts[2]::double precision);

   ELSIF wkt LIKE 'LINESTRING(%' THEN
      coords_str := trim(substring(wkt FROM 'LINESTRING\s*\((.+)\)'));
      pairs := string_to_array(coords_str, ',');
      FOR i IN 1..array_length(pairs, 1) LOOP
         parts := string_to_array(trim(pairs[i]), ' ');
         out_lon := out_lon || parts[1]::double precision;
         out_lat := out_lat || parts[2]::double precision;
      END LOOP;
      RETURN ROW(out_lon, out_lat)::geometry;

   ELSIF wkt LIKE 'POLYGON(%' THEN
      -- Extract inner ring: POLYGON((x1 y1,x2 y2,...))
      coords_str := trim(substring(wkt FROM 'POLYGON\s*\(\((.+)\)\)'));
      pairs := string_to_array(coords_str, ',');
      FOR i IN 1..array_length(pairs, 1) LOOP
         parts := string_to_array(trim(pairs[i]), ' ');
         out_lon := out_lon || parts[1]::double precision;
         out_lat := out_lat || parts[2]::double precision;
      END LOOP;
      -- Remove closing vertex if it duplicates the first
      IF array_length(out_lon, 1) > 1
         AND out_lon[1] = out_lon[array_length(out_lon, 1)]
         AND out_lat[1] = out_lat[array_length(out_lat, 1)] THEN
         out_lon := out_lon[1:array_length(out_lon,1)-1];
         out_lat := out_lat[1:array_length(out_lat,1)-1];
      END IF;
      RETURN ROW(out_lon, out_lat)::geometry;

   ELSE
      RAISE EXCEPTION 'ST_GeomFromText: unsupported WKT type: %', p_wkt;
   END IF;
END;
$$;

-- Example:
--   SELECT ST_GeomFromText('POINT(-111.97 40.52)');
--   SELECT ST_GeomFromText('POLYGON((-112 40,-111 40,-111 41,-112 41,-112 40))');


-- ============================================================
-- 12) ST_GeomFromGeoJSON  —  PostGIS ST_GeomFromGeoJSON
--     Parses a GeoJSON geometry object (text or jsonb).
-- ============================================================
CREATE OR REPLACE FUNCTION ST_GeomFromGeoJSON(p_json text)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   j jsonb := p_json::jsonb;
   gtype text;
   coords jsonb;
   ring jsonb;
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   i integer;
BEGIN
   gtype := j->>'type';

   IF gtype = 'Point' THEN
      coords := j->'coordinates';
      RETURN ST_MakePoint((coords->>0)::double precision,
                           (coords->>1)::double precision);

   ELSIF gtype = 'LineString' THEN
      coords := j->'coordinates';
      FOR i IN 0..jsonb_array_length(coords)-1 LOOP
         out_lon := out_lon || (coords->i->>0)::double precision;
         out_lat := out_lat || (coords->i->>1)::double precision;
      END LOOP;
      RETURN ROW(out_lon, out_lat)::geometry;

   ELSIF gtype = 'Polygon' THEN
      ring := j->'coordinates'->0;  -- exterior ring only
      FOR i IN 0..jsonb_array_length(ring)-1 LOOP
         out_lon := out_lon || (ring->i->>0)::double precision;
         out_lat := out_lat || (ring->i->>1)::double precision;
      END LOOP;
      -- Remove closing vertex
      IF array_length(out_lon, 1) > 1
         AND out_lon[1] = out_lon[array_length(out_lon, 1)]
         AND out_lat[1] = out_lat[array_length(out_lat, 1)] THEN
         out_lon := out_lon[1:array_length(out_lon,1)-1];
         out_lat := out_lat[1:array_length(out_lat,1)-1];
      END IF;
      RETURN ROW(out_lon, out_lat)::geometry;

   ELSE
      RAISE EXCEPTION 'ST_GeomFromGeoJSON: unsupported type: %', gtype;
   END IF;
END;
$$;

-- Example:
--   SELECT ST_GeomFromGeoJSON('{"type":"Point","coordinates":[-111.97,40.52]}');


-- ============================================================
-- 13) ST_Rotate  —  PostGIS ST_Rotate equivalent
--     Rotates geometry by angle (radians) around a center point.
--     Default center: origin (0,0).
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Rotate(
   p_geom  geometry,
   p_angle double precision,
   p_cx    double precision DEFAULT 0,
   p_cy    double precision DEFAULT 0
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   cos_a double precision := cos(p_angle);
   sin_a double precision := sin(p_angle);
   dx double precision; dy double precision;
   i integer;
BEGIN
   FOR i IN 1..n LOOP
      dx := (p_geom).lon[i] - p_cx;
      dy := (p_geom).lat[i] - p_cy;
      out_lon := out_lon || (p_cx + dx * cos_a - dy * sin_a);
      out_lat := out_lat || (p_cy + dx * sin_a + dy * cos_a);
   END LOOP;
   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 14) ST_Affine  —  PostGIS ST_Affine equivalent (2D)
--     Applies 2D affine transformation:
--       x' = a*x + b*y + xoff
--       y' = d*x + e*y + yoff
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Affine(
   p_geom geometry,
   p_a double precision, p_b double precision,
   p_d double precision, p_e double precision,
   p_xoff double precision, p_yoff double precision
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   i integer;
BEGIN
   FOR i IN 1..n LOOP
      out_lon := out_lon || (p_a * (p_geom).lon[i] + p_b * (p_geom).lat[i] + p_xoff);
      out_lat := out_lat || (p_d * (p_geom).lon[i] + p_e * (p_geom).lat[i] + p_yoff);
   END LOOP;
   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 15) ST_DumpPoints  —  PostGIS ST_DumpPoints equivalent
--     Returns a set of (path, geom) for each vertex.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_DumpPoints(p_geom geometry)
RETURNS TABLE(path integer[], geom geometry)
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   i integer;
BEGIN
   FOR i IN 1..n LOOP
      path := ARRAY[i];
      geom := ST_MakePoint((p_geom).lon[i], (p_geom).lat[i]);
      RETURN NEXT;
   END LOOP;
END;
$$;


-- ============================================================
-- 16) ST_DumpSegments  —  PostGIS ST_DumpSegments equivalent
--     Returns a set of (path, geom) for each edge segment.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_DumpSegments(p_geom geometry)
RETURNS TABLE(path integer[], geom geometry)
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   i integer; i2 integer;
BEGIN
   FOR i IN 1..n LOOP
      i2 := CASE WHEN i = n THEN 1 ELSE i + 1 END;
      path := ARRAY[i];
      geom := ROW(
         ARRAY[(p_geom).lon[i], (p_geom).lon[i2]],
         ARRAY[(p_geom).lat[i], (p_geom).lat[i2]]
      )::geometry;
      RETURN NEXT;
   END LOOP;
END;
$$;


-- ============================================================
-- 17) ST_SnapToGrid  —  PostGIS ST_SnapToGrid equivalent
--     Rounds all coordinates to the nearest multiple of size.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_SnapToGrid(
   p_geom geometry, p_size double precision
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   i integer;
BEGIN
   IF p_size <= 0 THEN RETURN p_geom; END IF;
   FOR i IN 1..n LOOP
      out_lon := out_lon || (round((p_geom).lon[i] / p_size) * p_size);
      out_lat := out_lat || (round((p_geom).lat[i] / p_size) * p_size);
   END LOOP;
   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 18) ST_RemoveRepeatedPoints  —  PostGIS equivalent
--     Removes consecutive duplicate vertices.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_RemoveRepeatedPoints(
   p_geom geometry, p_tolerance double precision DEFAULT 0
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   prev_lon double precision; prev_lat double precision;
   d double precision;
   i integer;
BEGIN
   IF n = 0 THEN RETURN p_geom; END IF;
   out_lon := ARRAY[(p_geom).lon[1]];
   out_lat := ARRAY[(p_geom).lat[1]];
   prev_lon := (p_geom).lon[1];
   prev_lat := (p_geom).lat[1];

   FOR i IN 2..n LOOP
      d := sqrt(((p_geom).lon[i] - prev_lon)^2
              + ((p_geom).lat[i] - prev_lat)^2);
      IF d > p_tolerance THEN
         out_lon := out_lon || (p_geom).lon[i];
         out_lat := out_lat || (p_geom).lat[i];
         prev_lon := (p_geom).lon[i];
         prev_lat := (p_geom).lat[i];
      END IF;
   END LOOP;

   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 19) ST_Segmentize  —  PostGIS ST_Segmentize equivalent
--     Adds intermediate vertices so that no segment exceeds
--     max_segment_length (planar).
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Segmentize(
   p_geom geometry, p_max_len double precision
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   seg_len double precision;
   num_segs integer;
   i integer; j integer;
   frac double precision;
BEGIN
   IF n = 0 OR p_max_len <= 0 THEN RETURN p_geom; END IF;

   out_lon := ARRAY[(p_geom).lon[1]];
   out_lat := ARRAY[(p_geom).lat[1]];

   FOR i IN 1..n-1 LOOP
      seg_len := sqrt(
         ((p_geom).lon[i+1] - (p_geom).lon[i])^2
       + ((p_geom).lat[i+1] - (p_geom).lat[i])^2);

      IF seg_len > p_max_len THEN
         num_segs := ceil(seg_len / p_max_len)::integer;
         FOR j IN 1..num_segs-1 LOOP
            frac := j::double precision / num_segs::double precision;
            out_lon := out_lon || ((p_geom).lon[i] + frac * ((p_geom).lon[i+1] - (p_geom).lon[i]));
            out_lat := out_lat || ((p_geom).lat[i] + frac * ((p_geom).lat[i+1] - (p_geom).lat[i]));
         END LOOP;
      END IF;

      out_lon := out_lon || (p_geom).lon[i+1];
      out_lat := out_lat || (p_geom).lat[i+1];
   END LOOP;

   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 20) ST_ClipByBox2D  —  PostGIS ST_ClipByBox2D equivalent
--     Clips a polygon to an axis-aligned bounding box using
--     the Sutherland-Hodgman algorithm.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_ClipByBox2D(
   p_geom geometry,
   p_xmin double precision, p_ymin double precision,
   p_xmax double precision, p_ymax double precision
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   -- We clip against each of the 4 edges in sequence
   in_lon  double precision[];
   in_lat  double precision[];
   out_lon double precision[];
   out_lat double precision[];
   n integer;
   i integer; i2 integer;
   x1 double precision; y1 double precision;
   x2 double precision; y2 double precision;
   t double precision;
   edge integer;  -- 1=left, 2=right, 3=bottom, 4=top
BEGIN
   in_lon := (p_geom).lon;
   in_lat := (p_geom).lat;

   FOR edge IN 1..4 LOOP
      n := coalesce(array_length(in_lon, 1), 0);
      IF n = 0 THEN RETURN ROW(ARRAY[]::double precision[], ARRAY[]::double precision[])::geometry; END IF;

      out_lon := ARRAY[]::double precision[];
      out_lat := ARRAY[]::double precision[];

      FOR i IN 1..n LOOP
         i2 := CASE WHEN i = n THEN 1 ELSE i + 1 END;
         x1 := in_lon[i];  y1 := in_lat[i];
         x2 := in_lon[i2]; y2 := in_lat[i2];

         CASE edge
            WHEN 1 THEN  -- left: x >= xmin
               IF x1 >= p_xmin THEN
                  out_lon := out_lon || x1; out_lat := out_lat || y1;
                  IF x2 < p_xmin THEN
                     t := (p_xmin - x1) / nullif(x2 - x1, 0);
                     IF t IS NOT NULL THEN
                        out_lon := out_lon || p_xmin;
                        out_lat := out_lat || (y1 + t * (y2 - y1));
                     END IF;
                  END IF;
               ELSIF x2 >= p_xmin THEN
                  t := (p_xmin - x1) / nullif(x2 - x1, 0);
                  IF t IS NOT NULL THEN
                     out_lon := out_lon || p_xmin;
                     out_lat := out_lat || (y1 + t * (y2 - y1));
                  END IF;
               END IF;

            WHEN 2 THEN  -- right: x <= xmax
               IF x1 <= p_xmax THEN
                  out_lon := out_lon || x1; out_lat := out_lat || y1;
                  IF x2 > p_xmax THEN
                     t := (p_xmax - x1) / nullif(x2 - x1, 0);
                     IF t IS NOT NULL THEN
                        out_lon := out_lon || p_xmax;
                        out_lat := out_lat || (y1 + t * (y2 - y1));
                     END IF;
                  END IF;
               ELSIF x2 <= p_xmax THEN
                  t := (p_xmax - x1) / nullif(x2 - x1, 0);
                  IF t IS NOT NULL THEN
                     out_lon := out_lon || p_xmax;
                     out_lat := out_lat || (y1 + t * (y2 - y1));
                  END IF;
               END IF;

            WHEN 3 THEN  -- bottom: y >= ymin
               IF y1 >= p_ymin THEN
                  out_lon := out_lon || x1; out_lat := out_lat || y1;
                  IF y2 < p_ymin THEN
                     t := (p_ymin - y1) / nullif(y2 - y1, 0);
                     IF t IS NOT NULL THEN
                        out_lon := out_lon || (x1 + t * (x2 - x1));
                        out_lat := out_lat || p_ymin;
                     END IF;
                  END IF;
               ELSIF y2 >= p_ymin THEN
                  t := (p_ymin - y1) / nullif(y2 - y1, 0);
                  IF t IS NOT NULL THEN
                     out_lon := out_lon || (x1 + t * (x2 - x1));
                     out_lat := out_lat || p_ymin;
                  END IF;
               END IF;

            WHEN 4 THEN  -- top: y <= ymax
               IF y1 <= p_ymax THEN
                  out_lon := out_lon || x1; out_lat := out_lat || y1;
                  IF y2 > p_ymax THEN
                     t := (p_ymax - y1) / nullif(y2 - y1, 0);
                     IF t IS NOT NULL THEN
                        out_lon := out_lon || (x1 + t * (x2 - x1));
                        out_lat := out_lat || p_ymax;
                     END IF;
                  END IF;
               ELSIF y2 <= p_ymax THEN
                  t := (p_ymax - y1) / nullif(y2 - y1, 0);
                  IF t IS NOT NULL THEN
                     out_lon := out_lon || (x1 + t * (x2 - x1));
                     out_lat := out_lat || p_ymax;
                  END IF;
               END IF;
         END CASE;
      END LOOP;

      in_lon := out_lon;
      in_lat := out_lat;
   END LOOP;

   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;

-- Geometry overload (takes a box geometry)
CREATE OR REPLACE FUNCTION ST_ClipByBox2D(
   p_geom geometry, p_box geometry
)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_ClipByBox2D(
      p_geom,
      ST_XMin(p_box), ST_YMin(p_box),
      ST_XMax(p_box), ST_YMax(p_box));
$$;


-- ============================================================
-- 21) ST_GeneratePoints  —  PostGIS ST_GeneratePoints
--     Generates N random points inside a polygon using
--     rejection sampling.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_GeneratePoints(
   p_geom geometry, p_npoints integer
)
RETURNS SETOF geometry
LANGUAGE plpgsql VOLATILE
AS $$
DECLARE
   xmin double precision := ST_XMin(p_geom);
   xmax double precision := ST_XMax(p_geom);
   ymin double precision := ST_YMin(p_geom);
   ymax double precision := ST_YMax(p_geom);
   count integer := 0;
   px double precision; py double precision;
BEGIN
   WHILE count < p_npoints LOOP
      px := xmin + random() * (xmax - xmin);
      py := ymin + random() * (ymax - ymin);
      IF point_in_polygon(px, py, (p_geom).lon, (p_geom).lat) THEN
         RETURN NEXT ST_MakePoint(px, py);
         count := count + 1;
      END IF;
   END LOOP;
END;
$$;


-- ============================================================
-- 22) ST_ChaikinSmoothing  —  PostGIS ST_ChaikinSmoothing
--     Applies Chaikin's corner-cutting algorithm.
--     nIterations defaults to 1.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_ChaikinSmoothing(
   p_geom geometry, p_niterations integer DEFAULT 1
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   cur_lon double precision[] := (p_geom).lon;
   cur_lat double precision[] := (p_geom).lat;
   new_lon double precision[];
   new_lat double precision[];
   n integer;
   i integer; iter integer;
BEGIN
   FOR iter IN 1..p_niterations LOOP
      n := array_length(cur_lon, 1);
      IF n < 2 THEN RETURN ROW(cur_lon, cur_lat)::geometry; END IF;

      new_lon := ARRAY[]::double precision[];
      new_lat := ARRAY[]::double precision[];

      FOR i IN 1..n-1 LOOP
         -- Q point (1/4 from start)
         new_lon := new_lon || (0.75 * cur_lon[i] + 0.25 * cur_lon[i+1]);
         new_lat := new_lat || (0.75 * cur_lat[i] + 0.25 * cur_lat[i+1]);
         -- R point (3/4 from start)
         new_lon := new_lon || (0.25 * cur_lon[i] + 0.75 * cur_lon[i+1]);
         new_lat := new_lat || (0.25 * cur_lat[i] + 0.75 * cur_lat[i+1]);
      END LOOP;

      cur_lon := new_lon;
      cur_lat := new_lat;
   END LOOP;

   RETURN ROW(cur_lon, cur_lat)::geometry;
END;
$$;


-- ============================================================
-- 23) ST_Expand  —  PostGIS ST_Expand equivalent
--     Expands a geometry's bounding box by a given amount
--     in all directions, returning a new bbox polygon.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Expand(
   p_geom geometry, p_amount double precision
)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_MakeEnvelope(
      ST_XMin(p_geom) - p_amount,
      ST_YMin(p_geom) - p_amount,
      ST_XMax(p_geom) + p_amount,
      ST_YMax(p_geom) + p_amount
   );
$$;


-- ============================================================
-- 24) ST_Summary  —  PostGIS ST_Summary equivalent
--     Returns a text summary describing the geometry.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Summary(p_geom geometry)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   gtype text;
BEGIN
   gtype := GeometryType(p_geom);
   RETURN gtype || '[' || n || ' vertices'
      || ', bbox(' || ST_XMin(p_geom)::text || ' '
      || ST_YMin(p_geom)::text || ', '
      || ST_XMax(p_geom)::text || ' '
      || ST_YMax(p_geom)::text || ')]';
END;
$$;

-- Example:
--   SELECT ST_Summary(ST_MakeEnvelope(-112, 40, -111, 41));
--   -- Returns: 'POLYGON[4 vertices, bbox(-112 40, -111 41)]'


-- ============================================================
-- 25) ST_AddPoint  —  PostGIS ST_AddPoint equivalent
--     Adds a point to a geometry at a given position (0-based).
--     If position is omitted, appends to the end.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_AddPoint(
   p_geom geometry, p_point geometry,
   p_position integer DEFAULT -1
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   pos integer;
   out_lon double precision[];
   out_lat double precision[];
BEGIN
   IF p_position < 0 THEN
      pos := n + 1;  -- append
   ELSE
      pos := p_position + 1;  -- convert 0-based to 1-based
   END IF;

   out_lon := (p_geom).lon[1:pos-1]
           || (p_point).lon
           || (p_geom).lon[pos:n];
   out_lat := (p_geom).lat[1:pos-1]
           || (p_point).lat
           || (p_geom).lat[pos:n];

   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 26) ST_RemovePoint  —  PostGIS ST_RemovePoint equivalent
--     Removes the vertex at the given index (0-based).
-- ============================================================
CREATE OR REPLACE FUNCTION ST_RemovePoint(
   p_geom geometry, p_index integer
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   idx integer := p_index + 1;  -- 0-based to 1-based
   out_lon double precision[];
   out_lat double precision[];
BEGIN
   IF idx < 1 OR idx > n THEN
      RAISE EXCEPTION 'ST_RemovePoint: index % out of range [0..%]', p_index, n-1;
   END IF;

   IF idx = 1 THEN
      out_lon := (p_geom).lon[2:n];
      out_lat := (p_geom).lat[2:n];
   ELSIF idx = n THEN
      out_lon := (p_geom).lon[1:n-1];
      out_lat := (p_geom).lat[1:n-1];
   ELSE
      out_lon := (p_geom).lon[1:idx-1] || (p_geom).lon[idx+1:n];
      out_lat := (p_geom).lat[1:idx-1] || (p_geom).lat[idx+1:n];
   END IF;

   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 27) ST_SetPoint  —  PostGIS ST_SetPoint equivalent
--     Replaces the vertex at the given index (0-based).
-- ============================================================
CREATE OR REPLACE FUNCTION ST_SetPoint(
   p_geom geometry, p_index integer, p_point geometry
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   idx integer := p_index + 1;
   out_lon double precision[] := (p_geom).lon;
   out_lat double precision[] := (p_geom).lat;
BEGIN
   IF idx < 1 OR idx > n THEN
      RAISE EXCEPTION 'ST_SetPoint: index % out of range [0..%]', p_index, n-1;
   END IF;
   out_lon[idx] := (p_point).lon[1];
   out_lat[idx] := (p_point).lat[1];
   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 28) ST_Project  —  PostGIS ST_Project equivalent
--     Projects a point by a distance (in meters) and
--     azimuth (in radians, clockwise from north).
--     Uses spherical approximation.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Project(
   p_point geometry,
   p_distance double precision,   -- meters
   p_azimuth  double precision    -- radians
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   R constant double precision := 6371000.0;
   lat1 double precision := radians((p_point).lat[1]);
   lon1 double precision := radians((p_point).lon[1]);
   d_over_R double precision := p_distance / R;
   lat2 double precision;
   lon2 double precision;
BEGIN
   lat2 := asin(sin(lat1) * cos(d_over_R)
              + cos(lat1) * sin(d_over_R) * cos(p_azimuth));
   lon2 := lon1 + atan2(
      sin(p_azimuth) * sin(d_over_R) * cos(lat1),
      cos(d_over_R) - sin(lat1) * sin(lat2));
   RETURN ST_MakePoint(degrees(lon2), degrees(lat2));
END;
$$;

-- Example:
--   -- Project 1000m due north from Denver
--   SELECT ST_AsText(
--      ST_Project(ST_MakePoint(-104.9903, 39.7392), 1000, 0));
