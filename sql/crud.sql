-- RF10: operaciones CRUD con integridad referencial (claves foráneas) y topológica.
-- Las funciones validan y devuelven errores claros. Los triggers protegen además el DML directo.
-- Se carga después de los datos para que los triggers no actúen en la carga masiva.

-- Comuna que contiene el punto, o la más cercana a menos de la tolerancia (mismo criterio de la carga)
create or replace function pudu.locate_municipality(p_geom geometry, p_tolerance_m double precision default 1000)
returns integer
language sql stable as $$
    select coalesce(
        (select m.municipality_code
         from pudu.municipality m
         where st_intersects(m.geom, p_geom)
         order by m.municipality_code
         limit 1),
        (select n.municipality_code
         from (select m.municipality_code, m.geom
               from pudu.municipality m
               order by m.geom <-> p_geom
               limit 1) n
         where st_dwithin(n.geom::geography, p_geom::geography, p_tolerance_m)))
$$;

-- Polígono en EPSG:4326, válido y como multipolígono
create or replace function pudu.clean_polygon(p_geom geometry)
returns geometry
language plpgsql as $$
declare
    g geometry;
begin
    if p_geom is null then
        raise exception 'la geometría es nula' using errcode = '23502';
    end if;
    if st_srid(p_geom) <> 4326 then
        raise exception 'la geometría debe estar en EPSG:4326 (recibido %)', st_srid(p_geom)
            using errcode = '23514';
    end if;
    g := st_multi(st_collectionextract(st_makevalid(p_geom), 3));
    if st_isempty(g) then
        raise exception 'la geometría no contiene polígonos' using errcode = '23514';
    end if;
    return g;
end $$;

-- Regla topológica, la comuna toca su región y no solapa sus interiores con otras comunas
create or replace function pudu.check_municipality_topology(
    p_code integer, p_region smallint, p_geom geometry, p_tolerance_m2 double precision)
returns void
language plpgsql as $$
declare
    v_other   integer;
    v_overlap double precision;
begin
    if not exists (select 1 from pudu.region r where r.region_code = p_region) then
        raise exception 'la región % no existe', p_region using errcode = '23503';
    end if;
    if not exists (select 1 from pudu.region r where r.region_code = p_region and st_intersects(r.geom, p_geom)) then
        raise exception 'la comuna % no intersecta la región %', p_code, p_region using errcode = '23514';
    end if;

    select m.municipality_code, st_area(st_intersection(m.geom, p_geom)::geography)
      into v_other, v_overlap
    from pudu.municipality m
    where m.municipality_code <> p_code
      and m.geom && p_geom
      and st_relate(m.geom, p_geom, '2********')
    order by 2 desc
    limit 1;

    if v_overlap > p_tolerance_m2 then
        raise exception 'la comuna % solapa % m² con la comuna %', p_code, round(v_overlap), v_other
            using errcode = '23514';
    end if;
end $$;

-- La geometría de la región es la unión de sus comunas
create or replace function pudu.rebuild_region(p_region smallint)
returns void
language sql as $$
    update pudu.region r
    set geom = u.geom
    from (select st_multi(st_collectionextract(st_makevalid(st_union(st_makevalid(m.geom))), 3)) as geom
          from pudu.municipality m
          where m.region_code = p_region) u
    where r.region_code = p_region
      and u.geom is not null
      and not st_isempty(u.geom)
$$;

-- Observaciones

create or replace function pudu.add_observation(
    p_species text, p_source text, p_lon double precision, p_lat double precision,
    p_date date default null, p_date_precision text default null, p_uncertainty_m numeric default null,
    p_locality text default null, p_record_type text default null, p_source_record_id text default null)
returns bigint
language plpgsql as $$
declare
    v_species smallint;
    v_source  smallint;
    v_geom    geometry;
    v_mun     integer;
    v_id      bigint;
