import argparse
import csv
import json
import os
from datetime import datetime
from decimal import Decimal
from pathlib import Path

import psycopg
from shapely import wkb
from shapely.geometry import mapping

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "exports"

LAYERS = {
    "risk_zone": "select 'zona a restringir' as name, "
                 "round((st_area(geom::geography) / 1e6)::numeric, 2) as area_km2, "
                 "st_asbinary(geom) as geom from pudu.mv_risk_zone",
    "safe_zone": "select 'zona apta' as name, "
                 "round((st_area(geom::geography) / 1e6)::numeric, 2) as area_km2, "
                 "st_asbinary(geom) as geom from pudu.mv_safe_zone",
    "settlement_buffer": "select toponym_id, topo_class, st_asbinary(geom) as geom "
                         "from pudu.mv_settlement_buffer",
    "water_mask": "select 'cuerpos de agua' as name, "
                  "round((st_area(geom::geography) / 1e6)::numeric, 2) as area_km2, "
                  "st_asbinary(geom) as geom from pudu.mv_water_union",
    "pudu_risk": "select p.id, p.observation_date, k.in_water, k.in_risk_zone, k.in_safe_zone, "
                 "d.dist_m as distance_to_road_m, st_asbinary(p.geom) as geom "
                 "from pudu.mv_pudu_risk k "
                 "join pudu.observation p on p.id = k.id "
                 "left join pudu.mv_pudu_road_distance d on d.id = k.id "
                 "where p.species_id = (select s.id from pudu.species s where s.code = 'pudu') "
                 "order by p.id",
}

OBSERVATION_SQL = """
select o.id, sp.code as species, so.code as source, o.source_record_id, o.observation_date,
       o.date_precision, o.uncertainty_m, o.locality, o.record_type,
       m.name as municipality, r.name as region, o.load_batch, st_asbinary(o.geom) as geom
from pudu.observation o
join pudu.species      sp on sp.id = o.species_id
join pudu.source       so on so.id = o.source_id
join pudu.municipality m  on m.municipality_code = o.municipality_code
join pudu.region       r  on r.region_code = m.region_code
"""


def connect():
    return psycopg.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=os.environ.get("PGPORT", "5435"),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD", "postgres"),
        dbname=os.environ.get("PGDATABASE", "pudu"),
    )


def observation_query(args):
    where, params = [], []
    if args.species:
        where.append("sp.code = any(%s::text[])")
        params.append(args.species)
    if args.source:
        where.append("so.code = any(%s::text[])")
        params.append(args.source)
    if args.date_from:
        where.append("o.observation_date >= %s::date")
        params.append(args.date_from)
    if args.date_to:
        where.append("o.observation_date <= %s::date")
        params.append(args.date_to)
    if args.region:
        where.append("r.region_code = %s::smallint")
        params.append(args.region)
    sql = OBSERVATION_SQL
    if where:
        sql += "where " + "\n  and ".join(where) + "\n"
    return sql + "order by o.id", params


def json_default(value):
    return float(value) if isinstance(value, Decimal) else str(value)


def write_geojson(path, columns, rows):
    gi = columns.index("geom")
    features = []
    for row in rows:
        properties = {c: v for c, v in zip(columns, row) if c != "geom"}
        features.append({"type": "Feature",
                         "geometry": mapping(wkb.loads(bytes(row[gi]))),
                         "properties": properties})
    collection = {"type": "FeatureCollection", "features": features}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(collection, f, ensure_ascii=False, separators=(",", ":"), default=json_default)


def write_csv(path, columns, rows):
    gi = columns.index("geom")
    geoms = [wkb.loads(bytes(row[gi])) for row in rows]
    points = all(g.geom_type == "Point" for g in geoms)
    attributes = [c for c in columns if c != "geom"]
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(attributes + (["lon", "lat"] if points else ["wkt"]))
        for row, g in zip(rows, geoms):
            values = [v for c, v in zip(columns, row) if c != "geom"]
            writer.writerow(values + ([g.x, g.y] if points else [g.wkt]))


def export(name, sql, params, fmt):
    OUTPUT.mkdir(exist_ok=True)
    with connect() as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        columns = [d.name for d in cur.description]
        rows = cur.fetchall()
    path = OUTPUT / f"{name}_{datetime.now():%Y%m%d_%H%M%S}.{'csv' if fmt == 'csv' else 'geojson'}"
    (write_csv if fmt == "csv" else write_geojson)(path, columns, rows)
    print(f"{path.relative_to(ROOT)} ({len(rows):,} rows)")


def main():
    parser = argparse.ArgumentParser(description="Exporta datos filtrados y capas de análisis a CSV o GeoJSON")
    sub = parser.add_subparsers(dest="command", required=True)

    obs = sub.add_parser("observations", help="observaciones filtradas por especie, fechas, región y fuente (RF3)")
    obs.add_argument("--species", nargs="+", choices=["pudu", "puma", "perro"])
    obs.add_argument("--source", nargs="+")
    obs.add_argument("--from", dest="date_from", metavar="YYYY-MM-DD")
    obs.add_argument("--to", dest="date_to", metavar="YYYY-MM-DD")
    obs.add_argument("--region", type=int, help="código de región")
    obs.add_argument("--format", choices=["csv", "geojson"], default="geojson")

    layer = sub.add_parser("layer", help="capas de análisis (vistas materializadas)")
    layer.add_argument("name", choices=sorted(LAYERS))
    layer.add_argument("--format", choices=["csv", "geojson"], default="geojson")

    args = parser.parse_args()
    if args.command == "observations":
        sql, params = observation_query(args)
        export("observations", sql, params, args.format)
    else:
        export(args.name, LAYERS[args.name], None, args.format)


if __name__ == "__main__":
    main()
