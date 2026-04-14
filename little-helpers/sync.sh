#!/usr/bin/env bash
# Background git sync loop for the HA addon.
# Strategy: commit local → pull (merge, not rebase) → push.
# Markdown conflicts are resolved automatically via .gitattributes (union merge).
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

    # ── Step 1: commit any local changes ──────────────────────────────────────
    if [ -n "$(git status --porcelain)" ]; then
        git add -A
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
        git commit -m "sync: auto-commit from HA addon at ${TIMESTAMP}" \
            --author="Claude HA Addon <claude-ha@localhost>" 2>/dev/null \
            && bashio::log.info "Sync: committed local changes" \
            || { bashio::log.warning "Sync: commit failed, skipping cycle"; continue; }
    fi

    # ── Step 2: pull remote changes (merge, not rebase) ───────────────────────
    # .gitattributes sets *.md merge=union so markdown conflicts auto-resolve.
    if ! git pull --no-rebase origin "${BRANCH}" 2>/dev/null; then
        bashio::log.warning "Sync: pull/merge failed — aborting and will retry next cycle"
        git merge --abort 2>/dev/null || true
        continue
    fi

    # ── Step 3: push ──────────────────────────────────────────────────────────
    git push origin "${BRANCH}" 2>/dev/null \
        && bashio::log.info "Sync: pushed to ${BRANCH}" \
        || bashio::log.warning "Sync: push failed (check github_token)"
done
