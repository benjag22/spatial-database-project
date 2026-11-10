-- Demostración de CRUD (RF10). Todo se revierte al final.
begin;

select pudu.add_observation('pudu', 'gbif', -73.05, -36.83, date '2026-01-01', 'día', 50,
                            'prueba CRUD', 'HUMAN_OBSERVATION') as new_id \gset

select id, species, municipality, region, locality from pudu.v_observation where id = :new_id;

select pudu.update_observation(:new_id, p_locality => 'prueba CRUD editada', p_lon => -72.99, p_lat => -36.8) as updated;
select id, municipality, locality from pudu.v_observation where id = :new_id;

select pudu.delete_observation(:new_id) as deleted;

rollback;

-- Observación fuera de Chile, debe ser rechazada
do $$
begin
    perform pudu.add_observation('pudu', 'gbif', -120, -40);
    raise notice 'no fue rechazada';
exception when check_violation then
    raise notice 'rechazada: %', sqlerrm;
end $$;

-- Comuna con registros asociados, debe ser rechazada (integridad referencial)
do $$
begin
    perform pudu.delete_municipality((select municipality_code from pudu.municipality where name = 'Concepción'));
    raise notice 'no fue rechazada';
exception when foreign_key_violation then
    raise notice 'rechazada: %', sqlerrm;
end $$;
