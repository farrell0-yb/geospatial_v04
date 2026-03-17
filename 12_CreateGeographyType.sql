-- ============================================================================
--
-- Purpose  : Define a custom 'geography' composite type for YugabyteDB YSQL,
--            plus casts between geometry and geography, constructor functions,
--            Vincenty ellipsoidal distance, and geography-aware spatial
--            functions that return results in meters / square meters.
--
--            The geography type is structurally identical to geometry (parallel
--            lon[] and lat[] arrays) but signals that functions should use
--            spherical or ellipsoidal math and return metric units.
--
--            Two distance models are provided:
--              - Haversine   (perfect sphere, R = 6,371,000 m)
--              - Vincenty    (WGS84 ellipsoid, sub-millimeter accuracy)
--
-- Depends on: 10_CreateGeometryType.sql  (geometry type must exist)
--
-- ============================================================================

-- Drop dependents first so the script is re-runnable.
DROP TYPE IF EXISTS geography CASCADE;

CREATE TYPE geography AS (
   lon   double precision[],
   lat   double precision[]
);


-- ============================================================================
-- Casts between geometry and geography
--
-- The internal representation is identical; casts are simple re-wraps.
-- ============================================================================

CREATE OR REPLACE FUNCTION lm__geometry_to_geography(p_geom geometry)
RETURNS geography
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ROW((p_geom).lon, (p_geom).lat)::geography;
$$;

CREATE OR REPLACE FUNCTION lm__geography_to_geometry(p_geog geography)
RETURNS geometry
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ROW((p_geog).lon, (p_geog).lat)::geometry;
$$;

CREATE CAST (geometry AS geography)
   WITH FUNCTION lm__geometry_to_geography(geometry)
   AS IMPLICIT;

CREATE CAST (geography AS geometry)
   WITH FUNCTION lm__geography_to_geometry(geography)
   AS IMPLICIT;


-- ============================================================================
-- Geography constructor functions
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_MakePoint_Geog(
   p_lon double precision,
   p_lat double precision
)
RETURNS geography
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ROW(ARRAY[p_lon], ARRAY[p_lat])::geography;
$$;

CREATE OR REPLACE FUNCTION ST_MakePolygon_Geog(
   p_lon double precision[],
   p_lat double precision[]
)
RETURNS geography
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   IF coalesce(array_length(p_lon, 1), 0) < 1 THEN
      RAISE EXCEPTION 'ST_MakePolygon_Geog: lon array must not be empty';
   END IF;
   IF array_length(p_lon, 1) <> coalesce(array_length(p_lat, 1), 0) THEN
      RAISE EXCEPTION 'ST_MakePolygon_Geog: lon[] and lat[] must be same length';
   END IF;
   RETURN ROW(p_lon, p_lat)::geography;
END;
$$;

CREATE OR REPLACE FUNCTION ST_MakeEnvelope_Geog(
   p_lon_min double precision,
   p_lat_min double precision,
   p_lon_max double precision,
   p_lat_max double precision
)
RETURNS geography
LANGUAGE sql IMMUTABLE
AS $$
   SELECT ROW(
      ARRAY[p_lon_min, p_lon_max, p_lon_max, p_lon_min],
      ARRAY[p_lat_min, p_lat_min, p_lat_max, p_lat_max]
   )::geography;
$$;


-- ============================================================================
-- SRID functions for geography (mirror the geometry versions)
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_SRID(p_geog geography)
RETURNS integer
LANGUAGE sql IMMUTABLE
AS $$
   SELECT 4326;
$$;

CREATE OR REPLACE FUNCTION ST_SetSRID(p_geog geography, p_srid integer)
RETURNS geography
LANGUAGE sql IMMUTABLE
AS $$
   SELECT p_geog;
$$;


-- ============================================================================
-- Internal: Haversine distance (sphere)
--
-- Already exists as ST_DistanceSphere for geometry; this is the geography
-- entry point that accepts geography arguments directly.
-- ============================================================================

