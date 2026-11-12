
select 'region' as table_name, count(*) as records, round(sum(area_km2)) as total, 'km²' as unit from pudu.region
union all select 'municipality', count(*), round(sum(area_km2)), 'km²' from pudu.municipality
union all select 'road', count(*), round(sum(length_m) / 1000), 'km' from pudu.road
union all select 'protected_area', count(*), round(sum(area_km2)), 'km²' from pudu.protected_area
union all select 'water_body', count(*), round(sum(area_km2)), 'km²' from pudu.water_body
union all select 'urban_area', count(*), round(sum(area_km2)), 'km²' from pudu.urban_area
union all select 'toponym', count(*), null, null from pudu.toponym
union all select 'observation', count(*), null, null from pudu.observation;

-- observations_by_species | Volume, date range and uncertainty by species and source
select sp.common_name as species, so.code as source, count(*) as records,
       min(o.observation_date) as first_date, max(o.observation_date) as last_date,
       count(*) filter (where o.observation_date is null) as without_date,
       round(percentile_cont(0.5) within group (order by o.uncertainty_m)::numeric) as median_uncertainty_m
from pudu.observation o
join pudu.species sp on sp.id = o.species_id
join pudu.source  so on so.id = o.source_id
group by sp.id, sp.common_name, so.code
order by sp.id, so.code;

-- rejections_by_reason | Records that did not pass the load validation (RF2)
select source, species, coalesce(rejection_reason, 'aceptada') as result, count(*) as records
from staging.raw_observation
group by source, species, result
order by source, species, records desc;

-- observations_by_region | Count by species and region (key join, no spatial computation)
select r.region_code, r.name as region,
       count(*) filter (where sp.code = 'pudu')  as pudu,
       count(*) filter (where sp.code = 'puma')  as puma,
       count(*) filter (where sp.code = 'perro') as dog
from pudu.observation o
join pudu.species      sp on sp.id = o.species_id
join pudu.municipality m  on m.municipality_code = o.municipality_code
join pudu.region       r  on r.region_code = m.region_code
group by r.region_code, r.name
order by r.region_code;

-- multicriteria_filter | Pudus in Los Lagos between 2015 and 2025, by source (RF3)
select so.code as source, count(*) as records
from pudu.observation o
join pudu.species      sp on sp.id = o.species_id
join pudu.source       so on so.id = o.source_id
join pudu.municipality m  on m.municipality_code = o.municipality_code
where sp.code = 'pudu'
  and o.observation_date between date '2015-01-01' and date '2025-12-31'
  and m.region_code = 10
group by so.code;

-- toponyms_by_class | Toponym classes, to choose the settlements (RF6)
select topo_class, count(*) as records
from pudu.toponym
group by topo_class
order by records desc;

-- pudus_in_snaspe | Pudus inside a protected wild area (ST_Intersects, RF8)
select count(*) as pudus,
       count(*) filter (where inside) as in_snaspe,
       round(100.0 * count(*) filter (where inside) / nullif(count(*), 0), 1) as percentage
from (select exists (select 1 from pudu.mv_protected_area_sub a where st_intersects(a.geom, o.geom)) as inside
      from pudu.observation o
      join pudu.species sp on sp.id = o.species_id
      where sp.code = 'pudu') x;

-- pudu_to_road | Distance from each pudu to the nearest road (RF4)
-- Filter: the 5 nearest segments according to the index (<->). Refinement: exact distance in meters.
-- The distances are precomputed in pudu.mv_pudu_road_distance (RF13), refreshed by pudu.refresh_derived().
select count(*) as pudus,
       round(percentile_cont(0.5) within group (order by dist_m)::numeric) as median_m,
       count(*) filter (where dist_m <= 500) as within_500_m,
       round(100.0 * count(*) filter (where dist_m <= 500) / nullif(count(*), 0), 1) as percentage_500_m
from pudu.mv_pudu_road_distance;

-- dogs_near_pudus | Pudus with the most dog records within 1 km (ST_DWithin, RF4)
select p.id, p.observation_date, m.name as municipality, count(d.id) as dogs_within_1_km
from pudu.observation p
join pudu.municipality m on m.municipality_code = p.municipality_code
join pudu.observation d
  on d.species_id = (select id from pudu.species where code = 'perro')
 and st_dwithin(d.geom::geography, p.geom::geography, 1000)
 and (d.observation_date is null or p.observation_date is null or abs(d.observation_date - p.observation_date) <= 730)
 and (d.uncertainty_m is null or d.uncertainty_m <= 1000)
where p.species_id = (select id from pudu.species where code = 'pudu')
group by p.id, p.observation_date, m.name
order by dogs_within_1_km desc
limit 10;

-- municipality_consistency | Do neighboring municipalities overlap? (topological constraint: disjoint interiors)
select count(*) as overlapping_pairs,
       round(coalesce(sum(st_area(st_intersection(a.geom, b.geom)::geography)), 0)::numeric) as overlap_area_m2
from pudu.municipality a
join pudu.municipality b
  on a.municipality_code < b.municipality_code
 and st_intersects(a.geom, b.geom)
 and st_relate(a.geom, b.geom, '2********');

-- observations_in_water | Observations falling inside lakes or ice (likely position error)
select sp.common_name as species, count(*) as records_in_water
from pudu.observation o
join pudu.species sp on sp.id = o.species_id
where exists (select 1 from pudu.water_body w where st_intersects(w.geom, o.geom))
group by sp.common_name;

-- plan_with_index | The optimizer uses the GiST index in a radius search (filter + refinement)
explain (costs off)
select count(*)
from pudu.observation
where st_dwithin(geom::geography, st_setsrid(st_makepoint(-73.0, -41.5), 4326)::geography, 10000);


-- observations_by_partition | Filas por partición de especie (RF13)
select tableoid::regclass as partition, count(*) as records
from pudu.observation
group by 1
order by 1;

-- load_history | Registro de cargas por lote, fuente y especie (RF16)
select load_batch, source, species, rows_read, rows_rejected, rows_inserted, rows_existing
from pudu.load_log
order by id;

-- observations_by_year | Evolución temporal de los avistamientos por año y especie
select extract(year from o.observation_date)::int as year,
       count(*) filter (where sp.code = 'pudu')  as pudu,
       count(*) filter (where sp.code = 'puma')  as puma,
       count(*) filter (where sp.code = 'perro') as dog
from pudu.observation o
join pudu.species sp on sp.id = o.species_id
where o.observation_date is not null
group by 1
order by 1;

-- pudus_by_month | Estacionalidad, solo fechas con precisión de día o mes
select extract(month from o.observation_date)::int as month, count(*) as pudus
from pudu.observation o
join pudu.species sp on sp.id = o.species_id
where sp.code = 'pudu' and o.date_precision in ('día', 'mes')
group by 1
order by 1;

-- pudu_density_by_municipality | Agrupación por densidad, pudúes por km² de comuna
select m.name as municipality, count(*) as pudus, m.area_km2,
       round(count(*) / nullif(m.area_km2, 0), 4) as pudus_per_km2
from pudu.observation o
join pudu.species sp on sp.id = o.species_id
join pudu.municipality m on m.municipality_code = o.municipality_code
where sp.code = 'pudu'
group by m.municipality_code, m.name, m.area_km2
order by pudus_per_km2 desc nulls last
limit 10;
