#!/usr/bin/env bash
# RF15: respaldo con pg_dump, VACUUM/ANALYZE y borrado de respaldos antiguos.
# Uso: scripts/maintenance.sh [carpeta_respaldo]   (KEEP_DAYS, por defecto 30)
set -euo pipefail
OUT="${1:-backups}"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d_%H%M%S)"
pg_dump -Fc -f "$OUT/pudu_$STAMP.dump" pudu
vacuumdb --analyze --dbname pudu
find "$OUT" -name 'pudu_*.dump' -mtime +"${KEEP_DAYS:-30}" -delete