CREATE OR REPLACE FUNCTION lm__haversine_distance(
   p_lon1 double precision, p_lat1 double precision,
   p_lon2 double precision, p_lat2 double precision
)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   R    constant double precision := 6371000.0;  -- Earth mean radius (m)
   rlat1 double precision := radians(p_lat1);
   rlat2 double precision := radians(p_lat2);
   dlat  double precision := radians(p_lat2 - p_lat1);
   dlon  double precision := radians(p_lon2 - p_lon1);
   a_val double precision;
BEGIN
   a_val := sin(dlat / 2.0) * sin(dlat / 2.0)
          + cos(rlat1) * cos(rlat2) * sin(dlon / 2.0) * sin(dlon / 2.0);
   RETURN R * 2.0 * atan2(sqrt(a_val), sqrt(1.0 - a_val));
END;
$$;


-- ============================================================================
-- Internal: Vincenty inverse distance (WGS84 ellipsoid)
--
-- Computes the geodesic distance between two points on the WGS84 ellipsoid
-- using Vincenty's inverse formula (iterative).
--
-- Returns distance in meters.  Sub-millimeter accuracy for all practical
-- point pairs.  Falls back to Haversine for nearly-antipodal points where
-- Vincenty may not converge.
--
-- Reference: T. Vincenty, "Direct and Inverse Solutions of Geodesics on the
--            Ellipsoid with Application of Nested Equations", Survey Review,
--            Vol. XXIII, No. 176, April 1975.
-- ============================================================================

CREATE OR REPLACE FUNCTION lm__vincenty_distance(
   p_lon1 double precision, p_lat1 double precision,
   p_lon2 double precision, p_lat2 double precision
)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   -- WGS84 ellipsoid parameters
   a  constant double precision := 6378137.0;           -- semi-major axis (m)
   f  constant double precision := 1.0 / 298.257223563; -- flattening
   b  constant double precision := 6356752.314245;      -- semi-minor axis (m)

   -- Reduced latitudes
   U1  double precision;
   U2  double precision;
   sinU1 double precision;  cosU1 double precision;
   sinU2 double precision;  cosU2 double precision;

   -- Difference in longitude on the auxiliary sphere
   L       double precision;
   lambda  double precision;
   lambda_prev double precision;

   -- Intermediate values
   sin_sigma   double precision;
   cos_sigma   double precision;
   sigma       double precision;
   sin_alpha   double precision;
   cos2_alpha  double precision;
   cos_2sigmaM double precision;
   C_val       double precision;
   u_sq        double precision;
   A_val       double precision;
   B_val       double precision;
   delta_sigma double precision;

   max_iter constant integer := 200;
   iter     integer := 0;
   tol      constant double precision := 1.0e-12;  -- ~0.06 mm
