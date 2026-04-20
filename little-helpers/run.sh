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

# ── Export env for interactive terminal use ───────────────────────────────────
# UTF-8 locale — without this Alpine/musl defaults to POSIX and Claude's
# box-drawing characters render as garbage.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export SHELL=/bin/bash   # tmux inherits this; ensures bash (not ash) runs in the session so .bashrc is sourced
# Ensure /usr/local/bin (where rz/sz/ttyd/gh live) is on PATH for tmux shells
export PATH="/usr/local/bin:/usr/local/sbin:${PATH}"
export ANTHROPIC_API_KEY
export GITHUB_TOKEN
export GH_TOKEN="${GITHUB_TOKEN}"
export JIRA_EMAIL
export JIRA_API_TOKEN
export GWS_BASE="${VAULT_DIR}/.gws"

cd "${VAULT_DIR}"

# ── Welcome banner ───────────────────────────────────────────────────────────
# Written to /etc/motd and injected into the pane on every client attach via
# the tmux client-attached hook, so it appears whether the session is new or
# the user is just reopening the browser tab.
cat > /etc/motd <<'MOTD_EOF'

┌─────────────────────────────────────────────────┐
│           Little Helpers  ·  Terminal            │
├─────────────────────────────────────────────────┤
│  claude         →  start Claude Code            │
│  file button    →  upload a file from device    │
│  swipe ↑        →  scroll back through output   │
│  scroll button  →  same, from toolbar           │
│  q / Esc        →  exit scroll mode             │
│  close tab      →  session keeps running        │
└─────────────────────────────────────────────────┘

MOTD_EOF

# ── tmux config for mobile-friendly status + scrollback ──────────────────────
# Mouse off: xterm.js handles touch-scroll natively. With mouse on, tmux hijacks
# touch events and copy-mode never triggers reliably on mobile. Use the toolbar
# "scroll" button to enter tmux copy-mode for deeper history.
cat > /root/.tmux.conf <<'TMUX_EOF'
set -g history-limit 50000
set -g mouse off
setw -g mode-keys vi
set -g status-style 'bg=#1e1e1e,fg=#aaaaaa'
set -g status-left ''
set -g status-right '%H:%M '
set -g status-right-length 20
set -g window-status-current-style 'bg=#444444,fg=#ffffff,bold'
set -g window-status-style 'fg=#888888'
# Inject /etc/motd directly into the pane tty on every browser tab open/reattach.
# #{pane_tty} is expanded by tmux before the shell runs it.
TMUX_EOF

bashio::log.info "Starting web terminal (ttyd) on port 7681..."

# ttyd attaches to (or creates) a persistent tmux session named 'main'.
# Closing the browser tab does not kill the session — Claude keeps running.
# Reopening the terminal reattaches to the same session.
#
# --index serves our mobile-enhanced HTML (built into the image) at /.
# -t options tune xterm.js for readability on phones (font size, theme, etc.).
exec ttyd \
    --port 7681 \
    --base-path "${INGRESS_PATH:-/}" \
    --writable \
    --index /terminal/mobile-index.html \
    -t fontSize=15 \
    -t 'fontFamily=Menlo, "DejaVu Sans Mono", monospace' \
    -t lineHeight=1.2 \
    -t disableLeaveAlert=true \
    -t disableResizeOverlay=true \
    -t cursorStyle=bar \
    -t scrollback=10000 \
    -t 'theme={"background":"#1e1e1e","foreground":"#e6e6e6","cursor":"#ff9900"}' \
    -t enableZmodem=true \
    -t scrollSensitivity=5 \
    tmux -u new-session -A -s main -c "${VAULT_DIR}" /bin/bash
