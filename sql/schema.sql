create extension if not exists postgis;

drop schema if exists pudu cascade;
drop schema if exists staging cascade;
create schema pudu;
create schema staging;

create table pudu.species (
    id              smallint primary key,
    code            text not null unique,
    scientific_name text not null,
    common_name     text not null,
    role            text not null
        check (role in ('especie objetivo', 'depredador natural', 'amenaza antrópica'))
);

insert into pudu.species values
    (1, 'pudu',  'Pudu puda',        'Pudú del sur',    'especie objetivo'),
    (2, 'puma',  'Puma concolor',    'Puma',            'depredador natural'),
    (3, 'perro', 'Canis familiaris', 'Perro doméstico', 'amenaza antrópica');

create table pudu.source (
    id   smallint primary key,
    code text not null unique,
    name text not null,
    url  text
);

insert into pudu.source values
    (1, 'gbif',   'Global Biodiversity Information Facility',      'https://www.gbif.org'),
    (2, 'simbio', 'SIMBIO, Ministerio del Medio Ambiente',         'https://simbio.mma.gob.cl'),
    (3, 'dryad',  'Dryad, datos de cámaras trampa',                'https://doi.org/10.5061/dryad.k6djh9wj8'),
    (4, 'bcn',    'Biblioteca del Congreso Nacional, mapas vectoriales',
                  'https://www.bcn.cl/siit/mapas_vectoriales');

create table pudu.region (
    region_code smallint primary key,
    name        text not null,
    geom        geometry(multipolygon, 4326) not null check (st_isvalid(geom)),
    area_km2    numeric generated always as (round((st_area(geom::geography) / 1e6)::numeric, 2)) stored
);

create table pudu.municipality (
    municipality_code integer primary key,
    name              text not null,
    province          text,
    region_code       smallint not null references pudu.region,
    geom              geometry(multipolygon, 4326) not null check (st_isvalid(geom)),
    area_km2          numeric generated always as (round((st_area(geom::geography) / 1e6)::numeric, 2)) stored,
    perimeter_km      numeric generated always as (round((st_perimeter(geom::geography) / 1e3)::numeric, 2)) stored
);

create table pudu.road (
    road_id      bigserial primary key,
    name         text,
    mop_code     text,
    category     text,
    route_class  text,
    surface_type text,
    region_code  smallint references pudu.region,
    geom         geometry(multilinestring, 4326) not null check (st_isvalid(geom)),
    length_m     numeric generated always as (round(st_length(geom::geography)::numeric, 1)) stored
);

create table pudu.protected_area (
    id                  serial primary key,
    name                text,
    protected_area_type text,
    geom                geometry(multipolygon, 4326) not null check (st_isvalid(geom)),
    area_km2            numeric generated always as (round((st_area(geom::geography) / 1e6)::numeric, 2)) stored,
    perimeter_km        numeric generated always as (round((st_perimeter(geom::geography) / 1e3)::numeric, 2)) stored
);

create table pudu.water_body (
    id           serial primary key,
    name         text,
    body_type    text,
    geom         geometry(multipolygon, 4326) not null check (st_isvalid(geom)),
    area_km2     numeric generated always as (round((st_area(geom::geography) / 1e6)::numeric, 2)) stored,
    perimeter_km numeric generated always as (round((st_perimeter(geom::geography) / 1e3)::numeric, 2)) stored
);

create table pudu.urban_area (
    id                serial primary key,
    locality          text,
    entity            text,
    municipality_code integer references pudu.municipality,
    geom              geometry(multipolygon, 4326) not null check (st_isvalid(geom)),
    area_km2          numeric generated always as (round((st_area(geom::geography) / 1e6)::numeric, 2)) stored,
    perimeter_km      numeric generated always as (round((st_perimeter(geom::geography) / 1e3)::numeric, 2)) stored
);

create table pudu.toponym (
    id                serial primary key,
    name              text,
    topo_class        text,
    fc_code           text,
    municipality_code integer references pudu.municipality,
    geom              geometry(point, 4326) not null
);

create table pudu.observation (
    id                bigserial,
    species_id        smallint not null references pudu.species,
    source_id         smallint not null references pudu.source,
    source_record_id  text not null,
    observation_date  date check (observation_date between date '1900-01-01' and date '2100-01-01'),
    date_precision    text check (date_precision in ('día', 'mes', 'año')),
    uncertainty_m     numeric check (uncertainty_m >= 0),
    locality          text,
    record_type       text,
    municipality_code integer not null references pudu.municipality,
    loaded_at         timestamptz not null default now(),
    source_loaded_at  timestamptz,
    load_batch        text not null default 'manual',
    geom              geometry(point, 4326) not null,
    primary key (id, species_id),
    unique (species_id, source_id, source_record_id)
) partition by list (species_id);

create table pudu.observation_pudu  partition of pudu.observation for values in (1);
create table pudu.observation_puma  partition of pudu.observation for values in (2);
create table pudu.observation_perro partition of pudu.observation for values in (3);
create table pudu.observation_other partition of pudu.observation default;

create table pudu.load_log (
    id            bigserial primary key,
    load_batch    text not null,
    source        text not null,
    species       text not null,
    rows_read     integer not null,
    rows_rejected integer not null,
    rows_inserted integer not null,
    rows_existing integer not null,
    logged_at     timestamptz not null default now()
);

create index region_geom_gix         on pudu.region         using gist (geom);
create index municipality_geom_gix   on pudu.municipality   using gist (geom);
create index road_geom_gix           on pudu.road           using gist (geom);
create index protected_area_geom_gix on pudu.protected_area using gist (geom);
create index water_body_geom_gix     on pudu.water_body     using gist (geom);
create index urban_area_geom_gix     on pudu.urban_area     using gist (geom);
create index toponym_geom_gix        on pudu.toponym        using gist (geom);
create index observation_geom_gix    on pudu.observation    using gist (geom);
create index observation_geog_gix    on pudu.observation    using gist ((geom::geography));
create index road_geog_gix           on pudu.road           using gist ((geom::geography));
create index toponym_geog_gix        on pudu.toponym        using gist ((geom::geography));

create index municipality_region_idx      on pudu.municipality (region_code);
create index toponym_class_idx            on pudu.toponym (topo_class);
create index observation_species_date_idx on pudu.observation (species_id, observation_date);
create index observation_municipality_idx on pudu.observation (municipality_code);

create view pudu.v_observation as
select o.id, sp.code as species, sp.common_name, so.code as source, o.source_record_id,
       o.observation_date, o.date_precision, o.uncertainty_m, o.locality, o.record_type,
       m.name as municipality, r.name as region, o.geom
from pudu.observation o
join pudu.species      sp on sp.id = o.species_id
join pudu.source       so on so.id = o.source_id
join pudu.municipality m  on m.municipality_code = o.municipality_code
join pudu.region       r  on r.region_code = m.region_code;

create view pudu.v_pudu as select * from pudu.v_observation where species = 'pudu';
create view pudu.v_puma as select * from pudu.v_observation where species = 'puma';
create view pudu.v_dog  as select * from pudu.v_observation where species = 'perro';

create view pudu.v_possible_duplicate as
select a.id as id_a, b.id as id_b, a.species_id, a.observation_date,
       round(st_distance(a.geom::geography, b.geom::geography)::numeric, 1) as distance_m
from pudu.observation a
join pudu.observation b
  on a.id < b.id
 and a.species_id = b.species_id
 and a.source_id <> b.source_id
 and a.observation_date = b.observation_date
 and st_dwithin(a.geom::geography, b.geom::geography, 50);
