# addon-little-helpers

Home Assistant custom addon repository for Guille's life wiki.

## Addons

### Claude Terminal

A web terminal (powered by [ttyd](https://github.com/tsl0922/ttyd)) that runs
[Claude Code](https://github.com/anthropics/claude-code) inside the
`little_helpers` life wiki vault. Access it from any device via the Home
Assistant UI sidebar.

**Features:**
- Full Claude Code REPL in the browser (works on mobile Safari/Chrome)
- Vault auto-cloned from GitHub on startup
- Background git sync every N minutes — changes pushed back automatically
- Integrations: Jira MCP, GitHub CLI (`gh`), Google Workspace CLI (`gws`)
- Authentication via HA session cookies (ingress) — no extra passwords

## Installation

1. In Home Assistant: **Settings → Add-ons → Add-on Store → ⋮ → Repositories**
2. Add: `https://github.com/guiman87/addon-little-helpers`
3. Refresh — "Claude Terminal" appears in the store
4. Install → Configure → Start

## Configuration

| Option | Type | Description |
|---|---|---|
| `anthropic_api_key` | password | **Required.** From [console.anthropic.com](https://console.anthropic.com) → API keys |
| `github_token` | password | PAT with `repo` scope — for git push and `gh` CLI |
| `jira_email` | str | Your Atlassian email |
| `jira_api_token` | password | From [id.atlassian.com](https://id.atlassian.com) → Security → API tokens |
| `vault_repo` | str | HTTPS URL of the vault repo (default: `little-helpers.git`) |
| `vault_branch` | str | Branch to track (default: `main`) |
| `sync_interval_minutes` | int | How often to commit+push (default: `15`) |
| `gws_client_secret_json` | password | Google OAuth client secret JSON (paste full content) |

## First-run manual steps (inside the terminal)

**Jira MCP re-auth:** On first use of `/daily` or any Jira command, Claude will
prompt for OAuth re-authorization. Open the URL shown in your browser, authorize,
and the token is saved to the persistent `/config/` volume.

**Google Workspace OAuth:** Run once per account:
```bash
GOOGLE_WORKSPACE_CLI_CONFIG_DIR=/config/little-helpers/.gws/work gws auth login
```
Tokens persist across container restarts (stored in `/config/`, not pushed to git).