BEGIN
   -- Identical points
   IF p_lon1 = p_lon2 AND p_lat1 = p_lat2 THEN
      RETURN 0.0;
   END IF;

   -- Reduced latitudes (latitude on the auxiliary sphere)
   U1 := atan((1.0 - f) * tan(radians(p_lat1)));
   U2 := atan((1.0 - f) * tan(radians(p_lat2)));
   sinU1 := sin(U1);  cosU1 := cos(U1);
   sinU2 := sin(U2);  cosU2 := cos(U2);

   L := radians(p_lon2 - p_lon1);
   lambda := L;

   LOOP
      iter := iter + 1;

      sin_sigma := sqrt(
         (cosU2 * sin(lambda)) * (cosU2 * sin(lambda))
       + (cosU1 * sinU2 - sinU1 * cosU2 * cos(lambda))
       * (cosU1 * sinU2 - sinU1 * cosU2 * cos(lambda))
      );

      -- Co-incident points
      IF sin_sigma = 0.0 THEN
         RETURN 0.0;
      END IF;

      cos_sigma   := sinU1 * sinU2 + cosU1 * cosU2 * cos(lambda);
      sigma       := atan2(sin_sigma, cos_sigma);
      sin_alpha   := cosU1 * cosU2 * sin(lambda) / sin_sigma;
      cos2_alpha  := 1.0 - sin_alpha * sin_alpha;

      -- cos_2sigmaM: cos of 2 * sigma_m (equatorial line case: cos2_alpha = 0)
      IF cos2_alpha = 0.0 THEN
         cos_2sigmaM := 0.0;
      ELSE
         cos_2sigmaM := cos_sigma - 2.0 * sinU1 * sinU2 / cos2_alpha;
      END IF;

      C_val := f / 16.0 * cos2_alpha * (4.0 + f * (4.0 - 3.0 * cos2_alpha));

      lambda_prev := lambda;
      lambda := L + (1.0 - C_val) * f * sin_alpha * (
         sigma + C_val * sin_sigma * (
            cos_2sigmaM + C_val * cos_sigma * (
               -1.0 + 2.0 * cos_2sigmaM * cos_2sigmaM
            )
         )
      );

      -- Convergence check
      EXIT WHEN abs(lambda - lambda_prev) < tol;

      -- Fail-safe: fall back to Haversine for nearly-antipodal points
      IF iter >= max_iter THEN
         RETURN lm__haversine_distance(p_lon1, p_lat1, p_lon2, p_lat2);
      END IF;
   END LOOP;

   -- Final distance calculation
   u_sq  := cos2_alpha * (a * a - b * b) / (b * b);
   A_val := 1.0 + u_sq / 16384.0 * (
      4096.0 + u_sq * (-768.0 + u_sq * (320.0 - 175.0 * u_sq))
   );
   B_val := u_sq / 1024.0 * (
      256.0 + u_sq * (-128.0 + u_sq * (74.0 - 47.0 * u_sq))
   );

   delta_sigma := B_val * sin_sigma * (
      cos_2sigmaM + B_val / 4.0 * (
         cos_sigma * (-1.0 + 2.0 * cos_2sigmaM * cos_2sigmaM)
       - B_val / 6.0 * cos_2sigmaM
         * (-3.0 + 4.0 * sin_sigma * sin_sigma)
         * (-3.0 + 4.0 * cos_2sigmaM * cos_2sigmaM)
      )
   );

   RETURN b * A_val * (sigma - delta_sigma);
END;
$$;


-- ============================================================================
-- Geography distance functions
-- ============================================================================

-- ------------------------------------------------------------
-- ST_Distance(geography, geography)
--   Returns distance in meters using Haversine (sphere).
--   This is the default; matches PostGIS behavior where
--   ST_Distance on geography uses spherical by default.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_Distance(
   p_a geography, p_b geography
)
RETURNS double precision
LANGUAGE sql IMMUTABLE
AS $$
   SELECT lm__haversine_distance(
      (p_a).lon[1], (p_a).lat[1],
      (p_b).lon[1], (p_b).lat[1]
   );
$$;

-- ------------------------------------------------------------
-- ST_Distance(geography, geography, use_spheroid)
--   3-arg version.
--   use_spheroid = true  -> Vincenty (WGS84 ellipsoid)
--   use_spheroid = false -> Haversine (sphere)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_Distance(
   p_a geography, p_b geography, p_use_spheroid boolean
)
RETURNS double precision
LANGUAGE sql IMMUTABLE
AS $$
   SELECT CASE WHEN p_use_spheroid
      THEN lm__vincenty_distance(
              (p_a).lon[1], (p_a).lat[1],
              (p_b).lon[1], (p_b).lat[1])
      ELSE lm__haversine_distance(
              (p_a).lon[1], (p_a).lat[1],
              (p_b).lon[1], (p_b).lat[1])
   END;
$$;


-- ------------------------------------------------------------
-- ST_DWithin(geography, geography, distance_meters)
--   Returns true if the two geographies are within the given
--   distance (meters) using Haversine.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_DWithin(
   p_a geography, p_b geography,
   p_distance double precision
)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT lm__haversine_distance(
      (p_a).lon[1], (p_a).lat[1],
      (p_b).lon[1], (p_b).lat[1]
   ) <= p_distance;
