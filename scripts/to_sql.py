import hashlib
import re
import unicodedata
from datetime import date, datetime, timezone
from pathlib import Path

import geopandas as gpd
import pandas as pd
import shapely

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
OUTPUT = DATA / "sql"
BATCH = 500

BCN_LAYERS = {
    "municipalities": {
        "municipality_code": ["cod_comuna", "cut_com", "cut", "codigo_com"],
        "name":              ["comuna", "nom_comuna", "nombre"],
        "province":          ["provincia", "nom_prov", "nom_provin"],
        "region_code":       ["codregion", "cod_region", "cut_reg", "cod_regi"],
        "region_name":       ["region", "nom_region", "nom_reg"],
    },
    "roads": {
        "name":         ["nombre", "nombre_cam", "nom_ruta", "name"],
        "mop_code":     ["rol", "rol_label", "rol_mop", "cod_ruta"],
        "category":     ["catego", "categoria", "clase", "jerarquia", "tipo"],
        "route_class":  ["clase_ruta", "clase_urba", "clasificac"],
        "surface_type": ["carpeta", "tipo_carpe", "tipo_carpeta", "superficie"],
    },
    "snaspe":       {"name":                ["nombre", "nom_snaspe", "nombre_tot"],
                     "protected_area_type": ["tipo", "categoria", "tipo_snasp", "clase"]},
    "water_bodies": {"name":      ["nombre", "name"],
                     "body_type": ["tipo", "clase", "categoria"]},
    "urban_areas":  {"locality": ["localidad", "nombre", "nom_loc"],
                     "entity":   ["entidad", "tipo", "categoria"]},
    "toponyms":     {"name":       ["nombre", "toponimo"],
                     "topo_class": ["clase_topo", "clase"],
                     "fc_code":    ["fc", "codigo_fc", "cod_fc"]},
}
REQUIRED_BCN = {"municipalities": ["municipality_code", "name"]}
INTEGER_COLUMNS = {"municipality_code", "region_code"}

OBSERVATION_FIELDS = {
    "source_record_id": ["gbifid", "occurrenceid", "id", "id_registro", "registro", "catalognumber", "enlace_observacion"],
    "lat":              ["decimallatitude", "latitud", "latitude", "lat"],
    "lon":              ["decimallongitude", "longitud", "longitude", "lon", "long"],
    "date_text":        ["eventdate", "fecha", "fecha_de_observacion", "fecha_observacion", "date"],
    "year":             ["year", "anio", "ano"],
    "uncertainty_m":    ["coordinateuncertaintyinmeters", "incertidumbre_m", "incertidumbre"],
    "locality":         ["locality", "localidad", "sitio", "site"],
    "record_type":      ["basisofrecord", "tipo_registro", "metodo", "base_del_registro"],
    "gbif_link":        ["enlace_obs_fuente_datos"],
}
OBSERVATION_COLUMNS = {
    "row_id": "bigint", "source": "text", "species": "text", "file": "text",
    "source_record_id": "text", "lat": "double precision", "lon": "double precision",
    "date_text": "text", "uncertainty_m": "double precision", "locality": "text",
    "record_type": "text", "observation_date": "date", "date_precision": "text",
    "source_loaded_at": "timestamptz", "load_batch": "text", "gbif_id": "text",
}
SOURCES = {"gbif", "simbio", "dryad"}
SPECIES = {"pudu", "puma", "perro"}

def sql_value(v):
    if v is None or (not isinstance(v, str) and pd.isna(v)):
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int) or (hasattr(v, "dtype") and v.dtype.kind in "iu"):
        return str(int(v))
    if isinstance(v, float) or (hasattr(v, "dtype") and v.dtype.kind == "f"):
        return repr(float(v))
    if isinstance(v, (pd.Timestamp, date)):
        return f"'{v:%Y-%m-%d}'"
    return "'" + str(v).replace("'", "''") + "'"


