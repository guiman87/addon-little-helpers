#!/usr/bin/env bash
set -e

export HOME=/root

source /usr/lib/bashio/bashio.sh

# Trap any error and log the line number so we know exactly what failed
trap 'bashio::log.fatal "run.sh: unexpected error at line ${LINENO} (exit code $?)"' ERR

bashio::log.info "run.sh starting..."

# ── Read addon options ────────────────────────────────────────────────────────
ANTHROPIC_API_KEY=$(bashio::config 'anthropic_api_key')
GITHUB_TOKEN=$(bashio::config 'github_token')
JIRA_EMAIL=$(bashio::config 'jira_email')
JIRA_API_TOKEN=$(bashio::config 'jira_api_token')
VAULT_REPO=$(bashio::config 'vault_repo')
VAULT_BRANCH=$(bashio::config 'vault_branch')
SYNC_INTERVAL=$(bashio::config 'sync_interval_minutes')
GWS_SECRET=$(bashio::config 'gws_client_secret_json')

VAULT_DIR="/config/little-helpers"

# ── Persist Claude config across restarts ─────────────────────────────────────
# /root/.claude/ and /root/.claude.json are both wiped on container restart.
# Symlink both to /config/ so first-run setup, MCP credentials, and settings
# survive reboots.
bashio::log.info "Setting up persistent Claude config at /config/claude-config..."
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

# ── Write per-session shell script ───────────────────────────────────────────
# ttyd runs this for each browser connection. It sets env vars then execs claude.
cat > /usr/local/bin/claude-session.sh << SESSIONEOF
#!/usr/bin/env bash
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
export GITHUB_TOKEN="${GITHUB_TOKEN}"
export GH_TOKEN="${GITHUB_TOKEN}"
export JIRA_EMAIL="${JIRA_EMAIL}"
export JIRA_API_TOKEN="${JIRA_API_TOKEN}"
export GWS_BASE="${VAULT_DIR}/.gws"

cd ${VAULT_DIR}

cat << 'BANNER'
╔══════════════════════════════════════════════════════════╗
║         Claude Code — little_helpers life wiki           ║
║  Vault: /config/little-helpers                           ║
║  Type:  /daily      for today's briefing                 ║
║  Type:  /query <q>  to search the wiki                   ║
║  Type:  /ingest <url|path>  to add a source              ║
╚══════════════════════════════════════════════════════════╝
BANNER

exec claude
SESSIONEOF
chmod 700 /usr/local/bin/claude-session.sh

# ── Start background git sync ─────────────────────────────────────────────────
SYNC_INTERVAL_SECS=$(( SYNC_INTERVAL * 60 ))
bashio::log.info "Background sync every ${SYNC_INTERVAL} min (${SYNC_INTERVAL_SECS}s)"
/sync.sh "${VAULT_DIR}" "${VAULT_BRANCH}" "${SYNC_INTERVAL_SECS}" &

# ── Start ttyd ────────────────────────────────────────────────────────────────
# --interface 0.0.0.0  required for HA ingress to proxy through
# --writable           allow keyboard input (default is read-only)
# --once=false         allow reconnections after disconnect
# --max-clients 3      cap concurrent sessions
bashio::log.info "Starting ttyd on port 8099..."
exec ttyd \
    --port 8099 \
    --interface 0.0.0.0 \
    --writable \
    --max-clients 3 \
    /usr/local/bin/claude-session.sh
