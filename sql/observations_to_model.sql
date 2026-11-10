
alter table staging.raw_observation
    add column geom geometry(point, 4326),
    add column municipality_code integer,
    add column rejection_reason text;

update staging.raw_observation set rejection_reason = 'sin coordenadas'
where lat is null or lon is null;

update staging.raw_observation set rejection_reason = 'coordenadas imposibles'
where rejection_reason is null
  and (lat not between -90 and 90 or lon not between -180 and 180 or (lat = 0 and lon = 0));

update staging.raw_observation set rejection_reason = 'fecha futura o anterior a 1900'
where rejection_reason is null
  and (observation_date::date > current_date or observation_date::date < date '1900-01-01');

update staging.raw_observation set geom = st_setsrid(st_makepoint(lon, lat), 4326)
where rejection_reason is null;
create index on staging.raw_observation using gist (geom);
analyze staging.raw_observation;

update staging.raw_observation o set municipality_code = s.municipality_code
from staging.municipality_sub s
where o.geom is not null and st_intersects(s.geom, o.geom);

with nearest as (
    select o.row_id, m.municipality_code,
           st_distance(m.geom::geography, o.geom::geography) as dist_m
    from staging.raw_observation o
    cross join lateral (select municipality_code, geom from staging.municipality_sub
                        order by geom <-> o.geom limit 1) m
    where o.geom is not null and o.municipality_code is null
)
update staging.raw_observation o set municipality_code = nearest.municipality_code
from nearest
where o.row_id = nearest.row_id and nearest.dist_m <= 1000;

update staging.raw_observation set rejection_reason = 'fuera de Chile (a más de 1 km de toda comuna)'
where rejection_reason is null and municipality_code is null;

update staging.raw_observation o set rejection_reason = 'duplicado (mismo id en la fuente)'
from (select row_id, row_number() over (partition by source, species, source_record_id order by row_id) as n
      from staging.raw_observation where rejection_reason is null) d
where o.row_id = d.row_id and d.n > 1;

-- Inserta solo lo nuevo y registra en load_log lo realmente insertado (RF16).
-- Una recarga del mismo archivo deja rows_inserted = 0 y rows_existing = filas aceptadas.
with inserted as (
    insert into pudu.observation
        (species_id, source_id, source_record_id, observation_date, date_precision, uncertainty_m,
         locality, record_type, municipality_code, source_loaded_at, load_batch, geom)
    select sp.id, so.id, s.source_record_id, s.observation_date::date, s.date_precision, s.uncertainty_m,
           s.locality, s.record_type, s.municipality_code, s.source_loaded_at, s.load_batch, s.geom
    from staging.raw_observation s
    join pudu.species sp on sp.code = s.species
    join pudu.source  so on so.code = s.source
    where s.rejection_reason is null
    on conflict (species_id, source_id, source_record_id) do nothing
    returning species_id, source_id, load_batch
)
insert into pudu.load_log (load_batch, source, species, rows_read, rows_rejected, rows_inserted, rows_existing)
select r.load_batch, r.source, r.species, r.n, r.rejected, coalesce(i.n, 0), r.n - r.rejected - coalesce(i.n, 0)
from (select load_batch, source, species, count(*) as n,
             count(*) filter (where rejection_reason is not null) as rejected
      from staging.raw_observation
      group by load_batch, source, species) r
left join (select n.load_batch, so.code as source, sp.code as species, count(*) as n
           from inserted n
           join pudu.source  so on so.id = n.source_id
           join pudu.species sp on sp.id = n.species_id
           group by n.load_batch, so.code, sp.code) i
  on i.load_batch = r.load_batch and i.source = r.source and i.species = r.species;

analyze pudu.observation;
