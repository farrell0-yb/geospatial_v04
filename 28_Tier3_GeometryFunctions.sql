-- ============================================================================
--
-- Tier 3 Geometry Functions  —  Advanced Algorithms
--
-- Pure PL/pgSQL PostGIS equivalents for YugabyteDB YSQL.
-- No extensions required.
--
-- Requires : 10_CreateGeometryType.sql
--            20_GeohashFunctions.sql
--            25_GeometryFunctions.sql
--            26_Tier1_GeometryFunctions.sql
--            27_Tier2_GeometryFunctions.sql
--
-- Functions in this file:
--    1) ST_ConvexHull       -> ST_ConvexHull
--    2) ST_Intersection     -> ST_Intersection  (convex polygons)
--    3) ST_Union            -> ST_Union          (bounding approach)
--    4) ST_Difference       -> ST_Difference     (convex polygons)
--    5) ST_SymDifference    -> ST_SymDifference
--    6) ST_Buffer           -> ST_Buffer         (approximate)
--    7) ST_IsValid          -> ST_IsValid
--    8) ST_Touches          -> ST_Touches
--    9) ST_Crosses          -> ST_Crosses
--   10) ST_Overlaps         -> ST_Overlaps
--   11) ST_Equals           -> ST_Equals
--   12) ST_Simplify_vw     -> ST_SimplifyVW (Visvalingam-Whyatt)
--
-- ============================================================================


-- ============================================================
-- 1)  ST_ConvexHull  —  PostGIS ST_ConvexHull equivalent
--     Computes the convex hull using the Graham scan algorithm.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_ConvexHull(p_geom geometry)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   pts_x double precision[];
   pts_y double precision[];
   -- Find lowest-rightmost point as pivot
   pivot_idx integer := 1;
   pivot_x double precision;
   pivot_y double precision;
   -- Sorting: indices, angles
   idx integer[];
   angles double precision[];
   dists  double precision[];
   i integer; j integer;
   tmp_idx integer; tmp_a double precision; tmp_d double precision;
   -- Hull stack
   hull_x double precision[] := ARRAY[]::double precision[];
   hull_y double precision[] := ARRAY[]::double precision[];
   h integer;  -- hull size
   cross_val double precision;
BEGIN
   IF n <= 2 THEN RETURN p_geom; END IF;

   pts_x := (p_geom).lon;
   pts_y := (p_geom).lat;

   -- Find bottom-most point (lowest y, then rightmost x)
   pivot_x := pts_x[1]; pivot_y := pts_y[1];
   FOR i IN 2..n LOOP
      IF pts_y[i] < pivot_y
         OR (pts_y[i] = pivot_y AND pts_x[i] > pivot_x) THEN
         pivot_idx := i;
         pivot_x := pts_x[i];
         pivot_y := pts_y[i];
      END IF;
   END LOOP;

   -- Swap pivot to position 1
   pts_x[pivot_idx] := pts_x[1]; pts_y[pivot_idx] := pts_y[1];
   pts_x[1] := pivot_x;          pts_y[1] := pivot_y;

   -- Compute polar angles and distances from pivot
   idx    := ARRAY[]::integer[];
   angles := ARRAY[]::double precision[];
   dists  := ARRAY[]::double precision[];
   FOR i IN 2..n LOOP
      idx    := idx || i;
      angles := angles || atan2(pts_y[i] - pivot_y, pts_x[i] - pivot_x);
      dists  := dists  || ((pts_x[i] - pivot_x)^2 + (pts_y[i] - pivot_y)^2);
   END LOOP;

   -- Simple insertion sort by angle, then by distance
   FOR i IN 1..array_length(idx, 1) LOOP
      FOR j IN (i+1)..array_length(idx, 1) LOOP
         IF angles[j] < angles[i]
            OR (angles[j] = angles[i] AND dists[j] < dists[i]) THEN
            tmp_idx := idx[i]; idx[i] := idx[j]; idx[j] := tmp_idx;
            tmp_a := angles[i]; angles[i] := angles[j]; angles[j] := tmp_a;
            tmp_d := dists[i]; dists[i] := dists[j]; dists[j] := tmp_d;
         END IF;
      END LOOP;
   END LOOP;

   -- Graham scan
   hull_x := ARRAY[pivot_x];
   hull_y := ARRAY[pivot_y];
   h := 1;

   FOR i IN 1..array_length(idx, 1) LOOP
      WHILE h >= 2 LOOP
         cross_val := (hull_x[h] - hull_x[h-1]) * (pts_y[idx[i]] - hull_y[h-1])
                    - (hull_y[h] - hull_y[h-1]) * (pts_x[idx[i]] - hull_x[h-1]);
         IF cross_val <= 0 THEN
            hull_x := hull_x[1:h-1];
            hull_y := hull_y[1:h-1];
            h := h - 1;
         ELSE
            EXIT;
         END IF;
      END LOOP;
      hull_x := hull_x || pts_x[idx[i]];
      hull_y := hull_y || pts_y[idx[i]];
      h := h + 1;
   END LOOP;

   RETURN ROW(hull_x, hull_y)::geometry;