def write_sql(table, columns, df, origin):
    path = OUTPUT / f"{table}.sql"
    names = ", ".join(columns)
    with open(path, "w", encoding="utf-8") as f:
        f.write("set client_encoding = 'UTF8';\n")
        f.write(f"drop table if exists staging.{table};\n")
        f.write(f"create table staging.{table} (\n    ")
        f.write(",\n    ".join(f"{c} {t}" for c, t in columns.items()))
        f.write("\n);\n")
        rows = df[list(columns)].itertuples(index=False, name=None)
        batch = []
        for row in rows:
            batch.append("(" + ", ".join(sql_value(v) for v in row) + ")")
            if len(batch) == BATCH:
                f.write(f"insert into staging.{table} ({names}) values\n" + ",\n".join(batch) + ";\n")
                batch = []
        if batch:
            f.write(f"insert into staging.{table} ({names}) values\n" + ",\n".join(batch) + ";\n")
    print(f"  → {path.relative_to(ROOT)} ({len(df):,} rows, {path.stat().st_size / 1e6:.1f} MB)")


def normalize(name):
    s = unicodedata.normalize("NFKD", str(name)).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")


def pick_columns(df, mapping, required, label):
    available = {normalize(c): c for c in df.columns}
    result, missing = {}, []
    for target, candidates in mapping.items():
        origin = next((available[normalize(c)] for c in candidates
                       if normalize(c) in available), None)
        if origin is None:
            if target in required:
                raise SystemExit(f"{label}: no column for '{target}'. "
                                 f"File columns: {list(df.columns)}\n"
                                 "→ add the right name in scripts/to_sql.py")
            missing.append(target)
            result[target] = pd.Series(pd.NA, index=df.index, dtype="string")
        else:
            result[target] = df[origin].astype("string").str.strip()
    if missing:
        print(f"  {label}: left empty {missing} (file columns: {list(df.columns)})")
    return result

def read_shapefiles(layer):
    folder = DATA / "bcn" / layer
    files = sorted([*folder.rglob("*.shp"), *folder.rglob("*.geojson")])
    if not files:
        raise SystemExit(f"No .shp or .geojson in {folder}. Run first: python scripts/download.py bcn")
    parts = []
    for shp in files:
        gdf = gpd.read_file(shp)
        if gdf.crs is None:
            raise SystemExit(f"{shp.name} has no reference system (the .prj is missing)")
        parts.append(gdf.to_crs(4326))  # everything ends up in WGS 84
    return gpd.GeoDataFrame(pd.concat(parts, ignore_index=True), crs=4326), files


