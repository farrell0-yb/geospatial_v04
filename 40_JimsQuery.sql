


SELECT
   md_pk,
   md_name,
   md_address,
   md_city,
   ST_Distance(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, true) AS dist_m
FROM
   my_mapdata
WHERE
      ST_DWithin(geom::geography, ST_SetSRID(ST_GeomFromText('POINT(-105.0775 40.5853)'), 4326)::geography, 1000, true)
   AND
      geom::box2d <-> ST_MakeEnvelope(-105.09, 40.57, -105.06, 40.60)::box2d = 0
ORDER BY
    ST_Distance(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, true)
LIMIT 10;





