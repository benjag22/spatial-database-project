#!/usr/bin/env bash
# RF15: respaldo con pg_dump y VACUUM/ANALYZE. Uso: scripts/maintenance.sh [carpeta_respaldo]
set -euo pipefail
OUT="${1:-backups}"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d_%H%M%S)"
pg_dump -Fc -f "$OUT/pudu_$STAMP.dump" pudu
vacuumdb --analyze --dbname pudu