def bcn_to_sql():
    for layer, mapping in BCN_LAYERS.items():
        gdf, files = read_shapefiles(layer)
        gdf = gdf[gdf.geometry.notna() & ~gdf.geometry.is_empty]
        data = pick_columns(gdf, mapping, REQUIRED_BCN.get(layer, []), f"BCN/{layer}")
        if layer == "municipalities":
            data["municipality_code"] = pd.to_numeric(data["municipality_code"], errors="coerce").astype("Int64")
            region = pd.to_numeric(data["region_code"], errors="coerce").astype("Int64")
            data["region_code"] = region.fillna(data["municipality_code"] // 1000)
        table = pd.DataFrame(data)
        table["geom"] = shapely.to_wkb(shapely.set_srid(gdf.geometry.values, 4326),
                                       hex=True, include_srid=True)
        columns = {c: ("integer" if c in INTEGER_COLUMNS else "text") for c in mapping}
        columns["geom"] = "geometry(geometry, 4326)"
        write_sql(layer, columns, table, ", ".join(f.name for f in files))


def read_table(path):
    if path.suffix.lower() in (".xlsx", ".xls"):
        return pd.read_excel(path, dtype=str)
    for encoding in ("utf-8-sig", "latin-1"):
        try:
            first_line = path.open(encoding=encoding).readline()
            break
        except UnicodeDecodeError:
            continue
    if "\t" in first_line:
        return pd.read_csv(path, sep="\t", dtype=str, encoding=encoding,
                           quoting=3, on_bad_lines="warn")
    separator = ";" if first_line.count(";") > first_line.count(",") else ","
    return pd.read_csv(path, sep=separator, dtype=str, encoding=encoding, on_bad_lines="warn")


def to_number(series):
    return pd.to_numeric(series.str.replace(",", ".", regex=False), errors="coerce")


def standardize_dates(text, year):
    text = text.fillna("")
    parsed_date = pd.Series(pd.NaT, index=text.index, dtype="datetime64[ns]")
    precision = pd.Series(pd.NA, index=text.index, dtype="string")
    rules = [
        (r"^(\d{4}-\d{2}-\d{2})",      "%Y-%m-%d", "día"),
        (r"^(\d{1,2}/\d{1,2}/\d{4})",  "%d/%m/%Y", "día"),
        (r"^(\d{1,2}-\d{1,2}-\d{4})",  "%d-%m-%Y", "día"),
        (r"^(\d{4}-\d{2})(?:$|/)",     "%Y-%m",    "mes"),
        (r"^(\d{4})(?:$|/)",           "%Y",       "año"),
    ]
    for pattern, fmt, prec in rules:
        pending = parsed_date.isna()
        value = text[pending].str.extract(pattern)[0]
        parsed = pd.to_datetime(value, format=fmt, errors="coerce").dropna()
        parsed_date[parsed.index] = parsed
        precision[parsed.index] = prec
    year_only = pd.to_datetime(year.where(parsed_date.isna()).str.extract(r"^(\d{4})")[0],
                               format="%Y", errors="coerce").dropna()
    parsed_date[year_only.index] = year_only
    precision[year_only.index] = "año"
    return parsed_date, precision


def observations_to_sql():
    folder = DATA / "observations"
    files = sorted(p for p in folder.glob("*")
                   if p.suffix.lower() in (".csv", ".txt", ".tsv", ".xlsx", ".xls"))
    if not files:
        raise SystemExit(f"No files in {folder}. Run first: python scripts/download.py gbif")
    batch = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    tables, used = [], []
    for path in files:
        parts = path.stem.lower().split("_")
        source, species = parts[0], (parts[1] if len(parts) > 1 else "")
        if source not in SOURCES or species not in SPECIES:
            print(f"  skipping {path.name}: the name must be <source>_<species>, e.g. simbio_pudu.csv")
            continue
        df = read_table(path)
        if source == "dryad":
            detection = to_number(df["detection"])
            country = df["country"].str.replace('"', "", regex=False).str.strip().str.lower()
            df = df[(detection > 0) & (country == "chile")]
        c = pick_columns(df, OBSERVATION_FIELDS, ["lat", "lon"], path.name)
        t = pd.DataFrame({
            "source": source, "species": species, "file": path.name,
            "source_record_id": c["source_record_id"],
            "lat": to_number(c["lat"]), "lon": to_number(c["lon"]),
            "date_text": c["date_text"],
            "uncertainty_m": to_number(c["uncertainty_m"]),
            "locality": c["locality"], "record_type": c["record_type"],
            "source_loaded_at": datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat(),
            "load_batch": batch,
            "gbif_id": c["gbif_link"].str.extract(r"/occurrence/(\d+)", expand=False),
        })
        t["observation_date"], t["date_precision"] = standardize_dates(t["date_text"], c["year"])
        no_id = t["source_record_id"].isna() | (t["source_record_id"] == "")
        fingerprint = (t["species"] + "|" + c["lat"].fillna("") + "|" + c["lon"].fillna("") + "|"
                       + t["date_text"].fillna("")).map(lambda s: hashlib.md5(s.encode()).hexdigest())
        t.loc[no_id, "source_record_id"] = fingerprint[no_id]
        tables.append(t)
        used.append(path.name)
        print(f"  {path.name}: {len(t):,} rows")
    everything = pd.concat(tables, ignore_index=True)
    everything["row_id"] = everything.index
    write_sql("raw_observation", OBSERVATION_COLUMNS, everything, ", ".join(used))


if __name__ == "__main__":
    OUTPUT.mkdir(parents=True, exist_ok=True)
    bcn_to_sql()
    observations_to_sql()
