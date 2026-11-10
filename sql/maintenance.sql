-- RF17: refresco de vistas materializadas dependientes tras recargar capas BCN u observaciones.
-- Orden de dependencia, buffers, agua, zona a restringir, zona apta, riesgo por pudú y distancia a caminos.
create or replace procedure pudu.refresh_derived()
language plpgsql as $$
begin
    refresh materialized view pudu.mv_settlement_buffer;
    refresh materialized view pudu.mv_water_union;
    refresh materialized view pudu.mv_risk_zone;
    refresh materialized view pudu.mv_safe_zone;
    refresh materialized view pudu.mv_pudu_risk;
    refresh materialized view pudu.mv_pudu_road_distance;
end $$;

-- Regenera las comunas y regiones subdivididas que usa la carga de observaciones tras cambiar pudu.municipality.
create or replace function pudu.rebuild_subdivided()
returns void
language plpgsql as $$
begin
    truncate staging.municipality_sub;
    insert into staging.municipality_sub
    select municipality_code, st_subdivide(geom, 255) from pudu.municipality;

    truncate staging.region_sub;
    insert into staging.region_sub
    select region_code, st_subdivide(geom, 255) from pudu.region;
end $$;