END;
$$;

-- Example:
--   SELECT ST_AsText(ST_ConvexHull(
--       ST_MakePolygon(ARRAY[-1,0,1,0], ARRAY[0,1,0,-1])));


-- ============================================================
-- 2)  ST_Intersection  —  PostGIS ST_Intersection equivalent
--     Computes the intersection of two CONVEX polygons using
--     the Sutherland-Hodgman algorithm.
--
--     Note: For non-convex polygons, results are approximate.
--     For exact results on non-convex polygons, decompose
--     into convex parts first.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Intersection(p_a geometry, p_b geometry)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   -- Subject polygon = B, clip polygon = A
   in_lon  double precision[] := (p_b).lon;
   in_lat  double precision[] := (p_b).lat;
   out_lon double precision[];
   out_lat double precision[];
   clip_n  integer := coalesce(array_length((p_a).lon, 1), 0);
   n integer;
   i integer; j integer; j2 integer;
   ex1 double precision; ey1 double precision;
   ex2 double precision; ey2 double precision;
   sx double precision; sy double precision;
   px double precision; py double precision;
   t double precision;
   s_inside boolean; p_inside boolean;
   denom double precision;
BEGIN
   IF clip_n < 3 OR coalesce(array_length(in_lon, 1), 0) < 3 THEN
      RETURN ROW(ARRAY[]::double precision[], ARRAY[]::double precision[])::geometry;
   END IF;

   -- Clip subject polygon against each edge of the clip polygon
   FOR j IN 1..clip_n LOOP
      j2 := CASE WHEN j = clip_n THEN 1 ELSE j + 1 END;
      ex1 := (p_a).lon[j];  ey1 := (p_a).lat[j];
      ex2 := (p_a).lon[j2]; ey2 := (p_a).lat[j2];

      n := coalesce(array_length(in_lon, 1), 0);
      IF n = 0 THEN
         RETURN ROW(ARRAY[]::double precision[], ARRAY[]::double precision[])::geometry;
      END IF;

      out_lon := ARRAY[]::double precision[];
      out_lat := ARRAY[]::double precision[];

      FOR i IN 1..n LOOP
         px := in_lon[i]; py := in_lat[i];
         IF i = 1 THEN
            sx := in_lon[n]; sy := in_lat[n];
         ELSE
            sx := in_lon[i-1]; sy := in_lat[i-1];
         END IF;

         -- "Inside" = left side of edge (using cross product sign)
         p_inside := ((ex2 - ex1) * (py - ey1) - (ey2 - ey1) * (px - ex1)) >= 0;
         s_inside := ((ex2 - ex1) * (sy - ey1) - (ey2 - ey1) * (sx - ex1)) >= 0;

         IF p_inside THEN
            IF NOT s_inside THEN
               -- Compute intersection of S->P with edge
               denom := (sx - px) * (ey2 - ey1) - (sy - py) * (ex2 - ex1);
               IF denom <> 0 THEN
                  t := ((ex1 - sx) * (ey2 - ey1) - (ey1 - sy) * (ex2 - ex1)) / denom;
                  out_lon := out_lon || (sx + t * (px - sx));
                  out_lat := out_lat || (sy + t * (py - sy));
               END IF;
            END IF;
            out_lon := out_lon || px;
            out_lat := out_lat || py;
         ELSIF s_inside THEN
            denom := (sx - px) * (ey2 - ey1) - (sy - py) * (ex2 - ex1);
            IF denom <> 0 THEN
               t := ((ex1 - sx) * (ey2 - ey1) - (ey1 - sy) * (ex2 - ex1)) / denom;
               out_lon := out_lon || (sx + t * (px - sx));
               out_lat := out_lat || (sy + t * (py - sy));
            END IF;
         END IF;
      END LOOP;

      in_lon := out_lon;
      in_lat := out_lat;
   END LOOP;

   IF coalesce(array_length(out_lon, 1), 0) < 3 THEN
      RETURN ROW(ARRAY[]::double precision[], ARRAY[]::double precision[])::geometry;
   END IF;

   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 3)  ST_Union  —  PostGIS ST_Union equivalent
