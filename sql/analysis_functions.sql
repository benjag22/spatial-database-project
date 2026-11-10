-- RF4 y RF7: consultas y buffers parametrizados por el usuario (radios en metros).
-- Usan ST_DWithin sobre geography con los índices GiST de geography, sin depender de la latitud.

-- Conteo de amenazas por pudú dentro del radio indicado
create or replace function pudu.pudu_threats(p_radius_m double precision default 1000)
returns table (id bigint, observation_date date, dogs bigint, road_segments bigint, settlements bigint)
language sql stable as $$
    select p.id, p.observation_date, dog_c.n, road_c.n, settlement_c.n
    from pudu.observation p
    cross join lateral (
        select count(*) as n
        from pudu.observation d
        where d.species_id = (select s.id from pudu.species s where s.code = 'perro')
          and st_dwithin(d.geom::geography, p.geom::geography, p_radius_m)
    ) dog_c
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
$$;

-- Buffers de asentamientos con radio general y radio para estancias. El cálculo métrico va en UTM 18S.
create or replace function pudu.settlement_buffers(
    p_buffer_m double precision default 1000, p_estancia_buffer_m double precision default 500)
returns table (toponym_id integer, topo_class text, geom geometry)
language sql stable as $$
    select t.id, t.topo_class,
           st_transform(st_buffer(st_transform(t.geom, 32718), b.radius_m), 4326)
    from pudu.toponym t
    cross join lateral (
        select pudu.settlement_buffer_m(t.topo_class, p_buffer_m, p_estancia_buffer_m) as radius_m) b
    where b.radius_m is not null
$$;
