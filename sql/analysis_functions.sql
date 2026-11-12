-- RF4 y RF7: consultas y buffers parametrizados por el usuario (radios en metros).
-- Usan ST_DWithin sobre geography con los índices GiST de geography, sin depender de la latitud.

-- Conteo de amenazas por pudú dentro del radio indicado.
-- p_window_years: solo cuentan perros y pumas registrados a ±N años del avistamiento (null la desactiva; sin fecha se conservan).
-- p_max_uncertainty_m: descarta registros con incertidumbre mayor (null la desactiva; sin incertidumbre se conservan).
drop function if exists pudu.pudu_threats(double precision);
create or replace function pudu.pudu_threats(
    p_radius_m double precision default 1000,
    p_window_years integer default 2,
    p_max_uncertainty_m numeric default 1000)
returns table (id bigint, observation_date date, dogs bigint, pumas bigint, road_segments bigint, settlements bigint)
language sql stable as $$
    select p.id, p.observation_date, animal_c.dogs, animal_c.pumas, road_c.n, settlement_c.n
    from pudu.observation p
    cross join lateral (
        select count(*) filter (where s.code = 'perro') as dogs,
               count(*) filter (where s.code = 'puma')  as pumas
        from pudu.observation d
        join pudu.species s on s.id = d.species_id
        where s.code in ('perro', 'puma')
          and st_dwithin(d.geom::geography, p.geom::geography, p_radius_m)
          and (p_window_years is null or d.observation_date is null or p.observation_date is null
               or abs(d.observation_date - p.observation_date) <= p_window_years * 365)
          and (p_max_uncertainty_m is null or d.uncertainty_m is null or d.uncertainty_m <= p_max_uncertainty_m)
    ) animal_c
    cross join lateral (
        select count(*) as n
        from pudu.road r
        where st_dwithin(r.geom::geography, p.geom::geography, p_radius_m)
    ) road_c
    cross join lateral (
        select count(*) as n
        from pudu.toponym t
        where pudu.settlement_buffer_m(t.topo_class) is not null
          and st_dwithin(t.geom::geography, p.geom::geography, p_radius_m)
    ) settlement_c
    where p.species_id = (select s.id from pudu.species s where s.code = 'pudu')
      and (p_max_uncertainty_m is null or p.uncertainty_m is null or p.uncertainty_m <= p_max_uncertainty_m)
$$;

-- Buffers de asentamientos con radio general y radio para estancias. El cálculo métrico va en UTM 18S.
create or replace function pudu.settlement_buffers(
    p_buffer_m double precision default 1000, p_estancia_buffer_m double precision default 500)
returns table (toponym_id integer, topo_class text, geom geometry)
language sql stable as $$
    select t.id, t.topo_class,
           st_transform(st_buffer(st_transform(t.geom, pudu.utm_srid(t.geom)), b.radius_m), 4326)
    from pudu.toponym t
    cross join lateral (
        select pudu.settlement_buffer_m(t.topo_class, p_buffer_m, p_estancia_buffer_m) as radius_m) b
    where b.radius_m is not null
$$;
