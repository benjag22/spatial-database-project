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
        new.municipality_code := pudu.locate_municipality(st_pointonsurface(new.geom));
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
