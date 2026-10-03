#!/usr/bin/env bash
set -euo pipefail

# Fixed identity and loopback bindings deliberately avoid other development stacks.
cosmos_sync_name=cosmos-sync-emulator
cosmos_sync_image=mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator@sha256:2db1f9e74c506bcf6fc347aa937aea1c00fa756061296a5a9efba530ce86ec02
cosmos_sync_root=$(cd "$(dirname "$0")/.." && pwd)
cosmos_sync_created=false

check_owner() {
  local owner
  owner=$(docker inspect "$cosmos_sync_name" --format '{{index .Config.Labels "com.anaregdesign.cosmos-sync"}}')
  if [[ "$owner" != integration ]]; then
    echo "Refusing to operate on a container not labeled for Cosmos Sync integration." >&2
    exit 1
  fi
}

start() {
  if docker container inspect "$cosmos_sync_name" >/dev/null 2>&1; then
    check_owner
    if [[ $(docker inspect "$cosmos_sync_name" --format '{{.State.Running}}') != true ]]; then
      echo "Existing Cosmos Sync emulator is stopped. Remove it explicitly before starting a new test container." >&2
      exit 1
    fi
  else
    docker run --detach --name "$cosmos_sync_name" \
      --label com.anaregdesign.cosmos-sync=integration \
      --publish 127.0.0.1:8085:8081 --publish 127.0.0.1:8086:8080 \
      "$cosmos_sync_image" --protocol http --enable-explorer false \
      --enable-telemetry false --log-level warn >/dev/null
    cosmos_sync_created=true
  fi
  local deadline=$((SECONDS + 120))
  until curl --fail --silent --max-time 2 http://127.0.0.1:8086/ready >/dev/null; do
    if ((SECONDS >= deadline)); then
      echo "Cosmos Sync emulator did not become ready within 120 seconds." >&2
      exit 1
    fi
    sleep 1
  done
  echo "Cosmos Sync emulator ready at http://127.0.0.1:8085 (local tests only)."
}

stop() {
  if docker container inspect "$cosmos_sync_name" >/dev/null 2>&1; then
    check_owner
    docker rm --force "$cosmos_sync_name" >/dev/null
    echo "Removed only the Cosmos Sync integration emulator."
  fi
}

cleanup_test() {
  if [[ "$cosmos_sync_created" == true ]]; then stop; fi
}

case "${1:-test}" in
  start) start ;;
  stop) stop ;;
  test)
    trap cleanup_test EXIT
    start
    cd "$cosmos_sync_root/bff"
    COSMOS_SYNC_EMULATOR_ENDPOINT=http://127.0.0.1:8085 \
      go test -race -run '^TestCosmosEmulatorIntegration$' -v -count=1
    ;;
  *) echo "Usage: tools/emulator.sh [start|test|stop]" >&2; exit 2 ;;
esac
