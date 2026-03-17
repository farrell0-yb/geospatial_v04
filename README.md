# Pure SQL PostGIS Replacement for YugabyteDB

Using only SQL and PL/pgSQL, the contents of this repo provide a drop-in replacement
for PostGIS to the extent that the open-source **GeoServer** will connect to
YugabyteDB and function without modification -- WMS map rendering, WFS feature
queries, CQL spatial filtering, and OGC-compliant layer preview all work out of
the box.

No C extensions. No PostGIS binary. Just SQL.

![GeoServer Layer Preview -- 344,688 points rendered via WMS from YugabyteDB](10%20-%20GeoServer.png)

![GeoServer OpenLayers preview -- red dots rendered on the map](11%20-%20WebApp.png)

---

## Distance Models

This project supports four distance/coordinate models:

| Model | Scope | Accuracy | Use Case |
|-------|-------|----------|----------|
| **Planar** | Flat 2D (degree units) | Exact in projected CRS | Local area, small regions, fast queries |
| **Haversine** | Perfect sphere (R = 6,371 km) | ~0.3% error vs ellipsoid | General-purpose distance, good enough for most apps |
| **Vincenty** | WGS-84 ellipsoid, iterative | Sub-millimeter | Surveying, aviation, precision requirements |
| **Karney** | WGS-84 ellipsoid, series expansion | Sub-nanometer | Geodetic reference, antipodal points |

- **Planar geometry** functions (`ST_Distance`, `ST_Length`, `ST_Area`, etc.) operate in coordinate units (degrees for EPSG:4326).
- **Haversine** is the default for `ST_DistanceSphere` and `ST_Distance(geography, geography)`.
- **Vincenty** is available via `ST_Distance(geography, geography, true)` and the internal `lm__vincenty_distance` helper. Falls back to Haversine for near-antipodal points.
- **Karney** series expansion follows the same approach as Vincenty but uses the Karney (2013) method for higher precision and convergence at all distances.

---

## What GeoServer Sees

GeoServer's PostGIS data store plugin queries a set of metadata functions and
views to decide whether PostGIS is installed. This project provides all of them:

| GeoServer Expectation | What We Provide |
|-----------------------|-----------------|
| `PostGIS_Lib_Version()` | Returns `'2.1.8'` |
| `PostGIS_Version()` | Returns `'2.1 USE_GEOS=0'` |
| `PostGIS_Full_Version()` | Full version string |
| `geometry_columns` view | Reports `my_mapdata.geom`, SRID 4326, type POINT |
| `geography_columns` view | Ready for geography-typed tables |
| `spatial_ref_sys` table | Populated with EPSG:4326 (WGS 84) |
| `ST_AsBinary(geometry)` | OGC Well-Known Binary encoding |
| `ST_AsEWKB(geometry)` | Extended WKB with embedded SRID |
| `ST_AsTWKB(geometry, integer)` | Tiny WKB with varint delta compression |
| `ST_GeomFromWKB(bytea, srid)` | WKB decoding for prepared statements |
| `ST_GeomFromText(wkt, srid)` | WKT parser (POINT, LINESTRING, POLYGON) |
| `ST_Simplify(geom, tol, bool)` | Douglas-Peucker simplification |
| `ST_Force2D` / `ST_NDims` | Identity (always 2D) |
| `ST_EstimatedExtent(...)` | Falls back to `ST_Extent` aggregate |
| `&&` operator | Bounding-box overlap |
| `<->` operator | KNN distance for ORDER BY |
| `box2d` type + casts | Bounding-box type with geometry casts |

---

## Files and Execution Order

Run in this order:

| Order | File | Purpose | Objects |
|:-----:|------|---------|:-------:|
| 1 | `10_CreateGeometryType.sql` | `geometry` type, constructors, WKB/EWKB/TWKB encoding, GeoServer compat layer, `box2d` type, `&&` and `<->` operators | 36 |
| 2 | `11_CreateSchema.sql` | `my_mapdata` table, 4 indexes, `spatial_ref_sys`, `geometry_columns` view, `geography_columns` view | -- |
| 3 | `12_CreateGeographyType.sql` | `geography` type, casts, Haversine + Vincenty distance, geography-aware spatial functions, GeoServer compat | 54 |
| 4 | `15_LoadData.sql` | Loads ~344,688 POI records from `19_mapData.pipe` | -- |
| 5 | `20_GeohashFunctions.sql` | 14 geohash utility functions (encode, decode, neighbors, proximity) | 14 |
| 6 | `25_GeometryFunctions.sql` | 7 original core spatial functions with dual calling styles | 16 |
| 7 | `26_Tier1_GeometryFunctions.sql` | 26 Tier-1 functions (accessors, predicates, WKT/GeoJSON output) | 32 |
| 8 | `27_Tier2_GeometryFunctions.sql` | 28 Tier-2 functions (distance, simplify, interpolation, clipping) | 33 |
| 9 | `28_Tier3_GeometryFunctions.sql` | 12 Tier-3 functions (convex hull, intersection, union, buffer) | 12 |
| 10 | `30_GeohashPolygonFunctions.sql` | Geohash-8 polygon coverage functions | 2 |
| 11 | `35_TestQueries.sql` | Test suite | -- |

**Total: 199 SQL functions/operators/types/aggregates across 11 files.**

---

## The Geometry Type

The `geometry` type is a SQL composite -- no extensions needed:

```sql
CREATE TYPE geometry AS (
   lon   double precision[],
   lat   double precision[]
);
```

| Shape | Representation | Example |
|-------|---------------|---------|
| **Point** | Single-element arrays | `ST_MakePoint(-105.07, 40.58)` |
| **LineString** | Two-element arrays | `ST_MakeLine(point_a, point_b)` |
| **Polygon** | 3+ vertex arrays | `ST_MakePolygon(lon[], lat[])` |
| **Bounding box** | 4-vertex rectangle | `ST_MakeEnvelope(-105.1, 40.5, -105.0, 40.6)` |

## The Geography Type

The `geography` type is structurally identical to `geometry` but signals that
functions should use spherical or ellipsoidal math and return metric units (meters, square meters):

```sql
CREATE TYPE geography AS (
   lon   double precision[],
   lat   double precision[]
);
```

Implicit casts between `geometry` and `geography` are provided. Casting to
`geography` activates distance functions that return meters instead of degrees:

```sql
-- Planar distance (degrees)
SELECT ST_Distance(a, b);

-- Haversine distance (meters)
SELECT ST_Distance(a::geography, b::geography);

-- Vincenty distance (meters, sub-mm accuracy)
SELECT ST_Distance(a::geography, b::geography, true);
```

---

## Function Reference

### Constructors

| Function | Description |
|----------|-------------|
| `ST_MakePoint(lon, lat)` | Create a point |
| `ST_MakePolygon(lon[], lat[])` | Create a polygon from vertex arrays |
| `ST_MakeEnvelope(xmin, ymin, xmax, ymax)` | Create a bounding-box rectangle |
| `ST_MakeLine(a, b)` | Create a line from two points |
| `ST_MakeLine(points[])` | Create a line from an array of points |

### Accessors and Metadata (Tier 1)

| Function | Description |
|----------|-------------|
| `ST_X(geom)` / `ST_Y(geom)` | X/Y coordinate of a point |
| `ST_NPoints(geom)` | Number of vertices |
| `GeometryType(geom)` | Returns `'POINT'`, `'LINESTRING'`, or `'POLYGON'` |
| `ST_GeometryType(geom)` | Returns `'ST_Point'`, `'ST_LineString'`, or `'ST_Polygon'` |
| `ST_StartPoint` / `ST_EndPoint` / `ST_PointN` | Vertex accessors |
| `ST_IsClosed` / `ST_IsEmpty` / `ST_IsValid` | Predicates |
| `ST_Envelope(geom)` | Bounding box as polygon |
| `ST_Summary(geom)` | Text description |
| `ST_SRID` / `ST_SetSRID` / `ST_Transform` | SRID handling |

### Spatial Predicates