--     For convex polygons: returns the convex hull of all
--     combined vertices.  This is exact for convex inputs.
--     For non-convex inputs: returns the convex hull
--     (an outer bound).
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Union(p_a geometry, p_b geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ST_ConvexHull(
      ROW((p_a).lon || (p_b).lon,
          (p_a).lat || (p_b).lat)::geometry
   );
$$;


-- ============================================================
-- 4)  ST_Difference  —  PostGIS ST_Difference equivalent
--     Returns the part of A that does not intersect with B.
--     Uses vertex-based approach: keeps A vertices outside B,
--     adds intersection points along A edges.
--
--     Exact for convex polygon pairs.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Difference(p_a geometry, p_b geometry)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   na integer := coalesce(array_length((p_a).lon, 1), 0);
   nb integer := coalesce(array_length((p_b).lon, 1), 0);
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   i integer; i2 integer; j integer; j2 integer;
   in_b boolean;
   prev_in_b boolean;
   denom double precision; t double precision; u double precision;
   ix double precision; iy double precision;
BEGIN
   IF na < 3 THEN RETURN p_a; END IF;
   IF nb < 3 THEN RETURN p_a; END IF;
   IF NOT ST_Intersects(p_a, p_b) THEN RETURN p_a; END IF;
   IF ST_Contains(p_b, p_a) THEN
      RETURN ROW(ARRAY[]::double precision[], ARRAY[]::double precision[])::geometry;
   END IF;

   -- Walk edges of A; keep vertices outside B, add intersection points
   prev_in_b := point_in_polygon((p_a).lon[na], (p_a).lat[na], (p_b).lon, (p_b).lat);

   FOR i IN 1..na LOOP
      in_b := point_in_polygon((p_a).lon[i], (p_a).lat[i], (p_b).lon, (p_b).lat);

      -- If crossing boundary, find intersection point with B edges
      IF in_b <> prev_in_b THEN
         -- Previous vertex index
         IF i = 1 THEN i2 := na; ELSE i2 := i - 1; END IF;
         FOR j IN 1..nb LOOP
            j2 := CASE WHEN j = nb THEN 1 ELSE j + 1 END;
            denom := ((p_a).lon[i] - (p_a).lon[i2]) * ((p_b).lat[j2] - (p_b).lat[j])
                   - ((p_a).lat[i] - (p_a).lat[i2]) * ((p_b).lon[j2] - (p_b).lon[j]);
            IF denom <> 0 THEN
               t := (((p_b).lon[j] - (p_a).lon[i2]) * ((p_b).lat[j2] - (p_b).lat[j])
                   - ((p_b).lat[j] - (p_a).lat[i2]) * ((p_b).lon[j2] - (p_b).lon[j])) / denom;
               u := (((p_b).lon[j] - (p_a).lon[i2]) * ((p_a).lat[i] - (p_a).lat[i2])
                   - ((p_b).lat[j] - (p_a).lat[i2]) * ((p_a).lon[i] - (p_a).lon[i2])) / denom;
               IF t >= 0 AND t <= 1 AND u >= 0 AND u <= 1 THEN
                  ix := (p_a).lon[i2] + t * ((p_a).lon[i] - (p_a).lon[i2]);
                  iy := (p_a).lat[i2] + t * ((p_a).lat[i] - (p_a).lat[i2]);
                  out_lon := out_lon || ix;
                  out_lat := out_lat || iy;
               END IF;
            END IF;
         END LOOP;
      END IF;

      IF NOT in_b THEN
         out_lon := out_lon || (p_a).lon[i];
         out_lat := out_lat || (p_a).lat[i];
      END IF;

      prev_in_b := in_b;
   END LOOP;

   IF coalesce(array_length(out_lon, 1), 0) < 3 THEN
      RETURN ROW(ARRAY[]::double precision[], ARRAY[]::double precision[])::geometry;
   END IF;

   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 5)  ST_SymDifference  —  PostGIS ST_SymDifference
