#!/usr/bin/env bash
# Once-a-day background loop. Sleeps until next ${TARGET_HOUR}:00 local
# time, then runs scripts/finance/nightly_ingest.py. Mirrors the sync.sh pattern.
# Output is appended to /tmp/nightly_ingest.log AND echoed to addon stdout
# so it shows up in the HA addon log panel.
#
# Args:
#   $1  vault dir (required, e.g. /config/little-helpers)
#   $2  target hour (optional, default 3 = 03:00 local)

set -e

VAULT_DIR="$1"
TARGET_HOUR="${2:-3}"

if [ -z "${VAULT_DIR}" ]; then
    echo "[nightly_ingest_loop] ERROR: vault dir required as first arg" >&2
    exit 1
fi

source /usr/lib/bashio/bashio.sh

bashio::log.info "Nightly ingest loop started (target hour: ${TARGET_HOUR}:00 local)"

while true; do
    now_epoch=$(date +%s)
    today=$(date +%Y-%m-%d)
    next_epoch=$(date -d "${today} ${TARGET_HOUR}:00:00" +%s)
    if [ "${next_epoch}" -le "${now_epoch}" ]; then
        tomorrow=$(date -d "@$(( now_epoch + 86400 ))" +%Y-%m-%d)
        next_epoch=$(date -d "${tomorrow} ${TARGET_HOUR}:00:00" +%s)
    fi
    sleep_seconds=$(( next_epoch - now_epoch ))
    bashio::log.info "Sleeping ${sleep_seconds}s until $(date -d "@${next_epoch}")"
    sleep "${sleep_seconds}"

    if [ ! -d "${VAULT_DIR}" ]; then
        bashio::log.warning "Vault dir ${VAULT_DIR} not found — skipping this cycle"
        continue
    fi

    bashio::log.info "Running nightly_ingest.py…"
    cd "${VAULT_DIR}" && \
        python3 scripts/finance/nightly_ingest.py 2>&1 | tee -a /tmp/nightly_ingest.log
    bashio::log.info "nightly_ingest.py exited with $?"
done