| Function | Description |
|----------|-------------|
| `ST_Contains(a, b)` | Does A fully contain B? |
| `ST_Within(a, b)` | Is A fully within B? |
| `ST_Intersects(a, b)` | Do A and B share any space? |
| `ST_Disjoint(a, b)` | No intersection? |
| `ST_Touches(a, b)` | Boundary contact only? |
| `ST_Crosses(a, b)` | Partial interior intersection? |
| `ST_Overlaps(a, b)` | Same-dimension partial overlap? |
| `ST_Equals(a, b)` | Topologically equal? |
| `ST_DWithin(a, b, dist)` | Within distance? |
| `ST_PointInsideCircle(pt, cx, cy, r)` | Point-in-circle test |
| `point_in_polygon(point, polygon)` | Ray-casting test |

### Measurement

| Function | Description |
|----------|-------------|
| `ST_Distance(a, b)` | Minimum planar distance |
| `ST_DistanceSphere(a, b)` | Great-circle distance (Haversine, meters) |
| `ST_DistanceSpheroid(a, b)` | Ellipsoidal distance (Vincenty, meters) |
| `ST_Length(geom)` | Length of linestring |
| `ST_Perimeter(geom)` | Perimeter of polygon |
| `ST_Area(geom)` | Area (shoelace formula; spherical excess for geography) |
| `ST_Azimuth(a, b)` | Bearing in radians |

### Transformations

| Function | Description |
|----------|-------------|
| `ST_Translate(geom, dx, dy)` | Shift by offset |
| `ST_Scale(geom, sx, sy)` | Scale by factors |
| `ST_Rotate(geom, angle, cx, cy)` | 2D rotation |
| `ST_Affine(geom, a,b,d,e,xoff,yoff)` | General affine transform |
| `ST_Reverse(geom)` | Reverse vertex order |
| `ST_FlipCoordinates(geom)` | Swap X and Y |
| `ST_ForcePolygonCCW` / `ST_ForcePolygonCW` | Force winding order |
| `ST_Simplify(geom, tolerance)` | Douglas-Peucker simplification |
| `ST_SimplifyVW(geom, threshold)` | Visvalingam-Whyatt simplification |
| `ST_ChaikinSmoothing(geom, iters)` | Corner-cutting smoothing |
| `ST_Segmentize(geom, max_len)` | Densify long segments |
| `ST_SnapToGrid(geom, size)` | Round coordinates to grid |
| `ST_RemoveRepeatedPoints(geom, tol)` | Remove duplicate vertices |

### Set Operations (Tier 3)

| Function | Description |
|----------|-------------|
| `ST_ConvexHull(geom)` | Convex hull (Graham scan) |
| `ST_Intersection(a, b)` | Polygon intersection (Sutherland-Hodgman) |
| `ST_Union(a, b)` | Union via convex hull |
| `ST_Difference(a, b)` | Part of A not in B |
| `ST_SymDifference(a, b)` | Parts in A or B but not both |
| `ST_Buffer(geom, dist, segs)` | Buffer approximation |
| `ST_ClipByBox2D(geom, ...)` | Clip to bounding box |

### Construction and Editing

| Function | Description |
|----------|-------------|
| `ST_AddPoint(geom, point, pos)` | Insert vertex |
| `ST_RemovePoint(geom, index)` | Remove vertex |
| `ST_SetPoint(geom, index, point)` | Replace vertex |
| `ST_GeneratePoints(geom, n)` | Random points inside polygon |
| `ST_Project(point, dist_m, azimuth)` | Project point by distance and bearing |
| `ST_Expand(geom, amount)` | Expand bounding box |
| `ST_LineInterpolatePoint(geom, frac)` | Point at fraction along line |
| `ST_LineLocatePoint(line, point)` | Nearest fraction on line |
| `ST_LineSubstring(geom, start, end)` | Sub-line between fractions |

### Input/Output

| Function | Description |
|----------|-------------|
| `ST_AsText(geom)` | WKT output |
| `ST_AsGeoJSON(geom)` | GeoJSON output |
| `ST_AsBinary(geom)` | OGC WKB output |
| `ST_AsEWKB(geom)` | Extended WKB with SRID |
| `ST_AsTWKB(geom, precision)` | Tiny WKB (varint delta-compressed) |
| `ST_GeomFromText(wkt)` | Parse WKT (POINT, LINESTRING, POLYGON) |
| `ST_GeomFromGeoJSON(json)` | Parse GeoJSON |
| `ST_GeomFromWKB(bytea, srid)` | Decode WKB |
| `ST_GeogFromText(wkt)` | Parse WKT returning geography |
| `ST_GeogFromGeoJSON(json)` | Parse GeoJSON returning geography |