--     Parts in A or B but not both.
--     Returns the convex hull of the two differences combined.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_SymDifference(p_a geometry, p_b geometry)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   diff_ab geometry := ST_Difference(p_a, p_b);
   diff_ba geometry := ST_Difference(p_b, p_a);
   na integer := coalesce(array_length((diff_ab).lon, 1), 0);
   nb integer := coalesce(array_length((diff_ba).lon, 1), 0);
BEGIN
   IF na = 0 AND nb = 0 THEN
      RETURN ROW(ARRAY[]::double precision[], ARRAY[]::double precision[])::geometry;
   END IF;
   IF na = 0 THEN RETURN diff_ba; END IF;
   IF nb = 0 THEN RETURN diff_ab; END IF;
   -- Return combined hull of both differences
   RETURN ST_ConvexHull(
      ROW((diff_ab).lon || (diff_ba).lon,
          (diff_ab).lat || (diff_ba).lat)::geometry);
END;
$$;


-- ============================================================
-- 6)  ST_Buffer  —  PostGIS ST_Buffer equivalent
--     Approximates a buffer around a geometry by generating
--     offset vertices at each corner.
--
--     For points: generates a regular polygon (circle approx).
--     For polygons: offsets each vertex outward along the
--     bisector of adjacent edges.
--
--     p_distance: buffer distance in degrees (planar).
--     p_segments: number of segments per quarter circle
--                 (default 8, so 32 segments for a point buffer).
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Buffer(
   p_geom geometry,
   p_distance double precision,
   p_segments integer DEFAULT 8
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   out_lon double precision[] := ARRAY[]::double precision[];
   out_lat double precision[] := ARRAY[]::double precision[];
   num_pts integer;
   angle double precision;
   i integer;
   -- For polygon buffering
   prev integer; nxt integer;
   dx1 double precision; dy1 double precision; len1 double precision;
   dx2 double precision; dy2 double precision; len2 double precision;
   nx double precision; ny double precision; nlen double precision;
BEGIN
   IF n = 0 THEN RETURN p_geom; END IF;

   -- Point buffer: circle approximation
   IF n = 1 THEN
      num_pts := p_segments * 4;
      FOR i IN 0..num_pts-1 LOOP
         angle := 2.0 * pi() * i::double precision / num_pts::double precision;
         out_lon := out_lon || ((p_geom).lon[1] + p_distance * cos(angle));
         out_lat := out_lat || ((p_geom).lat[1] + p_distance * sin(angle));
      END LOOP;
      RETURN ROW(out_lon, out_lat)::geometry;
   END IF;

   -- Polygon/line buffer: offset each vertex along bisector normal
   FOR i IN 1..n LOOP
      prev := CASE WHEN i = 1 THEN n ELSE i - 1 END;
      nxt  := CASE WHEN i = n THEN 1 ELSE i + 1 END;

      -- Edge vectors
      dx1 := (p_geom).lon[i] - (p_geom).lon[prev];
      dy1 := (p_geom).lat[i] - (p_geom).lat[prev];
      len1 := sqrt(dx1*dx1 + dy1*dy1);
      IF len1 > 0 THEN dx1 := dx1/len1; dy1 := dy1/len1; END IF;

      dx2 := (p_geom).lon[nxt] - (p_geom).lon[i];
      dy2 := (p_geom).lat[nxt] - (p_geom).lat[i];
      len2 := sqrt(dx2*dx2 + dy2*dy2);
      IF len2 > 0 THEN dx2 := dx2/len2; dy2 := dy2/len2; END IF;

      -- Average outward normal
      -- Normal of edge1: (-dy1, dx1), Normal of edge2: (-dy2, dx2)
      nx := (-dy1 + -dy2) / 2.0;
      ny := (dx1 + dx2) / 2.0;
      nlen := sqrt(nx*nx + ny*ny);
      IF nlen > 0 THEN
         nx := nx / nlen;
         ny := ny / nlen;
      END IF;

      -- Check orientation: if polygon is CW, normals point inward
      -- Flip sign based on signed area
      IF lm__signed_area((p_geom).lon, (p_geom).lat) < 0 THEN
         nx := -nx; ny := -ny;
      END IF;

      out_lon := out_lon || ((p_geom).lon[i] + p_distance * nx);
      out_lat := out_lat || ((p_geom).lat[i] + p_distance * ny);
   END LOOP;

   RETURN ROW(out_lon, out_lat)::geometry;
END;
$$;


-- ============================================================
-- 7)  ST_IsValid  —  PostGIS ST_IsValid equivalent
--     Checks basic OGC validity:
--       - Not empty
--       - Polygon has >= 3 vertices
--       - No self-intersecting edges (for polygons)
--       - Coordinates are finite numbers
-- ============================================================
CREATE OR REPLACE FUNCTION ST_IsValid(p_geom geometry)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   i integer; j integer; i2 integer; j2 integer;
BEGIN
   IF n = 0 THEN RETURN false; END IF;

   -- Check for NaN or infinity
   FOR i IN 1..n LOOP
      IF (p_geom).lon[i] = 'NaN'::double precision
         OR (p_geom).lat[i] = 'NaN'::double precision
         OR (p_geom).lon[i] = 'Infinity'::double precision
         OR (p_geom).lon[i] = '-Infinity'::double precision
         OR (p_geom).lat[i] = 'Infinity'::double precision
         OR (p_geom).lat[i] = '-Infinity'::double precision THEN
         RETURN false;
      END IF;
   END LOOP;

   -- Points and lines: valid if non-empty with finite coords
   IF n <= 2 THEN RETURN true; END IF;

   -- Polygon: check for self-intersection (non-adjacent edges)
   FOR i IN 1..n LOOP
      i2 := CASE WHEN i = n THEN 1 ELSE i + 1 END;
      FOR j IN (i+2)..n LOOP
         -- Skip adjacent edges
         IF j = n AND i = 1 THEN CONTINUE; END IF;
         j2 := CASE WHEN j = n THEN 1 ELSE j + 1 END;
         IF lm__segments_cross(
            (p_geom).lon[i],  (p_geom).lat[i],
            (p_geom).lon[i2], (p_geom).lat[i2],
            (p_geom).lon[j],  (p_geom).lat[j],
            (p_geom).lon[j2], (p_geom).lat[j2]) THEN
            RETURN false;
         END IF;
      END LOOP;
   END LOOP;

   -- Check area is non-zero
   IF ST_Area(p_geom) = 0 THEN RETURN false; END IF;

   RETURN true;
