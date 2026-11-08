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