$$;

-- ------------------------------------------------------------
-- ST_DWithin(geography, geography, distance_meters, use_spheroid)
--   4-arg version matching PostGIS signature.
--   use_spheroid = true  -> Vincenty
--   use_spheroid = false -> Haversine
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION ST_DWithin(
   p_a geography, p_b geography,
   p_distance double precision,
   p_use_spheroid boolean
)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT CASE WHEN p_use_spheroid
      THEN lm__vincenty_distance(
              (p_a).lon[1], (p_a).lat[1],
              (p_b).lon[1], (p_b).lat[1])
      ELSE lm__haversine_distance(
              (p_a).lon[1], (p_a).lat[1],
              (p_b).lon[1], (p_b).lat[1])
   END <= p_distance;
$$;


-- ============================================================================
-- Geography: ST_DistanceSphere / ST_DistanceSpheroid
-- ============================================================================

-- ST_DistanceSphere on geography — Haversine, returns meters
CREATE OR REPLACE FUNCTION ST_DistanceSphere(
   p_a geography, p_b geography
)
RETURNS double precision
LANGUAGE sql IMMUTABLE
AS $$
   SELECT lm__haversine_distance(
      (p_a).lon[1], (p_a).lat[1],
      (p_b).lon[1], (p_b).lat[1]
   );
$$;

-- ST_DistanceSpheroid on geography — Vincenty, returns meters
CREATE OR REPLACE FUNCTION ST_DistanceSpheroid(
   p_a geography, p_b geography
)
RETURNS double precision
LANGUAGE sql IMMUTABLE
AS $$
   SELECT lm__vincenty_distance(
      (p_a).lon[1], (p_a).lat[1],
      (p_b).lon[1], (p_b).lat[1]
   );
$$;

-- ST_DistanceSpheroid on geometry — Vincenty, returns meters
CREATE OR REPLACE FUNCTION ST_DistanceSpheroid(
   p_a geometry, p_b geometry
)
RETURNS double precision
LANGUAGE sql IMMUTABLE
AS $$
   SELECT lm__vincenty_distance(
      (p_a).lon[1], (p_a).lat[1],
      (p_b).lon[1], (p_b).lat[1]
   );
$$;


-- ============================================================================
-- Geography: ST_Length  (sum of great-circle segment lengths, meters)
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_Length(p_geog geography)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n     integer := coalesce(array_length((p_geog).lon, 1), 0);
   total double precision := 0;
   i     integer;
BEGIN
   IF n < 2 THEN RETURN 0; END IF;
   FOR i IN 1..(n - 1) LOOP
      total := total + lm__haversine_distance(
         (p_geog).lon[i], (p_geog).lat[i],
         (p_geog).lon[i + 1], (p_geog).lat[i + 1]
      );
   END LOOP;
   RETURN total;
END;
$$;


-- ============================================================================
-- Geography: ST_Perimeter  (closed ring length, meters)
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_Perimeter(p_geog geography)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   n     integer := coalesce(array_length((p_geog).lon, 1), 0);
   total double precision := 0;
   i     integer;
BEGIN
   IF n < 2 THEN RETURN 0; END IF;
   FOR i IN 1..(n - 1) LOOP
      total := total + lm__haversine_distance(
         (p_geog).lon[i], (p_geog).lat[i],
         (p_geog).lon[i + 1], (p_geog).lat[i + 1]
      );
   END LOOP;
   -- Close the ring
   total := total + lm__haversine_distance(
      (p_geog).lon[n], (p_geog).lat[n],
      (p_geog).lon[1], (p_geog).lat[1]
   );
   RETURN total;
END;
$$;


