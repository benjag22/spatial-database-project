-- RF17: reemplazo de las capas BCN por una versión nueva, conservando las observaciones.
-- Flujo: cargar data/sql/<capa>.sql (recrean las tablas staging) y llamar pudu.replace_bcn_layers().
-- Las regiones y comunas se actualizan en el lugar para no romper las claves foráneas de las observaciones.
-- Si una comuna desaparece, sus observaciones pasan a la comuna vigente más cercana antes de eliminarla.
-- Si algo falla, la transacción completa se revierte. Mantiene el mismo criterio que sql/bcn_to_model.sql.
create or replace procedure pudu.replace_bcn_layers()
language plpgsql as $$
declare
    v_relocated bigint;
begin
    if not exists (select 1 from staging.municipalities where municipality_code is not null) then
        raise exception 'staging.municipalities está vacía, no se reemplazan las capas';
    end if;

    truncate pudu.urban_area, pudu.toponym, pudu.road, pudu.protected_area, pudu.water_body restart identity;

    insert into pudu.region (region_code, name, geom)
    select region_code,
           coalesce(min(region_name), 'Región ' || region_code),
           st_multi(st_collectionextract(st_makevalid(st_union(st_makevalid(geom))), 3))
    from staging.municipalities
    where region_code is not null
    group by region_code
    on conflict (region_code) do update set name = excluded.name, geom = excluded.geom;

    insert into pudu.municipality (municipality_code, name, province, region_code, geom)
    select municipality_code, min(name), min(province), min(region_code),
           st_multi(st_collectionextract(st_makevalid(st_union(st_makevalid(geom))), 3))
    from staging.municipalities
    where municipality_code is not null
    group by municipality_code
    on conflict (municipality_code) do update
        set name = excluded.name, province = excluded.province,
            region_code = excluded.region_code, geom = excluded.geom;

    update pudu.observation o
    set municipality_code = (select m.municipality_code
                             from pudu.municipality m
                             where m.municipality_code in (select s.municipality_code from staging.municipalities s
                                                           where s.municipality_code is not null)
                             order by m.geom <-> o.geom
                             limit 1)
    where o.municipality_code not in (select s.municipality_code from staging.municipalities s
                                      where s.municipality_code is not null);

    delete from pudu.municipality
    where municipality_code not in (select s.municipality_code from staging.municipalities s
                                    where s.municipality_code is not null);
    delete from pudu.region
    where region_code not in (select s.region_code from staging.municipalities s
                              where s.region_code is not null);

    perform pudu.rebuild_subdivided();

    -- observaciones que quedaron fuera de su comuna por el cambio de límites
    update pudu.observation o
    set municipality_code = s.municipality_code
    from staging.municipality_sub s
    where st_intersects(s.geom, o.geom)
      and s.municipality_code <> o.municipality_code
      and not exists (select 1 from staging.municipality_sub own
                      where own.municipality_code = o.municipality_code and st_intersects(own.geom, o.geom));
    get diagnostics v_relocated = row_count;
    raise notice 'observaciones reasignadas de comuna: %', v_relocated;

    insert into pudu.road (name, mop_code, category, route_class, surface_type, region_code, geom)
    select r.name, r.mop_code, r.category, r.route_class, r.surface_type,
           (select s.region_code from staging.region_sub s
             where st_intersects(s.geom, st_pointonsurface(r.geom)) limit 1),
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
           (select s.municipality_code from staging.municipality_sub s
             where st_intersects(s.geom, st_pointonsurface(u.geom)) limit 1),
           u.geom
    from (select locality, entity, st_multi(st_collectionextract(st_makevalid(geom), 3)) as geom
          from staging.urban_areas) u
    where not st_isempty(u.geom);

    insert into pudu.toponym (name, topo_class, fc_code, municipality_code, geom)
    select t.name, t.topo_class, t.fc_code,
           (select s.municipality_code from staging.municipality_sub s
             where st_intersects(s.geom, t.point) limit 1),
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

    call pudu.refresh_derived();
end $$;
