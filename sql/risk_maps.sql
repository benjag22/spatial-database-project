-- RF7: zonas de influencia de asentamientos (1000 m, 500 m para estancias), en UTM solo para el cálculo
create materialized view pudu.mv_settlement_buffer as
select t.id as toponym_id, t.topo_class,
       st_transform(st_buffer(st_transform(t.geom, 32718), b.radius_m), 4326) as geom
from pudu.toponym t
cross join lateral (select pudu.settlement_buffer_m(t.topo_class) as radius_m) b
where b.radius_m is not null;
create index mv_settlement_buffer_gix on pudu.mv_settlement_buffer using gist (geom);

-- RF9: máscara de cuerpos de agua
create materialized view pudu.mv_water_union as
select st_multi(st_collectionextract(st_makevalid(st_union(geom)), 3)) as geom
from pudu.water_body;
create index mv_water_union_gix on pudu.mv_water_union using gist (geom);

-- RF5: zona a restringir = buffers de asentamientos menos agua
create materialized view pudu.mv_risk_zone as
select st_multi(st_collectionextract(st_makevalid(
           st_difference(st_union(b.geom), w.geom)), 3)) as geom
from pudu.mv_settlement_buffer b
cross join pudu.mv_water_union w
group by w.geom;
create index mv_risk_zone_gix on pudu.mv_risk_zone using gist (geom);

-- RF5: zona apta para reintroducción = áreas protegidas menos zona a restringir menos agua
create materialized view pudu.mv_safe_zone as
select st_multi(st_collectionextract(st_makevalid(
           st_difference(st_difference(p.geom, z.geom), w.geom)), 3)) as geom
from (select st_union(geom) as geom from pudu.protected_area) p
cross join pudu.mv_risk_zone z
cross join pudu.mv_water_union w;
create index mv_safe_zone_gix on pudu.mv_safe_zone using gist (geom);

-- RF5 y RF9: estado de cada pudú frente a agua, zona a restringir y zona apta
create materialized view pudu.mv_pudu_risk as
select p.id, p.observation_date,
       st_intersects(p.geom, w.geom) as in_water,
       st_intersects(p.geom, z.geom) as in_risk_zone,
       st_intersects(p.geom, s.geom) as in_safe_zone
from pudu.observation p
join pudu.species sp on sp.id = p.species_id
cross join pudu.mv_water_union w
cross join pudu.mv_risk_zone z
cross join pudu.mv_safe_zone s
where sp.code = 'pudu';
create index mv_pudu_risk_id_idx on pudu.mv_pudu_risk (id);

-- RF13: distancia de cada pudú al camino más cercano (5 candidatos por índice y distancia exacta en metros)
create materialized view pudu.mv_pudu_road_distance as
select p.id, p.observation_date, d.road_id, d.dist_m
from pudu.observation p
cross join lateral (
    select c.road_id, st_distance(c.geom::geography, p.geom::geography) as dist_m
    from (select r.road_id, r.geom from pudu.road r order by r.geom <-> p.geom limit 5) c
    order by dist_m
    limit 1
) d
where p.species_id = (select s.id from pudu.species s where s.code = 'pudu');
create index mv_pudu_road_distance_id_idx on pudu.mv_pudu_road_distance (id);

-- Optimización: áreas protegidas subdivididas. Los polígonos SNASPE pesan cientos de KB y cada
-- ST_Intersects los leía completos. Cada parte conserva el id y cubre el área, usar count(distinct) al contar puntos.
create materialized view pudu.mv_protected_area_sub as
select id as protected_area_id, name, protected_area_type, st_subdivide(geom, 255) as geom
from pudu.protected_area;
create index mv_protected_area_sub_gix on pudu.mv_protected_area_sub using gist (geom);