-- ============================================================================
-- Geography: ST_Area  (spherical excess formula, square meters)
--
-- Uses the spherical excess method:
--   Area = R^2 * |sum of spherical excess angles|
--
-- For each triangle (vertex 0, vertex i, vertex i+1) the spherical
-- excess is computed using L'Huilier's theorem.
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_Area(p_geog geography)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   R     constant double precision := 6371000.0;
   n     integer := coalesce(array_length((p_geog).lon, 1), 0);
   total double precision := 0;
   i     integer;
   -- Triangle sides (great-circle distances in radians)
   a_rad double precision;
   b_rad double precision;
   c_rad double precision;
   s     double precision;  -- semi-perimeter
   excess double precision;
   tan_val double precision;
BEGIN
   IF n < 3 THEN RETURN 0; END IF;

   -- Fan triangulation from vertex 1
   FOR i IN 2..(n - 1) LOOP
      -- Sides of triangle (vertex 1, vertex i, vertex i+1) in radians
      a_rad := lm__haversine_distance(
         (p_geog).lon[1], (p_geog).lat[1],
         (p_geog).lon[i], (p_geog).lat[i]
      ) / R;
      b_rad := lm__haversine_distance(
         (p_geog).lon[i], (p_geog).lat[i],
         (p_geog).lon[i + 1], (p_geog).lat[i + 1]
      ) / R;
      c_rad := lm__haversine_distance(
         (p_geog).lon[i + 1], (p_geog).lat[i + 1],
         (p_geog).lon[1], (p_geog).lat[1]
      ) / R;

      -- L'Huilier's theorem for spherical excess
      s := (a_rad + b_rad + c_rad) / 2.0;

      tan_val := sqrt(
         abs(
            tan(s / 2.0)
          * tan((s - a_rad) / 2.0)
          * tan((s - b_rad) / 2.0)
          * tan((s - c_rad) / 2.0)
         )
      );

      excess := 4.0 * atan(tan_val);
      total := total + excess;
   END LOOP;

   RETURN abs(total) * R * R;
END;
$$;


-- ============================================================================
-- Geography: ST_Intersects
--
-- Delegates to the geometry version (planar test).  For typical geospatial
-- data (not spanning poles or the antimeridian) this is accurate.
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_Intersects(
   p_a geography, p_b geography
)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_Intersects(p_a::geometry, p_b::geometry);
END;
$$;


-- ============================================================================
-- Geography: ST_Contains
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_Contains(
   p_a geography, p_b geography
)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_Contains(p_a::geometry, p_b::geometry);
END;
$$;


-- ============================================================================
-- Geography: ST_Within
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_Within(
   p_a geography, p_b geography
)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_Contains(p_b::geometry, p_a::geometry);
END;
$$;


-- ============================================================================
-- Geography: ST_Envelope, ST_Centroid  (delegate to geometry, return geography)
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_Envelope(p_geog geography)
RETURNS geography
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_Envelope(p_geog::geometry)::geography;
END;
$$;

CREATE OR REPLACE FUNCTION ST_Centroid(p_geog geography)
RETURNS geography
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_Centroid(p_geog::geometry)::geography;
END;
$$;


-- ============================================================================
-- Geography: Accessor functions
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_X(p_geog geography)
RETURNS double precision
LANGUAGE sql IMMUTABLE
AS $$
   SELECT (p_geog).lon[1];
$$;

CREATE OR REPLACE FUNCTION ST_Y(p_geog geography)
RETURNS double precision
LANGUAGE sql IMMUTABLE
AS $$
   SELECT (p_geog).lat[1];
$$;

CREATE OR REPLACE FUNCTION ST_NPoints(p_geog geography)
RETURNS integer
LANGUAGE sql IMMUTABLE
AS $$
   SELECT coalesce(array_length((p_geog).lon, 1), 0);
$$;

CREATE OR REPLACE FUNCTION ST_IsEmpty(p_geog geography)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT coalesce(array_length((p_geog).lon, 1), 0) = 0;
$$;


-- ============================================================================
-- Geography: Output functions
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_AsText(p_geog geography)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_AsText(p_geog::geometry);
END;
$$;

CREATE OR REPLACE FUNCTION ST_AsGeoJSON(p_geog geography)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_AsGeoJSON(p_geog::geometry);
END;
$$;

