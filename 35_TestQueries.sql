-- ============================================================================
--
-- Test queries for all functions.
--
-- Run these after executing files 10 through 30 in order.
-- Each query is independent.
--
-- Tests are organized to show BOTH calling styles:
--   - Array style  (the original lat/lon array signatures)
--   - Geometry style (the geometry type signatures)
--
-- ============================================================================


-- =================================================================
-- SECTION A:  ST_Contains
-- =================================================================

-- Test A1:  Array style -- large rectangle contains smaller one
--           Expected: true
--
SELECT ST_Contains(
   ARRAY[-112.0, -111.8, -111.8, -112.0],
   ARRAY[40.4,   40.4,   40.6,   40.6],
   ARRAY[-111.95, -111.85, -111.85, -111.95],
   ARRAY[40.45,   40.45,   40.55,   40.55]
) AS "A1: contains (array) = true";

-- Test A2:  Geometry style -- same test
--           Expected: true
--
SELECT ST_Contains(
   ST_MakePolygon(
      ARRAY[-112.0, -111.8, -111.8, -112.0],
      ARRAY[40.4,   40.4,   40.6,   40.6]),
   ST_MakePolygon(
      ARRAY[-111.95, -111.85, -111.85, -111.95],
      ARRAY[40.45,   40.45,   40.55,   40.55])
) AS "A2: contains (geometry) = true";

-- Test A3:  Reversed -- small does NOT contain large
--           Expected: false
--
SELECT ST_Contains(
   ST_MakePolygon(
      ARRAY[-111.95, -111.85, -111.85, -111.95],
      ARRAY[40.45,   40.45,   40.55,   40.55]),
   ST_MakePolygon(
      ARRAY[-112.0, -111.8, -111.8, -112.0],
      ARRAY[40.4,   40.4,   40.6,   40.6])
) AS "A3: contains reversed = false";


-- =================================================================
-- SECTION B:  ST_XMin / ST_XMax / ST_YMin / ST_YMax
-- =================================================================

-- Test B1:  Array style
--           Expected: -112.0
--
SELECT ST_XMin(ARRAY[-112.0, -111.9, -111.9, -112.0])
   AS "B1: xmin (array) = -112.0";

-- Test B2:  Geometry style
--           Expected: -111.9
--
SELECT ST_XMax(
   ST_MakePolygon(
      ARRAY[-112.0, -111.9, -111.9, -112.0],
      ARRAY[40.5,   40.5,   40.55,  40.55])
) AS "B2: xmax (geometry) = -111.9";

-- Test B3:  Array style
--           Expected: 40.5 and 40.55
--
SELECT ST_YMin(ARRAY[40.5, 40.5, 40.55, 40.55]) AS "B3a: ymin = 40.5",
       ST_YMax(ARRAY[40.5, 40.5, 40.55, 40.55]) AS "B3b: ymax = 40.55";

-- Test B4:  Geometry style
--           Expected: 40.5 and 40.55
--
SELECT ST_YMin(
   ST_MakePolygon(
      ARRAY[-112.0, -111.9, -111.9, -112.0],
      ARRAY[40.5,   40.5,   40.55,  40.55])
) AS "B4a: ymin (geom) = 40.5",
ST_YMax(
   ST_MakePolygon(
      ARRAY[-112.0, -111.9, -111.9, -112.0],
      ARRAY[40.5,   40.5,   40.55,  40.55])
) AS "B4b: ymax (geom) = 40.55";


-- =================================================================
-- SECTION C:  ST_Translate
-- =================================================================

-- Test C1:  Array style -- shift 0.01 east, 0.02 south
--           Expected: out_lon={-111.99,-111.89,-111.89,-111.99}
--                     out_lat={40.48,40.48,40.53,40.53}
--
SELECT * FROM ST_Translate(
   ARRAY[-112.0, -111.9, -111.9, -112.0],
   ARRAY[40.5,   40.5,   40.55,  40.55],
   0.01, -0.02
);

-- Test C2:  Geometry style -- same shift, returns a geometry
--
SELECT ST_Translate(
   ST_MakePolygon(
      ARRAY[-112.0, -111.9, -111.9, -112.0],
      ARRAY[40.5,   40.5,   40.55,  40.55]),
   0.01, -0.02
) AS "C2: translated geometry";


-- =================================================================
-- SECTION D:  ST_Intersects
-- =================================================================

-- Test D1:  Array style -- overlapping rectangles
--           Expected: true
--
SELECT ST_Intersects(
   ARRAY[-112.0, -111.9, -111.9, -112.0],
   ARRAY[40.5,   40.5,   40.55,  40.55],
   ARRAY[-111.95, -111.85, -111.85, -111.95],
   ARRAY[40.52,   40.52,   40.57,   40.57]
) AS "D1: intersects (array) = true";

-- Test D2:  Geometry style -- same test
--           Expected: true
--
SELECT ST_Intersects(
   ST_MakePolygon(
      ARRAY[-112.0, -111.9, -111.9, -112.0],
      ARRAY[40.5,   40.5,   40.55,  40.55]),
   ST_MakePolygon(
      ARRAY[-111.95, -111.85, -111.85, -111.95],
      ARRAY[40.52,   40.52,   40.57,   40.57])
) AS "D2: intersects (geometry) = true";

