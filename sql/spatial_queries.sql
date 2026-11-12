
-- Distancia (en metros) de cada pudú al camino más cercano --
select p.id,
       p.observation_date,
       round((select min(st_distance(c.geom::geography, p.geom::geography))
              from (select r.geom from pudu.road r order by r.geom <-> p.geom limit 5) c)::numeric) as distance_to_road_m
from pudu.observation p
join pudu.species s on s.id = p.species_id
where s.code = 'pudu'
order by distance_to_road_m
limit 10;


-- Pudúes cerca de amenazas (con ST_DWithin) --
select count(*) as pudus,

       count(*) filter (where exists (
           select 1 from pudu.road r
           where st_dwithin(r.geom, p.geom, 0.02)
             and st_dwithin(r.geom::geography, p.geom::geography, 1000)
       )) as near_road,

       count(*) filter (where exists (
           select 1 from pudu.toponym t
           where pudu.settlement_buffer_m(t.topo_class) is not null
             and st_dwithin(t.geom, p.geom, 0.02)
             and st_dwithin(t.geom::geography, p.geom::geography, 1000)
       )) as near_settlement,

       count(*) filter (where exists (
           select 1
           from pudu.observation d
           join pudu.species sd on sd.id = d.species_id
           where sd.code = 'perro'
             and st_dwithin(d.geom, p.geom, 0.02)
             and st_dwithin(d.geom::geography, p.geom::geography, 1000)
       )) as near_dog
from pudu.observation p
join pudu.species s on s.id = p.species_id
where s.code = 'pudu';


-- Conteo de amenazas por pudú (dentro de 1000 m) --
-- Usa el índice geography (observation_geog_gix) y el índice GiST de road con && como filtro previo
select p.id, p.observation_date, dog_c.dogs, road_c.road_segments
from pudu.observation p
join pudu.species s on s.id = p.species_id
cross join lateral (
    select count(*) as dogs
    from pudu.observation d
    where d.species_id = (select id from pudu.species where code = 'perro')
      and st_dwithin(d.geom::geography, p.geom::geography, 1000)
) dog_c
cross join lateral (
    select count(*) as road_segments
    from pudu.road r
    where r.geom && st_expand(p.geom, 0.02)
      and st_dwithin(r.geom::geography, p.geom::geography, 1000)
) road_c
where s.code = 'pudu'
order by dog_c.dogs + road_c.road_segments desc, p.id
limit 10;


-- Buffers de asentamientos rurales (con ST_Buffer) --

-- Buffers generados: cantidad y superficie total por clase
select b.topo_class, b.buffer_m, count(*) as buffers,
       round((sum(st_area(b.geom::geography)) / 1e6)::numeric, 1) as total_area_km2
from (
    select t.topo_class, r.radius_m as buffer_m,
           st_transform(st_buffer(st_transform(t.geom, pudu.utm_srid(t.geom)), r.radius_m), 4326) as geom
    from pudu.toponym t
    cross join lateral (select pudu.settlement_buffer_m(t.topo_class) as radius_m) r
    where r.radius_m is not null
) b
group by b.topo_class, b.buffer_m
order by buffers desc;

-- Pudúes que quedan dentro de alguna zona de perturbación (ST_Intersects)
select count(*) as pudus,
       count(*) filter (where exists (
           select 1
           from pudu.toponym t
           cross join lateral (select pudu.settlement_buffer_m(t.topo_class) as radius_m) r
           where r.radius_m is not null
             and st_dwithin(t.geom, p.geom, 0.02)
             and st_intersects(
                   st_transform(st_buffer(st_transform(t.geom, pudu.utm_srid(t.geom)), r.radius_m), 4326),
                   p.geom)
       )) as inside_buffer
from pudu.observation p
join pudu.species s on s.id = p.species_id
where s.code = 'pudu';


-- Solapamiento con áreas protegidas (SNASPE) --
select a.name, a.protected_area_type, count(distinct p.id) as pudus
from pudu.mv_protected_area_sub a
join pudu.observation p on st_intersects(a.geom, p.geom)
join pudu.species s on s.id = p.species_id
where s.code = 'pudu'
group by a.protected_area_id, a.name, a.protected_area_type
order by pudus desc
limit 10;

-- Pudúes con pumas cercanos (1000 m, ±2 años, incertidumbre hasta 1000 m) --
select count(*) as pudus, count(*) filter (where t.pumas > 0) as with_puma_within_1_km,
       count(*) filter (where t.dogs > 0) as with_dog_within_1_km
from pudu.pudu_threats(1000) t;

-- Distancia de cada pudú a la zona urbana más cercana (RF4) --
select count(*) as pudus,
       round(percentile_cont(0.5) within group (order by dist_m)::numeric) as median_m,
       count(*) filter (where dist_m <= 1000) as within_1_km
from pudu.mv_pudu_urban_distance;

-- Caminos que cruzan áreas protegidas: tramos y kilómetros dentro de cada área --
select a.name, a.protected_area_type, count(distinct r.road_id) as road_segments,
       round((sum(st_length(st_intersection(r.geom, a.geom)::geography)) / 1000)::numeric, 1) as km_inside
from pudu.mv_protected_area_sub a
join pudu.road r on st_intersects(r.geom, a.geom)
group by a.protected_area_id, a.name, a.protected_area_type
order by km_inside desc
limit 10;