CREATE OR REPLACE FUNCTION ST_AsBinary(p_geog geography)
RETURNS bytea
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_AsBinary(p_geog::geometry);
END;
$$;


-- ============================================================================
-- Geography: GeometryType / ST_GeometryType
-- ============================================================================

CREATE OR REPLACE FUNCTION GeometryType(p_geog geography)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN GeometryType(p_geog::geometry);
END;
$$;

CREATE OR REPLACE FUNCTION ST_GeometryType(p_geog geography)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_GeometryType(p_geog::geometry);
END;
$$;


-- ============================================================================
-- Geography: ST_GeomFromText / ST_GeomFromGeoJSON  (return geography)
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_GeogFromText(p_wkt text)
RETURNS geography
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_GeomFromText(p_wkt)::geography;
END;
$$;

CREATE OR REPLACE FUNCTION ST_GeogFromGeoJSON(p_json text)
RETURNS geography
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_GeomFromGeoJSON(p_json::jsonb)::geography;
END;
$$;


-- ============================================================================
-- Geography: bbox overlap operator &&
-- ============================================================================

CREATE OR REPLACE FUNCTION geography_overlaps_bbox(a geography, b geography)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
   SELECT geometry_overlaps_bbox(a::geometry, b::geometry);
$$;

DROP OPERATOR IF EXISTS && (geography, geography);

CREATE OPERATOR && (
   LEFTARG    = geography,
   RIGHTARG   = geography,
   FUNCTION   = geography_overlaps_bbox,
   COMMUTATOR = &&
);


-- ============================================================================
-- Geography: ST_Extent aggregate
-- ============================================================================

CREATE OR REPLACE FUNCTION lm__st_extent_geog_transfn(
   state geography,
   val   geography
)
RETURNS geography
LANGUAGE sql IMMUTABLE
AS $$
   SELECT lm__st_extent_transfn(state::geometry, val::geometry)::geography;
$$;

DROP AGGREGATE IF EXISTS ST_Extent(geography);

CREATE AGGREGATE ST_Extent(geography) (
   SFUNC    = lm__st_extent_geog_transfn,
   STYPE    = geography
);


-- ============================================================================
-- Geography: ST_Project (forward geodesic projection)
--
-- Projects a point by distance (meters) and azimuth (radians).
-- Uses the Vincenty direct formula on the WGS84 ellipsoid.
-- ============================================================================

CREATE OR REPLACE FUNCTION ST_Project(
   p_geog    geography,
   p_distance double precision,
   p_azimuth  double precision
)
RETURNS geography
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   -- WGS84
   a  constant double precision := 6378137.0;
   f  constant double precision := 1.0 / 298.257223563;
   b  constant double precision := 6356752.314245;

   lon1  double precision := radians((p_geog).lon[1]);
   lat1  double precision := radians((p_geog).lat[1]);
   alpha1 double precision := p_azimuth;

   sinAlpha1  double precision := sin(alpha1);
   cosAlpha1  double precision := cos(alpha1);

   tanU1   double precision := (1.0 - f) * tan(lat1);
   cosU1   double precision := 1.0 / sqrt(1.0 + tanU1 * tanU1);
   sinU1   double precision := tanU1 * cosU1;

   sigma1     double precision;
   sinAlpha   double precision;
   cos2Alpha  double precision;
   u_sq       double precision;
   A_val      double precision;
   B_val      double precision;

   sigma      double precision;
   sigma_prev double precision;
   cos2sigmaM double precision;
   sinSigma   double precision;
   cosSigma   double precision;
   deltaSigma double precision;

   tmp   double precision;
   lat2  double precision;
   lon2  double precision;
   lambda double precision;
   C_val  double precision;
   L_val  double precision;

   iter     integer := 0;
   max_iter constant integer := 200;
