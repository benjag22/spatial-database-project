
import csv
import io
import sys
import time
import zipfile
from pathlib import Path

import requests

DATA = Path(__file__).resolve().parent.parent / "data"

GBIF_API = "https://api.gbif.org/v1"
SPECIES = {"pudu": "Pudu puda", "puma": "Puma concolor", "perro": "Canis familiaris"}
GBIF_FIELDS = ["gbifID",
               "occurrenceID",
               "scientificName",
               "decimalLatitude",
               "decimalLongitude",
               "coordinateUncertaintyInMeters",
               "eventDate",
               "year",
               "locality",
               "stateProvince",
               "basisOfRecord",
               "datasetKey",
               "institutionCode"]
MAX_PER_SLICE = 9_000

BCN_PAGE = "https://www.bcn.cl/siit/mapas_vectoriales"
BCN_BASE = "https://www.bcn.cl/obtienearchivo?id=repositorio%2F10221%2F"
BCN_LAYERS = {
    "municipalities": BCN_BASE + "10396%2F5%2Fcomunas_final.zip",
    "roads":          BCN_BASE + "10403%2F2%2FRed_Vial.zip",
    "snaspe":         BCN_BASE + "10404%2F2%2FSnaspe.zip",
    "toponyms":       BCN_BASE + "10400%2F2%2FToponimos.zip",
    "water_bodies":   BCN_BASE + "10399%2F2%2FMasas_Lacustres.zip",
    "urban_areas":    BCN_BASE + "10405%2F2%2FAreas_Pobladas.zip",
}


def taxon_key(name):
    r = requests.get(f"{GBIF_API}/species/match", params={"name": name}, timeout=30)
    r.raise_for_status()
    d = r.json()
    key = d.get("acceptedUsageKey") or d.get("usageKey")
    if not key:
        sys.exit(f"GBIF does not recognize '{name}'")
    return key


def search(params):
    for attempt in range(1, 6):
        try:
            r = requests.get(f"{GBIF_API}/occurrence/search", params=params, timeout=60)
            if r.status_code not in (429, 500, 502, 503, 504):
                r.raise_for_status()
                return r.json()
        except (requests.Timeout, requests.ConnectionError):
            pass
        print(f"\nGBIF not responding, retry {attempt}/5")
        time.sleep(10 * attempt)
    sys.exit("GBIF is not responding, try again later")


def latitude_slices(params, lat_min=-90.0, lat_max=90.0):
    count = search({**params, "decimalLatitude": f"{lat_min},{lat_max}", "limit": 0})["count"]
    if count == 0:
        return []
    if count <= MAX_PER_SLICE or lat_max - lat_min < 0.001:
        return [(lat_min, lat_max, count)]
    middle = (lat_min + lat_max) / 2
    return latitude_slices(params, lat_min, middle) + latitude_slices(params, middle, lat_max)


def download_gbif():
    folder = DATA / "observations"
    folder.mkdir(parents=True, exist_ok=True)
    for code, name in SPECIES.items():
        params = {"country": "CL", "taxonKey": taxon_key(name), "hasCoordinate": "true",
                  "hasGeospatialIssue": "false", "occurrenceStatus": "PRESENT"}
        slices = latitude_slices(params)
        total = sum(n for _, _, n in slices)
        rows = {}
        for lat_min, lat_max, _ in slices:
            offset = 0
            while True:
                d = search({**params, "decimalLatitude": f"{lat_min},{lat_max}",
                            "limit": 300, "offset": offset})
                for o in d["results"]:
                    row = {f: o.get(f, "") for f in GBIF_FIELDS}
                    row["gbifID"] = o.get("gbifID") or o.get("key")
                    rows[row["gbifID"]] = row
                offset += len(d["results"])
                print(f"\rgbif_{code}.csv: {len(rows):,} of {total:,}", end="")
                if d["endOfRecords"] or not d["results"]:
                    break
                time.sleep(0.2)
        with open(folder / f"gbif_{code}.csv", "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=GBIF_FIELDS)
            writer.writeheader()
            writer.writerows(rows.values())
        print(f"\rgbif_{code}.csv: {len(rows):,} records          ")


def download_bcn():
    for layer, url in BCN_LAYERS.items():
        target = DATA / "bcn" / layer
        if any(target.rglob("*.shp")):
            continue
        print(f"bcn/{layer}:", end=" ", flush=True)
        r = requests.get(url, timeout=600, headers={"User-Agent": "Mozilla/5.0 (academic project)"})
        r.raise_for_status()
        if not r.content.startswith(b"PK"):
            sys.exit(f"\nBCN did not return a .zip for '{layer}': download it from {BCN_PAGE} into {target}")
        target.mkdir(parents=True, exist_ok=True)
        zipfile.ZipFile(io.BytesIO(r.content)).extractall(target)
        print(f"{len(r.content) / 1e6:.1f} MB")


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what in ("all", "gbif"):
        download_gbif()
    if what in ("all", "bcn"):
        download_bcn()