begin
    select id into v_species from pudu.species where code = p_species;
    if v_species is null then
        raise exception 'la especie % no existe', p_species using errcode = '23503';
    end if;
    select id into v_source from pudu.source where code = p_source;
    if v_source is null then
        raise exception 'la fuente % no existe', p_source using errcode = '23503';
    end if;
    if p_lon is null or p_lat is null or p_lon not between -180 and 180 or p_lat not between -90 and 90 then
        raise exception 'coordenadas inválidas' using errcode = '23514';
    end if;

    v_geom := st_setsrid(st_makepoint(p_lon, p_lat), 4326);
    v_mun := pudu.locate_municipality(v_geom);
    if v_mun is null then
        raise exception 'la observación cae fuera de Chile (a más de 1 km de toda comuna)' using errcode = '23514';
    end if;

    insert into pudu.observation
        (species_id, source_id, source_record_id, observation_date, date_precision, uncertainty_m,
         locality, record_type, municipality_code, geom)
    values (v_species, v_source, coalesce(p_source_record_id, 'manual-' || gen_random_uuid()::text),
            p_date, p_date_precision, p_uncertainty_m, p_locality, p_record_type, v_mun, v_geom)
    returning id into v_id;
    return v_id;
end $$;

-- Los parámetros nulos dejan el valor actual. Lon y lat se indican juntas.
create or replace function pudu.update_observation(
    p_id bigint, p_date date default null, p_date_precision text default null,
    p_uncertainty_m numeric default null, p_locality text default null, p_record_type text default null,
    p_lon double precision default null, p_lat double precision default null)
returns boolean
language plpgsql as $$
declare
    v_geom geometry;
    v_mun  integer;
begin
    if (p_lon is null) <> (p_lat is null) then
        raise exception 'lon y lat deben indicarse juntas' using errcode = '23514';
    end if;
    if p_lon is not null then
        if p_lon not between -180 and 180 or p_lat not between -90 and 90 then
            raise exception 'coordenadas inválidas' using errcode = '23514';
        end if;
        v_geom := st_setsrid(st_makepoint(p_lon, p_lat), 4326);
        v_mun := pudu.locate_municipality(v_geom);
        if v_mun is null then
            raise exception 'la observación cae fuera de Chile (a más de 1 km de toda comuna)' using errcode = '23514';
        end if;
    end if;

    update pudu.observation o
    set observation_date  = coalesce(p_date, o.observation_date),
        date_precision    = coalesce(p_date_precision, o.date_precision),
        uncertainty_m     = coalesce(p_uncertainty_m, o.uncertainty_m),
        locality          = coalesce(p_locality, o.locality),
        record_type       = coalesce(p_record_type, o.record_type),
        municipality_code = coalesce(v_mun, o.municipality_code),
        geom              = coalesce(v_geom, o.geom)
    where o.id = p_id;
    return found;
end $$;

create or replace function pudu.delete_observation(p_id bigint)
returns boolean
language plpgsql as $$
begin
    delete from pudu.observation where id = p_id;
    return found;
end $$;

-- Comunas (territorial)

create or replace function pudu.add_municipality(
    p_code integer, p_name text, p_province text, p_region_code smallint, p_geom geometry,
    p_tolerance_m2 double precision default 0)
returns integer
language plpgsql as $$
declare
    g geometry;
begin
    g := pudu.clean_polygon(p_geom);
    perform pudu.check_municipality_topology(p_code, p_region_code, g, p_tolerance_m2);
    insert into pudu.municipality (municipality_code, name, province, region_code, geom)
    values (p_code, p_name, p_province, p_region_code, g);
    perform pudu.rebuild_region(p_region_code);
    perform pudu.rebuild_subdivided();
    return p_code;
end $$;

-- Los parámetros nulos dejan el valor actual. Una nueva geometría no puede dejar observaciones asociadas fuera de la comuna.
create or replace function pudu.update_municipality(
    p_code integer, p_name text default null, p_province text default null,
    p_region_code smallint default null, p_geom geometry default null,
    p_tolerance_m2 double precision default 0)