BEGIN
   sigma1    := atan2(tanU1, cosAlpha1);
   sinAlpha  := cosU1 * sinAlpha1;
   cos2Alpha := 1.0 - sinAlpha * sinAlpha;
   u_sq      := cos2Alpha * (a * a - b * b) / (b * b);

   A_val := 1.0 + u_sq / 16384.0 * (
      4096.0 + u_sq * (-768.0 + u_sq * (320.0 - 175.0 * u_sq))
   );
   B_val := u_sq / 1024.0 * (
      256.0 + u_sq * (-128.0 + u_sq * (74.0 - 47.0 * u_sq))
   );

   sigma := p_distance / (b * A_val);

   LOOP
      iter := iter + 1;
      cos2sigmaM := cos(2.0 * sigma1 + sigma);
      sinSigma   := sin(sigma);
      cosSigma   := cos(sigma);

      deltaSigma := B_val * sinSigma * (
         cos2sigmaM + B_val / 4.0 * (
            cosSigma * (-1.0 + 2.0 * cos2sigmaM * cos2sigmaM)
          - B_val / 6.0 * cos2sigmaM
            * (-3.0 + 4.0 * sinSigma * sinSigma)
            * (-3.0 + 4.0 * cos2sigmaM * cos2sigmaM)
         )
      );

      sigma_prev := sigma;
      sigma := p_distance / (b * A_val) + deltaSigma;

      EXIT WHEN abs(sigma - sigma_prev) < 1.0e-12;
      EXIT WHEN iter >= max_iter;
   END LOOP;

   sinSigma   := sin(sigma);
   cosSigma   := cos(sigma);
   cos2sigmaM := cos(2.0 * sigma1 + sigma);

   tmp := sinU1 * sinSigma - cosU1 * cosSigma * cosAlpha1;
   lat2 := atan2(
      sinU1 * cosSigma + cosU1 * sinSigma * cosAlpha1,
      (1.0 - f) * sqrt(sinAlpha * sinAlpha + tmp * tmp)
   );

   lambda := atan2(
      sinSigma * sinAlpha1,
      cosU1 * cosSigma - sinU1 * sinSigma * cosAlpha1
   );

   C_val := f / 16.0 * cos2Alpha * (4.0 + f * (4.0 - 3.0 * cos2Alpha));

   L_val := lambda - (1.0 - C_val) * f * sinAlpha * (
      sigma + C_val * sinSigma * (
         cos2sigmaM + C_val * cosSigma * (
            -1.0 + 2.0 * cos2sigmaM * cos2sigmaM
         )
      )
   );

   lon2 := lon1 + L_val;

   RETURN ROW(ARRAY[degrees(lon2)], ARRAY[degrees(lat2)])::geography;
END;
$$;


-- ============================================================================
-- GeoServer PostGIS compatibility — additional geography functions
-- ============================================================================

-- ST_AsEWKB for geography (delegates to geometry version)
CREATE OR REPLACE FUNCTION ST_AsEWKB(p_geog geography)
RETURNS bytea
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_AsEWKB(p_geog::geometry);
END;
$$;

-- ST_Force2D for geography (identity — always 2D)
CREATE OR REPLACE FUNCTION ST_Force2D(p_geog geography)
RETURNS geography
LANGUAGE sql IMMUTABLE
AS $$
   SELECT p_geog;
$$;

CREATE OR REPLACE FUNCTION ST_Force_2D(p_geog geography)
RETURNS geography
LANGUAGE sql IMMUTABLE
AS $$
   SELECT p_geog;
$$;

-- ST_NDims for geography (always 2)
CREATE OR REPLACE FUNCTION ST_NDims(p_geog geography)
RETURNS integer
LANGUAGE sql IMMUTABLE
AS $$
   SELECT 2;
$$;

-- ST_Transform for geography (identity — always 4326)
CREATE OR REPLACE FUNCTION ST_Transform(p_geog geography, p_srid integer)
RETURNS geography
LANGUAGE sql IMMUTABLE
AS $$
   SELECT p_geog;
$$;

