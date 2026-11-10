-- Mediciones para optimizar consultas (EXPLAIN ANALYZE). Los índices GiST y de geography están en schema.sql.

-- pudu_to_road
explain (analyze, buffers)
with d as (
    select o.id,
           (select min(st_distance(r.geom::geography, o.geom::geography))
            from (select geom from pudu.road order by geom <-> o.geom limit 5) r) as dist_m
    from pudu.observation o
    where o.species_id = (select id from pudu.species where code = 'pudu')
)
select count(*) from d;

-- dogs_near_pudus
explain (analyze, buffers)
select p.id, count(d.id)
from pudu.observation p
join pudu.observation d
  on d.species_id = (select id from pudu.species where code = 'perro')
 and st_dwithin(d.geom::geography, p.geom::geography, 1000)
where p.species_id = (select id from pudu.species where code = 'pudu')
group by p.id
order by 2 desc
limit 10;

-- Conteo de amenazas con radio de 1000 m
explain (analyze, buffers)
select count(*) from pudu.pudu_threats(1000);

-- Pudúes dentro de áreas protegidas
explain (analyze, buffers)
select count(*)
from pudu.observation o
where o.species_id = (select id from pudu.species where code = 'pudu')
  and exists (select 1 from pudu.protected_area a where st_intersects(a.geom, o.geom));

-- Búsqueda por radio con el índice de geography
explain (analyze, buffers)
select count(*)
from pudu.observation
where st_dwithin(geom::geography, st_setsrid(st_makepoint(-73.0, -41.5), 4326)::geography, 10000);

-- Poda de particiones por especie
explain (analyze, buffers)
select count(*) from pudu.observation where species_id = 1;
