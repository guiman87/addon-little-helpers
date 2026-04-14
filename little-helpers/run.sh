#!/usr/bin/env bash
set -e

export HOME=/root

source /usr/lib/bashio/bashio.sh

# ── Read addon options ────────────────────────────────────────────────────────
# Use || true for optional fields — bashio::config exits 1 for empty values
ANTHROPIC_API_KEY=$(bashio::config 'anthropic_api_key' || true)
GITHUB_TOKEN=$(bashio::config 'github_token' || true)
JIRA_EMAIL=$(bashio::config 'jira_email' || true)
JIRA_API_TOKEN=$(bashio::config 'jira_api_token' || true)
VAULT_REPO=$(bashio::config 'vault_repo' || true)
VAULT_BRANCH=$(bashio::config 'vault_branch' || true)
SYNC_INTERVAL=$(bashio::config 'sync_interval_minutes' || true)
GWS_SECRET=$(bashio::config 'gws_client_secret_json' || true)
NOTIFICATION_SERVICE=$(bashio::config 'notification_service' || true)
NOTIFICATION_SERVICE="${NOTIFICATION_SERVICE:-notify}"
CLAUDE_AUTH_JSON=$(bashio::config 'claude_auth_json' || true)

VAULT_DIR="/config/little-helpers"

# ── Persist Claude config across restarts ─────────────────────────────────────
# /root/.claude/ and /root/.claude.json are both wiped on container restart.
# Symlink both to /config/ so first-run setup, MCP credentials, and settings
# survive reboots.
mkdir -p /config/claude-config

# Persist the .claude/ directory
ln -sfn /config/claude-config /root/.claude

# Persist the .claude.json config file (sibling of .claude/, NOT inside it)
CLAUDE_JSON_PERSIST="/config/claude-config/.claude.json"
if [ ! -s "${CLAUDE_JSON_PERSIST}" ]; then
    # No persisted config yet — check if a backup was left from a previous run
    latest_backup=$(ls -t /config/claude-config/backups/.claude.json.backup.* 2>/dev/null | head -1 || true)
    if [ -n "${latest_backup}" ]; then
        bashio::log.info "Restoring .claude.json from backup: ${latest_backup}"
        cp "${latest_backup}" "${CLAUDE_JSON_PERSIST}"
    else
        touch "${CLAUDE_JSON_PERSIST}"
    fi
fi
ln -sfn "${CLAUDE_JSON_PERSIST}" /root/.claude.json

# ── Inject claude.ai auth credentials if provided ────────────────────────────
# Writes the .claude.json from addon config on every start so the session
# stays fresh. Only overwrites if the config field is non-empty.
if ! bashio::var.is_empty "${CLAUDE_AUTH_JSON}"; then
    bashio::log.info "Writing claude.ai auth credentials..."
    printf '%s\n' "${CLAUDE_AUTH_JSON}" > "${CLAUDE_JSON_PERSIST}"
    chmod 600 "${CLAUDE_JSON_PERSIST}"
fi

# ── Validate required secrets ─────────────────────────────────────────────────
if bashio::var.is_empty "${ANTHROPIC_API_KEY}"; then
    bashio::log.fatal "anthropic_api_key is required. Set it in the addon Configuration tab."
    exit 1
fi

# ── Configure git for HTTPS push ──────────────────────────────────────────────
git config --global user.email "guillermo.dutra@globe.com"
git config --global user.name "Claude HA Addon"
git config --global credential.helper store
printf 'https://guiman87:%s@github.com\n' "${GITHUB_TOKEN}" > /root/.git-credentials
chmod 600 /root/.git-credentials

# ── Clone or update vault ─────────────────────────────────────────────────────
if [ -d "${VAULT_DIR}/.git" ]; then
    bashio::log.info "Vault exists at ${VAULT_DIR} — pulling latest..."
    git -C "${VAULT_DIR}" fetch origin
    git -C "${VAULT_DIR}" reset --hard "origin/${VAULT_BRANCH}"
else
    bashio::log.info "Cloning vault from ${VAULT_REPO}..."
    git clone --branch "${VAULT_BRANCH}" "${VAULT_REPO}" "${VAULT_DIR}"
fi

# Normalize remote to HTTPS (vault remote may be SSH)
git -C "${VAULT_DIR}" remote set-url origin "https://github.com/guiman87/little-helpers.git"

# ── Write gws client_secret if provided ──────────────────────────────────────
if ! bashio::var.is_empty "${GWS_SECRET}"; then
    bashio::log.info "Writing gws client_secret.json..."
    printf '%s\n' "${GWS_SECRET}" > "${VAULT_DIR}/.gws/client_secret.json"
    chmod 600 "${VAULT_DIR}/.gws/client_secret.json"
fi

# ── Authenticate gh CLI ───────────────────────────────────────────────────────
if ! bashio::var.is_empty "${GITHUB_TOKEN}"; then
    printf '%s\n' "${GITHUB_TOKEN}" | gh auth login --with-token 2>/dev/null || \
        bashio::log.warning "gh CLI auth failed — GitHub PRs may not work"
fi

# ── Start background git sync ─────────────────────────────────────────────────
SYNC_INTERVAL_SECS=$(( SYNC_INTERVAL * 60 ))
bashio::log.info "Background sync every ${SYNC_INTERVAL} min (${SYNC_INTERVAL_SECS}s)"
/sync.sh "${VAULT_DIR}" "${VAULT_BRANCH}" "${SYNC_INTERVAL_SECS}" &

# ── Start Claude Code in remote control mode (restart loop) ───────────────────
export ANTHROPIC_API_KEY
export GITHUB_TOKEN
export GH_TOKEN="${GITHUB_TOKEN}"
export JIRA_EMAIL
export JIRA_API_TOKEN
export GWS_BASE="${VAULT_DIR}/.gws"

cd "${VAULT_DIR}"

while true; do
    RC_LOG=$(mktemp /tmp/claude-rcXXXXXX)
    bashio::log.info "Starting claude remote-control..."

    claude remote-control \
        --name "Little Helpers $(date '+%Y-%m-%d')" \
        > "${RC_LOG}" 2>&1 &
    RC_PID=$!

    # Stream output to HA log in background
    tail -f "${RC_LOG}" >&2 &
    TAIL_PID=$!

    # Poll up to 60s for the session URL
    RC_URL=""
    for i in $(seq 1 60); do
        sleep 1
        if ! kill -0 "${RC_PID}" 2>/dev/null; then
            bashio::log.warning "claude remote-control exited during startup"
            break
        fi
        RC_URL=$(grep -oE 'https://claude\.ai/code[^[:space:]"]*' "${RC_LOG}" | head -1 || true)
        if [ -n "${RC_URL}" ]; then
            break
        fi
    done

    if [ -n "${RC_URL}" ]; then
        bashio::log.info "Remote control session URL: ${RC_URL}"
        # Send HA notification via supervisor API
        curl -s -X POST \
            -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            -H "Content-Type: application/json" \
            "http://supervisor/core/api/services/notify/${NOTIFICATION_SERVICE}" \
            -d "{\"title\": \"Claude Code ready\", \"message\": \"${RC_URL}\"}" \
            && bashio::log.info "Notification sent via ${NOTIFICATION_SERVICE}" \
            || bashio::log.warning "HA notification failed (check notification_service config)"
    else
        bashio::log.warning "No remote control URL found within 60s"
    fi

    # Wait for the process to exit
    wait "${RC_PID}" || true
    kill "${TAIL_PID}" 2>/dev/null || true
    rm -f "${RC_LOG}"

    bashio::log.info "claude remote-control exited — restarting in 10s..."
    sleep 10
done
