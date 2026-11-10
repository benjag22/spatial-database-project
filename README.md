# Proyecto de bases de datos espaciales

## Ejecución

```bash
docker compose up -d                 # 1. levanta PostGIS
pip install -r requirements.txt      # 2. dependencias de Python
python scripts/download.py           # 3. GBIF + BCN a data/ (unos minutos)
python scripts/to_sql.py             # 4. genera data/sql/*.sql
docker compose run --rm load         # 5. carga todo y muestra cuántas observaciones se aceptaron
docker compose run --rm queries      # 6. consultas
```

## Operación

```bash
docker compose run --rm reload       # recarga incremental de observaciones (tras python scripts/to_sql.py), refresca vistas y muestra pudu.load_log
docker compose run --rm maintenance  # pg_dump a backups/ y VACUUM ANALYZE (programable con scripts/crontab.example)
docker compose run --rm explain      # EXPLAIN ANALYZE de las consultas principales
docker compose run --rm crud_demo    # demo de CRUD con integridad (se revierte)

python scripts/export.py observations --species pudu --from 2015-01-01 --to 2025-12-31 --region 10 --format csv
python scripts/export.py layer risk_zone --format geojson   # risk_zone, safe_zone, settlement_buffer, water_mask, pudu_risk
```

Los archivos exportados quedan en `exports/`.