-- ST_GeomFromText with SRID returning geography
-- GeoServer may call: ST_GeomFromText('POINT(...)', 4326)::geography
-- The cast handles this, but explicit function is also useful.
CREATE OR REPLACE FUNCTION ST_GeogFromText(p_wkt text, p_srid integer)
RETURNS geography
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_GeomFromText(p_wkt)::geography;
END;
$$;

-- <-> operator for geography (great-circle distance for KNN sorting)
CREATE OR REPLACE FUNCTION geography_distance(a geography, b geography)
RETURNS double precision
LANGUAGE sql IMMUTABLE
AS $$
   SELECT lm__haversine_distance(
      (a).lon[1], (a).lat[1],
      (b).lon[1], (b).lat[1]
   );
$$;

DROP OPERATOR IF EXISTS <-> (geography, geography);

CREATE OPERATOR <-> (
   LEFTARG    = geography,
   RIGHTARG   = geography,
   FUNCTION   = geography_distance,
   COMMUTATOR = <->
);

-- geography to box2d cast
CREATE OR REPLACE FUNCTION lm__geography_to_box2d(p_geog geography)
RETURNS box2d
LANGUAGE sql IMMUTABLE
AS $$
   SELECT lm__geometry_to_box2d(p_geog::geometry);
$$;

CREATE CAST (geography AS box2d)
   WITH FUNCTION lm__geography_to_box2d(geography)
   AS IMPLICIT;

-- ST_SimplifyPreserveTopology for geography
CREATE OR REPLACE FUNCTION ST_SimplifyPreserveTopology(
   p_geog geography,
   p_tolerance double precision
)
RETURNS geography
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_Simplify(p_geog::geometry, p_tolerance)::geography;
END;
$$;

-- ST_Simplify for geography
CREATE OR REPLACE FUNCTION ST_Simplify(
   p_geog geography,
   p_tolerance double precision
)
RETURNS geography
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_Simplify(p_geog::geometry, p_tolerance)::geography;
END;
$$;

-- ST_Buffer for geography (distance in meters, approximate)
-- Converts meter distance to approximate degrees, delegates to geometry
CREATE OR REPLACE FUNCTION ST_Buffer(
   p_geog geography,
   p_distance_m double precision,
   p_segments integer DEFAULT 8
)
RETURNS geography
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
   -- Approximate meters-to-degrees at the geometry's latitude
   lat_deg double precision := coalesce((p_geog).lat[1], 0);
   m_per_deg_lat constant double precision := 111320.0;
   m_per_deg_lon double precision := 111320.0 * cos(radians(lat_deg));
   avg_m_per_deg double precision;
   deg_distance double precision;
BEGIN
   avg_m_per_deg := (m_per_deg_lat + m_per_deg_lon) / 2.0;
   IF avg_m_per_deg = 0 THEN avg_m_per_deg := m_per_deg_lat; END IF;
   deg_distance := p_distance_m / avg_m_per_deg;
   RETURN ST_Buffer(p_geog::geometry, deg_distance, p_segments)::geography;
END;
$$;

-- ST_Crosses for geography
CREATE OR REPLACE FUNCTION ST_Crosses(p_a geography, p_b geography)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_Crosses(p_a::geometry, p_b::geometry);
END;
$$;

-- ST_Overlaps for geography
CREATE OR REPLACE FUNCTION ST_Overlaps(p_a geography, p_b geography)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_Overlaps(p_a::geometry, p_b::geometry);
END;
$$;

-- ST_Touches for geography
CREATE OR REPLACE FUNCTION ST_Touches(p_a geography, p_b geography)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_Touches(p_a::geometry, p_b::geometry);
END;
$$;

-- ST_Equals for geography
CREATE OR REPLACE FUNCTION ST_Equals(p_a geography, p_b geography)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN ST_Equals(p_a::geometry, p_b::geometry);
END;
$$;

-- ST_Disjoint for geography
CREATE OR REPLACE FUNCTION ST_Disjoint(p_a geography, p_b geography)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
   RETURN NOT ST_Intersects(p_a::geometry, p_b::geometry);
END;
$$;


-- ============================================================================
-- End of geography type definition
-- ============================================================================
