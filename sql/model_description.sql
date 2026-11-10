-- Descripción del modelo lógico implementado, leída del catálogo de PostgreSQL (RF14 y RF15).

-- model_tables | Tablas, tipo de geometría y comentario
select c.relname as table_name,
       case c.relkind when 'p' then 'particionada' else 'tabla' end as kind,
       coalesce((select format_type(a.atttypid, a.atttypmod)
                 from pg_attribute a
                 join pg_type t on t.oid = a.atttypid and t.typname = 'geometry'
                 where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                 limit 1), '') as geometry,
       obj_description(c.oid, 'pg_class') as description
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'pudu' and c.relkind in ('r', 'p') and not c.relispartition
order by c.relname;

-- model_columns | Columnas con tipo, obligatoriedad y valor por defecto o expresión generada
select c.relname as table_name, a.attnum as pos, a.attname as column_name,
       format_type(a.atttypid, a.atttypmod) as type,
       case when a.attnotnull then 'no' else 'sí' end as nullable,
       pg_get_expr(d.adbin, d.adrelid) as default_or_generated
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
where n.nspname = 'pudu' and c.relkind in ('r', 'p') and not c.relispartition
order by c.relname, a.attnum;

-- model_constraints | Claves primarias, foráneas, únicas y restricciones CHECK
select c.relname as table_name,
       case k.contype when 'p' then 'PRIMARY KEY' when 'f' then 'FOREIGN KEY'
                      when 'u' then 'UNIQUE' when 'c' then 'CHECK' end as type,
       k.conname as name,
       pg_get_constraintdef(k.oid) as definition
from pg_constraint k
join pg_class c on c.oid = k.conrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'pudu' and not c.relispartition and k.contype in ('p', 'f', 'u', 'c')
order by c.relname, k.contype, k.conname;

-- model_partitions | Particiones de pudu.observation
select pc.relname as partition, pg_get_expr(pc.relpartbound, pc.oid) as bound
from pg_inherits i
join pg_class pc on pc.oid = i.inhrelid
join pg_class parent on parent.oid = i.inhparent
join pg_namespace n on n.oid = parent.relnamespace
where n.nspname = 'pudu' and parent.relname = 'observation'
order by pc.relname;

-- model_indexes | Índices (GiST sobre geometría y geography, B-tree en claves y filtros)
select t.relname as table_name, i.relname as index_name, am.amname as method,
       pg_get_indexdef(i.oid) as definition
from pg_index x
join pg_class i on i.oid = x.indexrelid
join pg_class t on t.oid = x.indrelid
join pg_namespace n on n.oid = t.relnamespace
join pg_am am on am.oid = i.relam
where n.nspname = 'pudu' and not t.relispartition and not i.relispartition
order by t.relname, i.relname;

-- model_views | Vistas y vistas materializadas
select c.relname as name,
       case c.relkind when 'v' then 'vista' else 'vista materializada' end as kind
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'pudu' and c.relkind in ('v', 'm')
order by c.relkind desc, c.relname;

-- model_routines | Funciones y procedimientos
select p.proname as name,
       case p.prokind when 'p' then 'procedimiento' else 'función' end as kind,
       pg_get_function_arguments(p.oid) as arguments
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'pudu'
order by p.prokind desc, p.proname;

-- model_triggers | Disparadores de integridad
select c.relname as table_name, g.tgname as trigger_name, pg_get_triggerdef(g.oid) as definition
from pg_trigger g
join pg_class c on c.oid = g.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'pudu' and not g.tgisinternal and g.tgparentid = 0
order by c.relname, g.tgname;