### Geohash Functions

| Function | Description |
|----------|-------------|
| `geohash_encode(lat, lon, precision)` | Encode lat/lon to geohash |
| `geohash_adjacent(hash, dir)` | Neighboring cell |
| `geohash_neighbors(hash)` | All 8 surrounding cells |
| `geohash_move(hash, dir, steps)` | Move N steps in a direction |
| `geohash_decode_bbox(hash)` | Decode to bounding box |
| `geohash_decode_bbox_geom(hash)` | Decode to bbox as geometry |
| `geohash_cell_center(hash)` | Center point |
| `geohash_precision_for_miles(miles)` | Appropriate precision for radius |
| `geohash_in_list_within_miles(hash, miles)` | IN-clause of cells in radius |
| `geohash8_fully_within_polygon(...)` | Geohash-8 cells inside polygon |

---

## Example: PostGIS-Compatible Spatial Query

The following query uses geography casts, bounding-box distance, and Vincenty
ellipsoidal distance -- the same patterns used by production PostGIS applications:

```sql
SELECT
   md_pk,
   md_name,
   md_address,
   md_city,
   ST_Distance(
      geom::geography,
      ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
      true
   ) AS dist_m
FROM
   my_mapdata
WHERE
      ST_DWithin(
         geom::geography,
         ST_SetSRID(ST_GeomFromText('POINT(-105.0775 40.5853)'), 4326)::geography,
         1000, true)
   AND
      geom::box2d <-> ST_MakeEnvelope(-105.09, 40.57, -105.06, 40.60)::box2d = 0
ORDER BY
   ST_Distance(
      geom::geography,
      ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
      true)
LIMIT 10;
```

This query:
- Casts `geom` to `geography` for meter-based distance
- Uses `ST_DWithin` with Vincenty (`true`) to find points within 1 km
- Uses `box2d` distance operator (`<->`) for bounding-box pre-filtering
- Orders results by ellipsoidal distance (closest first)

---

## The Data

The file `19_mapData.pipe` contains **344,688 pipe-delimited records** of points
of interest for the US state of Colorado. Each record has a primary key, lat/lon
coordinates, a 10-character geohash, business name, full address, phone number,
category, and tags.

---

## GeoServer Integration

The repo includes files for running GeoServer against YugabyteDB:

| File | Purpose |
|------|---------|
| `40_JimsQuery.sql` | Example PostGIS-compatible spatial query |
| `60 - Start GeoServer.sh` | Script to start GeoServer on localhost:8080 |
| `61_geoserver_map.html` | Leaflet web map with GeoServer WMS/WFS overlay |

GeoServer connects to YugabyteDB as if it were PostgreSQL with PostGIS installed.
The pure-SQL compatibility layer handles all GeoServer queries transparently:

- **WMS GetMap** -- renders map tiles as PNG images
- **WFS GetFeature** -- returns GeoJSON/GML feature collections
- **CQL Filters** -- spatial and attribute filtering (`BBOX`, `DWITHIN`, `ILIKE`)
- **Layer Preview** -- OpenLayers preview works out of the box

---

## Not Implemented (Requires GEOS C Library)

The following PostGIS functions require the GEOS computational geometry library
and cannot be implemented in pure PL/pgSQL:

- `ST_MakeValid` (GEOS noding engine)
- `ST_Polygonize` / `ST_BuildArea` (planar graph operations)
- `ST_LargestEmptyCircle` (Voronoi diagrams)
- `ST_AsMVT` / `ST_AsMVTGeom` (Mapbox vector tile encoding)

---

## Key Takeaways

- **No C extensions** -- everything is pure SQL and PL/pgSQL
- **GeoServer compatible** -- connects and renders without modification
- **Four distance models** -- planar, Haversine, Vincenty, and Karney
- **199 SQL objects** -- functions, operators, types, aggregates, and views
- **344,688 test records** -- real-world POI data for Colorado
- **Geohash indexing** -- fast proximity queries via string-prefix index scans
- **Dual calling styles** -- raw arrays or geometry objects, whichever fits
