#!/usr/bin/env bash
# Background git sync loop
# Usage: sync.sh <vault_dir> <branch> <interval_seconds>

export HOME=/root

VAULT_DIR="$1"
BRANCH="$2"
INTERVAL="${3:-900}"

source /usr/lib/bashio/bashio.sh

bashio::log.info "Sync loop started (interval: ${INTERVAL}s, branch: ${BRANCH})"

while true; do
    sleep "${INTERVAL}"

    cd "${VAULT_DIR}" || { bashio::log.warning "Sync: vault dir not found, skipping"; continue; }

    # Pull remote changes first (rebase to avoid merge commits)
    if git fetch origin "${BRANCH}" 2>/dev/null; then
        git rebase "origin/${BRANCH}" 2>/dev/null || {
            bashio::log.warning "Sync: rebase conflict — skipping push this cycle"
            git rebase --abort 2>/dev/null || true
            continue
        }
    else
        bashio::log.warning "Sync: fetch failed (offline?) — will try push anyway"
    fi

    # Stage and commit any local changes made by claude
    if [ -n "$(git status --porcelain)" ]; then
        git add -A
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
        if git commit -m "sync: auto-commit from HA addon at ${TIMESTAMP}" \
            --author="Claude HA Addon <claude-ha@localhost>" 2>/dev/null; then
            git push origin "${BRANCH}" 2>/dev/null && \
                bashio::log.info "Sync: pushed changes to ${BRANCH}" || \
                bashio::log.warning "Sync: push failed (check github_token)"
        fi
    else
        bashio::log.debug "Sync: no changes to commit"
    fi
done