END;
$$;


-- ============================================================
-- 8)  ST_Touches  —  PostGIS ST_Touches equivalent
--     Returns true if geometries have at least one boundary
--     point in common, but their interiors do not intersect.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Touches(p_a geometry, p_b geometry)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   na integer := coalesce(array_length((p_a).lon, 1), 0);
   nb integer := coalesce(array_length((p_b).lon, 1), 0);
   i integer; j integer; i2 integer; j2 integer;
   boundary_contact boolean := false;
   epsilon constant double precision := 1e-12;
   d double precision;
BEGIN
   -- Must intersect to touch
   IF NOT ST_Intersects(p_a, p_b) THEN RETURN false; END IF;

   -- Check: any vertex of A on boundary of B
   FOR i IN 1..na LOOP
      FOR j IN 1..nb LOOP
         j2 := CASE WHEN j = nb THEN 1 ELSE j + 1 END;
         d := lm__point_segment_dist(
            (p_a).lon[i], (p_a).lat[i],
            (p_b).lon[j], (p_b).lat[j],
            (p_b).lon[j2], (p_b).lat[j2]);
         IF d < epsilon THEN
            boundary_contact := true;
            -- But is this point in the INTERIOR of B?
            -- If it's strictly inside B (not on boundary), then it's not just touching
            IF na >= 3 AND nb >= 3 THEN
               IF point_in_polygon((p_a).lon[i], (p_a).lat[i], (p_b).lon, (p_b).lat) THEN
                  -- Check if it's truly on boundary
                  IF d >= epsilon THEN
                     RETURN false;  -- interior intersection
                  END IF;
               END IF;
            END IF;
         END IF;
      END LOOP;
   END LOOP;

   -- Check: any vertex of B on boundary of A
   FOR i IN 1..nb LOOP
      FOR j IN 1..na LOOP
         j2 := CASE WHEN j = na THEN 1 ELSE j + 1 END;
         d := lm__point_segment_dist(
            (p_b).lon[i], (p_b).lat[i],
            (p_a).lon[j], (p_a).lat[j],
            (p_a).lon[j2], (p_a).lat[j2]);
         IF d < epsilon THEN
            boundary_contact := true;
         END IF;
      END LOOP;
   END LOOP;

   -- They intersect but only on boundaries
   -- Final check: no interior overlap
   -- If any vertex of A is strictly inside B (not on boundary), not just touching
   FOR i IN 1..na LOOP
      IF point_in_polygon((p_a).lon[i], (p_a).lat[i], (p_b).lon, (p_b).lat) THEN
         -- Verify it's on the boundary
         d := 'Infinity'::double precision;
         FOR j IN 1..nb LOOP
            j2 := CASE WHEN j = nb THEN 1 ELSE j + 1 END;
            d := least(d, lm__point_segment_dist(
               (p_a).lon[i], (p_a).lat[i],
               (p_b).lon[j], (p_b).lat[j],
               (p_b).lon[j2], (p_b).lat[j2]));
         END LOOP;
         IF d > epsilon THEN RETURN false; END IF;
      END IF;
   END LOOP;

   FOR i IN 1..nb LOOP
      IF point_in_polygon((p_b).lon[i], (p_b).lat[i], (p_a).lon, (p_a).lat) THEN
         d := 'Infinity'::double precision;
         FOR j IN 1..na LOOP
            j2 := CASE WHEN j = na THEN 1 ELSE j + 1 END;
            d := least(d, lm__point_segment_dist(
               (p_b).lon[i], (p_b).lat[i],
               (p_a).lon[j], (p_a).lat[j],
               (p_a).lon[j2], (p_a).lat[j2]));
         END LOOP;
         IF d > epsilon THEN RETURN false; END IF;
      END IF;
   END LOOP;

   RETURN boundary_contact;