returns boolean
language plpgsql as $$
declare
    v         pudu.municipality%rowtype;
    g         geometry;
    r         smallint;
    v_orphans bigint;
begin
    select * into v from pudu.municipality where municipality_code = p_code for update;
    if not found then
        return false;
    end if;

    r := coalesce(p_region_code, v.region_code);
    g := case when p_geom is null then v.geom else pudu.clean_polygon(p_geom) end;

    if p_geom is not null or r <> v.region_code then
        perform pudu.check_municipality_topology(p_code, r, g, p_tolerance_m2);
    end if;

    if p_geom is not null then
        select count(*) into v_orphans
        from pudu.observation o
        where o.municipality_code = p_code
          and not st_intersects(g, o.geom)
          and not st_dwithin(g::geography, o.geom::geography, 1000);
        if v_orphans > 0 then
            raise exception 'la nueva geometría deja % observaciones de la comuna % fuera de ella', v_orphans, p_code
                using errcode = '23514';
        end if;
    end if;

    update pudu.municipality
    set name = coalesce(p_name, name),
        province = coalesce(p_province, province),
        region_code = r,
        geom = g
    where municipality_code = p_code;

    perform pudu.rebuild_region(r);
    if r <> v.region_code then
        perform pudu.rebuild_region(v.region_code);
    end if;
    if p_geom is not null then
        perform pudu.rebuild_subdivided();
    end if;
    return true;
end $$;

-- No se elimina una comuna con registros asociados
create or replace function pudu.delete_municipality(p_code integer)
returns boolean
language plpgsql as $$
declare
    v_region smallint;
begin
    if exists (select 1 from pudu.observation where municipality_code = p_code) then
        raise exception 'la comuna % tiene observaciones asociadas', p_code using errcode = '23503';
    end if;
    if exists (select 1 from pudu.urban_area where municipality_code = p_code) then
        raise exception 'la comuna % tiene áreas urbanas asociadas', p_code using errcode = '23503';
    end if;
    if exists (select 1 from pudu.toponym where municipality_code = p_code) then
        raise exception 'la comuna % tiene topónimos asociados', p_code using errcode = '23503';
    end if;

    delete from pudu.municipality where municipality_code = p_code returning region_code into v_region;
    if not found then
        return false;
    end if;
    perform pudu.rebuild_region(v_region);
    perform pudu.rebuild_subdivided();
    return true;
end $$;

-- Triggers, protegen el DML directo sobre las tablas

create or replace function pudu.tg_observation_integrity()
returns trigger
language plpgsql as $$
begin
    if tg_op = 'UPDATE'
       and new.geom is distinct from old.geom
       and new.municipality_code is not distinct from old.municipality_code then
        new.municipality_code := null;
    end if;
    if new.municipality_code is null then
        new.municipality_code := pudu.locate_municipality(new.geom);
        if new.municipality_code is null then
            raise exception 'la observación cae fuera de Chile (a más de 1 km de toda comuna)'
                using errcode = '23514';
        end if;
    end if;
    return new;
end $$;

create or replace function pudu.tg_locate_municipality()
returns trigger
language plpgsql as $$
begin
    if tg_op = 'UPDATE'
       and new.geom is distinct from old.geom
       and new.municipality_code is not distinct from old.municipality_code then
        new.municipality_code := null;
    end if;
    if new.municipality_code is null then
        new.municipality_code := coalesce(pudu.locate_municipality(st_pointonsurface(new.geom)),
            (select m.municipality_code from pudu.municipality m order by m.geom <-> st_pointonsurface(new.geom) limit 1));
    end if;
    return new;
end $$;

drop trigger if exists observation_integrity on pudu.observation;
create trigger observation_integrity
    before insert or update on pudu.observation
    for each row execute function pudu.tg_observation_integrity();

