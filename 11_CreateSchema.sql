
-- ============================================================================
--
-- Purpose  : Create the my_mapdata table with a geometry column,
--            plus GeoServer-required metadata objects (geometry_columns
--            view and spatial_ref_sys table).
--
-- Requires : 10_CreateGeometryType.sql  (defines the geometry type)
--
-- The table stores point-of-interest records.  Each row has:
--   - Standard address/category fields (loaded from the pipe file)
--   - A geohash10 TEXT column used for spatial indexing
--   - A geo_hash8 TEXT column (first 8 chars of geohash10) for finer lookups
--   - A geom GEOMETRY column holding the point as ST_MakePoint(lng, lat)
--
-- ============================================================================

DROP TABLE IF EXISTS my_mapdata;

CREATE TABLE my_mapdata
   (
   md_pk                 BIGINT NOT NULL,
   md_lat                TEXT,
   md_lng                TEXT,
   geo_hash10            TEXT,
   geom                  geometry,
   geo_hash8             TEXT,
   md_name               TEXT,
   md_address            TEXT,
   md_city               TEXT,
   md_province           TEXT,
   md_country            TEXT,
   md_postcode           TEXT,
   md_phone              TEXT,
   md_category           TEXT,
   md_subcategory        TEXT,
   md_mysource           TEXT,
   md_tags               TEXT,
   md_type               TEXT,
   PRIMARY KEY ((md_pk) HASH)
   );

-- Full geohash10 + name index
--
CREATE INDEX ix_my_mapdata2
   ON my_mapdata (geo_hash10, md_name);

-- Best index for the speed = 80 use case,
-- because of how we build that data set.
--
CREATE INDEX IF NOT EXISTS ix_mapdata3
   ON my_mapdata (left(geo_hash10, 5), md_name);

-- Best index for the walking use case
--
CREATE INDEX IF NOT EXISTS ix_mapdata4
   ON my_mapdata (left(geo_hash10, 6), md_name);

-- Index on geo_hash8 for equality lookups
--
CREATE INDEX IF NOT EXISTS ix_mapdata_geo_hash8
   ON my_mapdata (geo_hash8);


-- ============================================================================
-- GeoServer PostGIS compatibility — spatial_ref_sys table
--
-- GeoServer queries this table to validate SRIDs.
-- We populate only EPSG:4326 (WGS 84) since all our data uses it.
-- ============================================================================

CREATE TABLE IF NOT EXISTS spatial_ref_sys (
   srid      integer PRIMARY KEY,
   auth_name varchar(256),
   auth_srid integer,
   srtext    varchar(2048),
   proj4text varchar(2048)
);

INSERT INTO spatial_ref_sys (srid, auth_name, auth_srid, srtext, proj4text)
VALUES (
   4326,
   'EPSG',
   4326,
   'GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],UNIT["degree",0.0174532925199433,AUTHORITY["EPSG","9122"]],AUTHORITY["EPSG","4326"]]',
   '+proj=longlat +datum=WGS84 +no_defs'
)
ON CONFLICT (srid) DO NOTHING;


-- ============================================================================
-- GeoServer PostGIS compatibility — geometry_columns view
--
-- GeoServer queries this view during layer setup to discover geometry
-- columns, their types, SRIDs, and coordinate dimensions.
--
-- SELECT * FROM geometry_columns WHERE f_table_name = 'my_mapdata';
-- ============================================================================

DROP VIEW IF EXISTS geometry_columns;

CREATE VIEW geometry_columns AS
SELECT
   current_database()::varchar(256)  AS f_table_catalog,
   'public'::varchar(256)            AS f_table_schema,
   'my_mapdata'::varchar(256)        AS f_table_name,
   'geom'::varchar(256)              AS f_geometry_column,
   2                                 AS coord_dimension,
   4326                              AS srid,
   'POINT'::varchar(30)              AS type;


-- ============================================================================
-- GeoServer PostGIS compatibility — geography_columns view
--
-- GeoServer queries this view when checking for geography-typed columns.
-- Structure mirrors PostGIS's geography_columns view.
--
-- If a table has no geography column, this returns zero rows — which is
-- correct.  When geography columns are added to tables, add rows here.
-- ============================================================================

DROP VIEW IF EXISTS geography_columns;

CREATE VIEW geography_columns AS
SELECT
   current_database()::varchar(256)  AS f_table_catalog,
   'public'::varchar(256)            AS f_table_schema,
   t.f_table_name::varchar(256)      AS f_table_name,
   t.f_geography_column::varchar(256) AS f_geography_column,
   2                                 AS coord_dimension,
   4326                              AS srid,
   t.type::varchar(30)               AS type
FROM (
   -- Add rows here for each table with a geography column.
   -- Example:
   -- SELECT 'my_geo_table'::text AS f_table_name,
   --        'geog'::text         AS f_geography_column,
   --        'POINT'::text        AS type
   -- Currently no tables have geography columns, so this returns empty.
   SELECT NULL::text AS f_table_name,
          NULL::text AS f_geography_column,
          NULL::text AS type
   WHERE false
) t;
