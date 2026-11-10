
-- Distancia (en metros) de cada pudú al camino más cercano --
select p.id,
       p.observation_date,
       round((select st_distance(st_transform(r.geom, 32718), st_transform(p.geom, 32718))
              from pudu.road r
              order by r.geom <-> p.geom
              limit 1)::numeric) as distance_to_road_m
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
             and st_dwithin(st_transform(r.geom, 32718), st_transform(p.geom, 32718), 1000)
       )) as near_road,

       count(*) filter (where exists (
           select 1 from pudu.toponym t
           where t.geom && st_makeenvelope(-80, -60, -65, -17, 4326)
             and t.topo_class ilike any (array['%poblado%', '%localidad%', '%caser%', '%estancia%', '%minero%'])
             and st_dwithin(t.geom, p.geom, 0.02)
             and st_dwithin(st_transform(t.geom, 32718), st_transform(p.geom, 32718), 1000)
       )) as near_settlement,

       count(*) filter (where exists (
           select 1
           from pudu.observation d
           join pudu.species sd on sd.id = d.species_id
           where sd.code = 'perro'
             and st_dwithin(d.geom, p.geom, 0.02)
             and st_dwithin(st_transform(d.geom, 32718), st_transform(p.geom, 32718), 1000)
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
select topo_class, buffer_m, count(*) as buffers,
       round((sum(st_area(geom::geography)) / 1e6)::numeric, 1) as total_area_km2
from (
    select t.topo_class,
           case when t.topo_class ilike '%estancia%' then 500 else 1000 end as buffer_m,
           st_transform(
               st_buffer(st_transform(t.geom, 32718),
                         case when t.topo_class ilike '%estancia%' then 500 else 1000 end),
               4326) as geom
    from pudu.toponym t
    where t.geom && st_makeenvelope(-80, -60, -65, -17, 4326)
      and t.topo_class ilike any (array['%poblado%', '%localidad%', '%caser%', '%estancia%', '%minero%'])
) b
group by topo_class, buffer_m
order by buffers desc;

-- Pudúes que quedan dentro de alguna zona de perturbación (ST_Intersects)
select count(*) as pudus,
       count(*) filter (where exists (
           select 1
           from pudu.toponym t
           where t.geom && st_makeenvelope(-80, -60, -65, -17, 4326)
             and t.topo_class ilike any (array['%poblado%', '%localidad%', '%caser%', '%estancia%', '%minero%'])
             and st_dwithin(t.geom, p.geom, 0.02)
             and st_intersects(
                   st_transform(
                       st_buffer(st_transform(t.geom, 32718),
                                 case when t.topo_class ilike '%estancia%' then 500 else 1000 end),
                       4326),
                   p.geom)
       )) as inside_buffer
from pudu.observation p
join pudu.species s on s.id = p.species_id
where s.code = 'pudu';


-- Solapamiento con áreas protegidas (SNASPE) --
select a.name, a.protected_area_type, count(*) as pudus
from pudu.protected_area a
join pudu.observation p on st_intersects(a.geom, p.geom)
join pudu.species s on s.id = p.species_id
where s.code = 'pudu'
group by a.id, a.name, a.protected_area_type
order by pudus desc
limit 10;
