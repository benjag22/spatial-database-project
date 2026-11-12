insert into pudu.region (region_code, name, geom)
select region_code,
       coalesce(min(region_name), 'Región ' || region_code),
       st_multi(st_collectionextract(st_makevalid(st_union(st_makevalid(geom))), 3))
from staging.municipalities
where region_code is not null
group by region_code;

insert into pudu.municipality (municipality_code, name, province, region_code, geom)
select municipality_code, min(name), min(province), min(region_code),
       st_multi(st_collectionextract(st_makevalid(st_union(st_makevalid(geom))), 3))
from staging.municipalities
where municipality_code is not null
group by municipality_code;

create table staging.municipality_sub as
select municipality_code, st_subdivide(geom, 255) as geom from pudu.municipality;
create index on staging.municipality_sub using gist (geom);

create table staging.region_sub as
select region_code, st_subdivide(geom, 255) as geom from pudu.region;
create index on staging.region_sub using gist (geom);
analyze staging.municipality_sub;
analyze staging.region_sub;

insert into pudu.road (name, mop_code, category, route_class, surface_type, region_code, geom)
select r.name, r.mop_code, r.category, r.route_class, r.surface_type,
       coalesce((select s.region_code from staging.region_sub s where st_intersects(s.geom, st_pointonsurface(r.geom)) limit 1), (select s.region_code from staging.region_sub s order by s.geom <-> st_pointonsurface(r.geom) limit 1)),
       r.geom
from (select name, mop_code, category, route_class, surface_type,
             st_multi(st_collectionextract(st_makevalid(geom), 2)) as geom
      from staging.roads) r
where not st_isempty(r.geom);

insert into pudu.protected_area (name, protected_area_type, geom)
select name, protected_area_type, geom
from (select name, protected_area_type, st_multi(st_collectionextract(st_makevalid(geom), 3)) as geom
      from staging.snaspe) x
where not st_isempty(geom);

insert into pudu.water_body (name, body_type, geom)
select name, body_type, geom
from (select name, body_type, st_multi(st_collectionextract(st_makevalid(geom), 3)) as geom
      from staging.water_bodies) x
where not st_isempty(geom);

insert into pudu.urban_area (locality, entity, municipality_code, geom)
select u.locality, u.entity,
       coalesce((select s.municipality_code from staging.municipality_sub s where st_intersects(s.geom, st_pointonsurface(u.geom)) limit 1), (select s.municipality_code from staging.municipality_sub s order by s.geom <-> st_pointonsurface(u.geom) limit 1)),
       u.geom
from (select locality, entity, st_multi(st_collectionextract(st_makevalid(geom), 3)) as geom
      from staging.urban_areas) u
where not st_isempty(u.geom);

insert into pudu.toponym (name, topo_class, fc_code, municipality_code, geom)
select t.name, t.topo_class, t.fc_code,
       coalesce((select s.municipality_code from staging.municipality_sub s where st_intersects(s.geom, t.point) limit 1), (select s.municipality_code from staging.municipality_sub s order by s.geom <-> t.point limit 1)),
       t.point
from (select name, topo_class, fc_code, st_pointonsurface(geom) as point
      from staging.toponyms where geom is not null and not st_isempty(geom)) t;

analyze pudu.region;
analyze pudu.municipality;
analyze pudu.road;
analyze pudu.protected_area;
analyze pudu.water_body;
analyze pudu.urban_area;
analyze pudu.toponym;