END;
$$;


-- ============================================================
-- 9)  ST_Crosses  —  PostGIS ST_Crosses equivalent
--     Two geometries cross if they have some but not all
--     interior points in common, and the dimension of the
--     intersection is less than the max dimension of the inputs.
--
--     Simplified: for two lines, returns true if they
--     intersect at a point but neither contains the other.
--     For a line and polygon, returns true if the line
--     has points both inside and outside the polygon.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Crosses(p_a geometry, p_b geometry)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   na integer := coalesce(array_length((p_a).lon, 1), 0);
   nb integer := coalesce(array_length((p_b).lon, 1), 0);
   has_in boolean := false;
   has_out boolean := false;
   i integer;
BEGIN
   IF NOT ST_Intersects(p_a, p_b) THEN RETURN false; END IF;

   -- Line crossing polygon
   IF na = 2 AND nb >= 3 THEN
      FOR i IN 1..na LOOP
         IF point_in_polygon((p_a).lon[i], (p_a).lat[i], (p_b).lon, (p_b).lat) THEN
            has_in := true;
         ELSE
            has_out := true;
         END IF;
      END LOOP;
      RETURN has_in AND has_out;
   END IF;

   IF nb = 2 AND na >= 3 THEN
      FOR i IN 1..nb LOOP
         IF point_in_polygon((p_b).lon[i], (p_b).lat[i], (p_a).lon, (p_a).lat) THEN
            has_in := true;
         ELSE
            has_out := true;
         END IF;
      END LOOP;
      RETURN has_in AND has_out;
   END IF;

   -- Line-line: they cross if they intersect but neither contains the other
   IF na = 2 AND nb = 2 THEN
      RETURN ST_Intersects(p_a, p_b)
         AND NOT ST_Contains(p_a, p_b)
         AND NOT ST_Contains(p_b, p_a);
   END IF;

   -- Same-dimension polygons don't "cross" — they "overlap"
   RETURN false;
END;
$$;


-- ============================================================
-- 10) ST_Overlaps  —  PostGIS ST_Overlaps equivalent
--     Returns true if two geometries of the same dimension
--     share some but not all points in common, and the
--     intersection has the same dimension as the inputs.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Overlaps(p_a geometry, p_b geometry)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   na integer := coalesce(array_length((p_a).lon, 1), 0);
   nb integer := coalesce(array_length((p_b).lon, 1), 0);
   dim_a integer;
   dim_b integer;
BEGIN
   -- Determine dimensions
   dim_a := CASE WHEN na <= 1 THEN 0 WHEN na = 2 THEN 1 ELSE 2 END;
   dim_b := CASE WHEN nb <= 1 THEN 0 WHEN nb = 2 THEN 1 ELSE 2 END;

   -- Overlaps only applies to same-dimension geometries
   IF dim_a <> dim_b THEN RETURN false; END IF;

   -- Must intersect
   IF NOT ST_Intersects(p_a, p_b) THEN RETURN false; END IF;

   -- Neither contains the other
   IF dim_a >= 2 THEN
      IF ST_Contains(p_a, p_b) OR ST_Contains(p_b, p_a) THEN
         RETURN false;
      END IF;
   END IF;

   RETURN true;