drop trigger if exists toponym_locate on pudu.toponym;
create trigger toponym_locate
    before insert or update on pudu.toponym
    for each row execute function pudu.tg_locate_municipality();

drop trigger if exists urban_area_locate on pudu.urban_area;
create trigger urban_area_locate
    before insert or update on pudu.urban_area
    for each row execute function pudu.tg_locate_municipality();

-- CRUD de las demás capas (RF10). La comuna o región se asigna por contención y, si no hay, por cercanía (triggers).

create or replace function pudu.clean_line(p_geom geometry)
returns geometry
language plpgsql as $$
declare
    g geometry;
begin
    if p_geom is null then
        raise exception 'la geometría es nula' using errcode = '23502';
    end if;
    if st_srid(p_geom) <> 4326 then
        raise exception 'la geometría debe estar en EPSG:4326 (recibido %)', st_srid(p_geom) using errcode = '23514';
    end if;
    g := st_multi(st_collectionextract(st_makevalid(p_geom), 2));
    if st_isempty(g) then
        raise exception 'la geometría no contiene líneas' using errcode = '23514';
    end if;
    return g;
end $$;

create or replace function pudu.clean_point(p_geom geometry)
returns geometry
language plpgsql as $$
begin
    if p_geom is null then
        raise exception 'la geometría es nula' using errcode = '23502';
    end if;
    if st_srid(p_geom) <> 4326 or geometrytype(p_geom) <> 'POINT' then
        raise exception 'se espera un punto en EPSG:4326' using errcode = '23514';
    end if;
    return p_geom;
end $$;

create or replace function pudu.tg_locate_region()
returns trigger
language plpgsql as $$
declare
    pt geometry;
begin
    if tg_op = 'UPDATE' and new.geom is distinct from old.geom
       and new.region_code is not distinct from old.region_code then
        new.region_code := null;
    end if;
    if new.region_code is null then
        pt := st_pointonsurface(new.geom);
        new.region_code := coalesce(
            (select r.region_code from pudu.region r where st_intersects(r.geom, pt) order by r.region_code limit 1),
            (select r.region_code from pudu.region r order by r.geom <-> pt limit 1));
    end if;
    return new;
end $$;

drop trigger if exists road_locate on pudu.road;
create trigger road_locate
    before insert or update on pudu.road
    for each row execute function pudu.tg_locate_region();

-- Caminos
create or replace function pudu.add_road(p_name text, p_mop_code text, p_category text, p_route_class text,
                                         p_surface_type text, p_geom geometry)
returns bigint
language plpgsql as $$
declare
    v_id bigint;
begin
    insert into pudu.road (name, mop_code, category, route_class, surface_type, geom)
    values (p_name, p_mop_code, p_category, p_route_class, p_surface_type, pudu.clean_line(p_geom))
    returning road_id into v_id;
    return v_id;
end $$;

create or replace function pudu.update_road(p_id bigint, p_name text default null, p_mop_code text default null,
                                            p_category text default null, p_route_class text default null,
                                            p_surface_type text default null, p_geom geometry default null)
returns boolean
language plpgsql as $$
begin
    update pudu.road
    set name = coalesce(p_name, name), mop_code = coalesce(p_mop_code, mop_code),
        category = coalesce(p_category, category), route_class = coalesce(p_route_class, route_class),
        surface_type = coalesce(p_surface_type, surface_type),
        geom = case when p_geom is null then geom else pudu.clean_line(p_geom) end
    where road_id = p_id;
    return found;
end $$;

create or replace function pudu.delete_road(p_id bigint)
returns boolean
language plpgsql as $$
begin
    delete from pudu.road where road_id = p_id;
    return found;
end $$;

-- Áreas protegidas
create or replace function pudu.add_protected_area(p_name text, p_type text, p_geom geometry)
returns integer
language plpgsql as $$
declare
    v_id integer;