-- Test D3:  Non-overlapping rectangles
--           Expected: false
--
SELECT ST_Intersects(
   ST_MakePolygon(
      ARRAY[-112.0, -111.9, -111.9, -112.0],
      ARRAY[40.5,   40.5,   40.55,  40.55]),
   ST_MakePolygon(
      ARRAY[-111.0, -110.9, -110.9, -111.0],
      ARRAY[41.0,   41.0,   41.05,  41.05])
) AS "D3: intersects far apart = false";


-- =================================================================
-- SECTION E:  point_in_polygon
-- =================================================================

-- Test E1:  lat/lon style
--           Expected: true
--
SELECT point_in_polygon(
   -111.97, 40.52,
   ARRAY[-112.0, -111.9, -111.9, -112.0],
   ARRAY[40.5, 40.5, 40.55, 40.55]
) AS "E1: point_in_polygon (lat/lon) = true";

-- Test E2:  Geometry style
--           Expected: true
--
SELECT point_in_polygon(
   ST_MakePoint(-111.97, 40.52),
   ST_MakePolygon(
      ARRAY[-112.0, -111.9, -111.9, -112.0],
      ARRAY[40.5, 40.5, 40.55, 40.55])
) AS "E2: point_in_polygon (geometry) = true";


-- =================================================================
-- SECTION F:  geohash_decode_bbox (both forms)
-- =================================================================

-- Test F1:  TABLE-returning version
--           Expected: lat_min, lat_max, lon_min, lon_max
--
SELECT * FROM geohash_decode_bbox('9x0qs0');

-- Test F2:  Geometry-returning version
--           Expected: a geometry rectangle
--
SELECT geohash_decode_bbox_geom('9x0qs0') AS "F2: bbox as geometry";


-- =================================================================
-- SECTION G:  geohash_cell_center (both forms)
-- =================================================================

-- Test G1:  TABLE-returning version
--           Expected: lat, lon
--
SELECT * FROM geohash_cell_center('9x0qs0');

-- Test G2:  Geometry-returning version
--           Expected: a geometry point
--
SELECT geohash_cell_center_geom('9x0qs0') AS "G2: center as geometry";


-- =================================================================
-- SECTION H:  Using geohash bounding boxes with spatial functions
-- =================================================================

-- Test H1:  A precision-6 cell contains its child precision-8 cell
--           Using TABLE style with manual array construction
--           Expected: true
--
WITH
   a AS (SELECT * FROM geohash_decode_bbox('9x0qs0')),
   b AS (SELECT * FROM geohash_decode_bbox('9x0qs0fd'))
SELECT ST_Contains(
   ARRAY[a.lon_min, a.lon_max, a.lon_max, a.lon_min],
   ARRAY[a.lat_min, a.lat_min, a.lat_max, a.lat_max],
   ARRAY[b.lon_min, b.lon_max, b.lon_max, b.lon_min],
   ARRAY[b.lat_min, b.lat_min, b.lat_max, b.lat_max]
) AS "H1: parent contains child (array) = true"
FROM a, b;

-- Test H2:  Same test using geometry style -- much cleaner
--           Expected: true
--
SELECT ST_Contains(
   geohash_decode_bbox_geom('9x0qs0'),
   geohash_decode_bbox_geom('9x0qs0fd')
) AS "H2: parent contains child (geometry) = true";


-- =================================================================
-- SECTION I:  Table geometry column
--             (only works after 15_LoadData.sql has been run)
-- =================================================================

-- Test I1:  Query the table using the geometry column
--
-- SELECT md_pk, md_name,
--        (geom).lon[1] AS lng,
--        (geom).lat[1] AS lat
-- FROM my_mapdata
-- WHERE geom IS NOT NULL
-- LIMIT 5;


-- =================================================================
-- SECTION J:  GeoServer compatibility functions
-- =================================================================

-- Test J1:  PostGIS version detection
--           Expected: '3.4 USE_GEOS=0'
--
SELECT PostGIS_Version() AS "J1: PostGIS_Version";

-- Test J2:  ST_SRID always returns 4326
--           Expected: 4326
--
SELECT ST_SRID(ST_MakePoint(-111.97, 40.52)) AS "J2: ST_SRID = 4326";

-- Test J3:  geometry_columns view
--
SELECT * FROM geometry_columns;

-- Test J4:  spatial_ref_sys table
--
SELECT srid, auth_name, auth_srid FROM spatial_ref_sys WHERE srid = 4326;

-- Test J5:  ST_AsBinary returns bytea
--           (verify non-null, 21 bytes for a point)
--
SELECT length(ST_AsBinary(ST_MakePoint(-111.97, 40.52))) AS "J5: WKB length = 21";

-- Test J6:  && operator (bbox overlap)
--           Expected: true
--
SELECT ST_MakeEnvelope(-112, 40, -111, 41) && ST_MakeEnvelope(-111.5, 40.5, -110.5, 41.5)
   AS "J6: bbox overlap = true";

-- Test J7:  ST_Extent aggregate
--           (only works after data is loaded)
--
-- SELECT ST_AsText(ST_Extent(geom)) AS "J7: extent of all points"
-- FROM my_mapdata
-- WHERE geom IS NOT NULL;

-- Test J8:  ST_MakeEnvelope with SRID
--           Expected: same as 4-arg version
--
SELECT ST_AsText(ST_MakeEnvelope(-112, 40, -111, 41, 4326)) AS "J8: MakeEnvelope with SRID";