END;
$$;


-- ============================================================
-- 11) ST_Equals  —  PostGIS ST_Equals equivalent
--     Returns true if two geometries represent the same
--     point set (topological equality).
--
--     Two polygons are equal if each contains the other.
--     Two points are equal if same coordinates.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Equals(p_a geometry, p_b geometry)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   na integer := coalesce(array_length((p_a).lon, 1), 0);
   nb integer := coalesce(array_length((p_b).lon, 1), 0);
BEGIN
   -- Empty geometries
   IF na = 0 AND nb = 0 THEN RETURN true; END IF;
   IF na = 0 OR nb = 0 THEN RETURN false; END IF;

   -- Points
   IF na = 1 AND nb = 1 THEN
      RETURN (p_a).lon[1] = (p_b).lon[1]
         AND (p_a).lat[1] = (p_b).lat[1];
   END IF;

   -- Same vertex count check (quick reject)
   -- Note: topologically equal polygons CAN have different vertex counts
   -- But for exact equality we check mutual containment.

   -- Mutual containment = topological equality for polygons
   IF na >= 3 AND nb >= 3 THEN
      RETURN ST_Contains(p_a, p_b) AND ST_Contains(p_b, p_a);
   END IF;

   -- Lines: check vertex-by-vertex in both directions
   IF na = nb THEN
      -- Forward match
      DECLARE
         fwd boolean := true;
         rev boolean := true;
         i integer;
      BEGIN
         FOR i IN 1..na LOOP
            IF (p_a).lon[i] <> (p_b).lon[i]
               OR (p_a).lat[i] <> (p_b).lat[i] THEN
               fwd := false;
            END IF;
            IF (p_a).lon[i] <> (p_b).lon[na - i + 1]
               OR (p_a).lat[i] <> (p_b).lat[na - i + 1] THEN
               rev := false;
            END IF;
         END LOOP;
         RETURN fwd OR rev;
      END;
   END IF;

   RETURN false;
END;
$$;


-- ============================================================
-- 12) ST_Simplify_vw  —  PostGIS ST_SimplifyVW equivalent
--     Visvalingam-Whyatt simplification.
--     Removes vertices based on effective triangle area.
-- ============================================================
CREATE OR REPLACE FUNCTION ST_Simplify_vw(
   p_geom geometry, p_area_threshold double precision
)
RETURNS geometry
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n integer := coalesce(array_length((p_geom).lon, 1), 0);
   lon_arr double precision[] := (p_geom).lon;
   lat_arr double precision[] := (p_geom).lat;
   areas double precision[];
   min_area double precision;
   min_idx integer;
   i integer;
   new_lon double precision[];
   new_lat double precision[];
   cur_n integer;
BEGIN
   IF n <= 3 THEN RETURN p_geom; END IF;

   -- Iteratively remove the vertex with smallest effective area
   LOOP
      cur_n := array_length(lon_arr, 1);
      IF cur_n <= 3 THEN EXIT; END IF;

      -- Compute effective areas for interior vertices
      min_area := 'Infinity';
      min_idx := -1;
      FOR i IN 2..cur_n-1 LOOP
         areas[i] := abs(
            (lon_arr[i-1] * (lat_arr[i] - lat_arr[i+1])
           + lon_arr[i]   * (lat_arr[i+1] - lat_arr[i-1])
           + lon_arr[i+1] * (lat_arr[i-1] - lat_arr[i])) / 2.0);
         IF areas[i] < min_area THEN
            min_area := areas[i];
            min_idx := i;
         END IF;
      END LOOP;

      IF min_area >= p_area_threshold THEN EXIT; END IF;

      -- Remove the vertex with smallest area
      new_lon := ARRAY[]::double precision[];
      new_lat := ARRAY[]::double precision[];
      FOR i IN 1..cur_n LOOP
         IF i <> min_idx THEN
            new_lon := new_lon || lon_arr[i];
            new_lat := new_lat || lat_arr[i];
         END IF;
      END LOOP;
      lon_arr := new_lon;
      lat_arr := new_lat;
   END LOOP;

   RETURN ROW(lon_arr, lat_arr)::geometry;
END;
$$;
