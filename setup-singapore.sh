#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE_NAME="osm-tile-server:local"
PBF_URL="https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf"
PBF_PATH="$SCRIPT_DIR/mapfiles/malaysia-singapore-brunei-latest.osm.pbf"

log() {
  printf '\n[%s] %s\n' "setup-singapore" "$1"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

ensure_clean_volumes() {
  docker compose down --remove-orphans >/dev/null 2>&1 || true
  docker volume rm osm-data >/dev/null 2>&1 || true
  docker volume rm osm-tiles >/dev/null 2>&1 || true
  docker volume create osm-data >/dev/null
  docker volume create osm-tiles >/dev/null
}

require_command docker
require_command curl

mkdir -p "$SCRIPT_DIR/mapfiles"

if [[ "${FORCE_REIMPORT:-0}" == "1" ]]; then
  log "Removing existing osm-data and osm-tiles volumes"
  ensure_clean_volumes
fi

log "Building the local tile-server image"
docker compose build map

if [[ ! -f "$PBF_PATH" ]]; then
  log "Downloading the latest Malaysia/Singapore/Brunei extract"
  curl -L "$PBF_URL" -o "$PBF_PATH"
else
  log "Using existing extract at $PBF_PATH"
fi

log "Ensuring Docker volumes exist"
docker volume create osm-data >/dev/null
docker volume create osm-tiles >/dev/null

if docker run --rm --entrypoint bash -v osm-data:/data/database/ "$IMAGE_NAME" -lc 'test -f /data/database/planet-import-complete'; then
  log "osm-data already contains an imported database; skipping re-import"
else
  log "Preparing clean volumes for import"
  ensure_clean_volumes

  log "Importing the Singapore-region extract into osm-data"
  docker run --rm \
    -v "$PBF_PATH:/data/region.osm.pbf" \
    -v osm-data:/data/database/ \
    -v osm-tiles:/data/tiles/ \
    "$IMAGE_NAME" \
    import
fi

log "Setup complete. Start the server with: docker compose up -d"
