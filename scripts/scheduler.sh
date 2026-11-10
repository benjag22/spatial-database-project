#!/usr/bin/env bash
# RF15: ejecuta maintenance.sh al iniciar y luego cada MAINTENANCE_INTERVAL_HOURS (por defecto 168, una semana).
# Uso: docker compose --profile tools up -d scheduler
set -u
OUT="${1:-/backups}"
HOURS="${MAINTENANCE_INTERVAL_HOURS:-168}"
while true; do
    bash "$(dirname "$0")/maintenance.sh" "$OUT" || echo "maintenance.sh falló, se reintenta en $HOURS h"
    sleep "$((HOURS * 3600))"
done