begin
    insert into pudu.protected_area (name, protected_area_type, geom)
    values (p_name, p_type, pudu.clean_polygon(p_geom)) returning id into v_id;
    return v_id;
end $$;

create or replace function pudu.update_protected_area(p_id integer, p_name text default null,
                                                      p_type text default null, p_geom geometry default null)
returns boolean
language plpgsql as $$
begin
    update pudu.protected_area
    set name = coalesce(p_name, name), protected_area_type = coalesce(p_type, protected_area_type),
        geom = case when p_geom is null then geom else pudu.clean_polygon(p_geom) end
    where id = p_id;
    return found;
end $$;

create or replace function pudu.delete_protected_area(p_id integer)
returns boolean
language plpgsql as $$
begin
    delete from pudu.protected_area where id = p_id;
    return found;
end $$;

-- Masas de agua
create or replace function pudu.add_water_body(p_name text, p_type text, p_geom geometry)
returns integer
language plpgsql as $$
declare
    v_id integer;
begin
    insert into pudu.water_body (name, body_type, geom)
    values (p_name, p_type, pudu.clean_polygon(p_geom)) returning id into v_id;
    return v_id;
end $$;

create or replace function pudu.update_water_body(p_id integer, p_name text default null,
                                                  p_type text default null, p_geom geometry default null)
returns boolean
language plpgsql as $$
begin
    update pudu.water_body
    set name = coalesce(p_name, name), body_type = coalesce(p_type, body_type),
        geom = case when p_geom is null then geom else pudu.clean_polygon(p_geom) end
    where id = p_id;
    return found;
end $$;

create or replace function pudu.delete_water_body(p_id integer)
returns boolean
language plpgsql as $$
begin
    delete from pudu.water_body where id = p_id;
    return found;
end $$;

-- Áreas urbanas
create or replace function pudu.add_urban_area(p_locality text, p_entity text, p_geom geometry)
returns integer
language plpgsql as $$
declare
    v_id integer;
begin
    insert into pudu.urban_area (locality, entity, geom)
    values (p_locality, p_entity, pudu.clean_polygon(p_geom)) returning id into v_id;
    return v_id;
end $$;

create or replace function pudu.update_urban_area(p_id integer, p_locality text default null,
                                                  p_entity text default null, p_geom geometry default null)
returns boolean
language plpgsql as $$
begin
    update pudu.urban_area
    set locality = coalesce(p_locality, locality), entity = coalesce(p_entity, entity),
        geom = case when p_geom is null then geom else pudu.clean_polygon(p_geom) end
    where id = p_id;
    return found;
end $$;

create or replace function pudu.delete_urban_area(p_id integer)
returns boolean
language plpgsql as $$
begin
    delete from pudu.urban_area where id = p_id;
    return found;
end $$;

-- Topónimos
create or replace function pudu.add_toponym(p_name text, p_topo_class text, p_fc_code text, p_geom geometry)
returns integer
language plpgsql as $$
declare
    v_id integer;
begin
    insert into pudu.toponym (name, topo_class, fc_code, geom)
    values (p_name, p_topo_class, p_fc_code, pudu.clean_point(p_geom)) returning id into v_id;
    return v_id;
end $$;

create or replace function pudu.update_toponym(p_id integer, p_name text default null, p_topo_class text default null,
                                               p_fc_code text default null, p_geom geometry default null)
returns boolean
language plpgsql as $$
begin
    update pudu.toponym
    set name = coalesce(p_name, name), topo_class = coalesce(p_topo_class, topo_class),
        fc_code = coalesce(p_fc_code, fc_code),
        geom = case when p_geom is null then geom else pudu.clean_point(p_geom) end
    where id = p_id;
    return found;
end $$;

create or replace function pudu.delete_toponym(p_id integer)
returns boolean
language plpgsql as $$
begin
    delete from pudu.toponym where id = p_id;
    return found;
end $$;
