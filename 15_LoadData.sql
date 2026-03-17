-- ============================================================================
--
-- Purpose  : Load data from 19_mapData.pipe into my_mapdata, then populate
--            the geometry column (geom) and the geo_hash8 column.
--
-- Requires : 10_CreateGeometryType.sql  (geometry type + ST_MakePoint)
--            11_CreateSchema.sql        (my_mapdata table)
--
-- The pipe file has columns:
--   md_pk|md_lat|md_lng|geo_hash10|md_name|md_address|md_city|md_province|
--   md_country|md_postcode|md_phone|md_category|md_subcategory|md_mysource|
--   md_tags|md_type
--
-- After loading, we backfill:
--   geom      = ST_MakePoint(lng::double precision, lat::double precision)
--   geo_hash8 = left(geo_hash10, 8)
--
-- ============================================================================

DELETE FROM my_mapdata;

-- This command must be on a single line
--
\copy my_mapdata(md_pk, md_lat, md_lng, geo_hash10, md_name, md_address, md_city, md_province, md_country, md_postcode, md_phone, md_category, md_subcategory, md_mysource, md_tags, md_type) FROM '19_mapData.pipe' WITH (FORMAT csv, DELIMITER '|', HEADER true, ROWS_PER_TRANSACTION 100);

-- Populate the geometry column from the text lat/lng fields
--
UPDATE my_mapdata
SET
   geom = ST_MakePoint(
      md_lng::double precision,
      md_lat::double precision
   )
WHERE
   md_lat IS NOT NULL
   AND md_lng IS NOT NULL;

-- Populate geo_hash8 from geo_hash10
--
UPDATE my_mapdata
SET
   geo_hash8 = LEFT(geo_hash10, 8)
WHERE
   geo_hash10 IS NOT NULL
   AND (geo_hash8 IS NULL OR geo_hash8 <> LEFT(geo_hash10, 8));
