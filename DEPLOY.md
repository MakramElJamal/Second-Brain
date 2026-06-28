# Deploying the web/remote server

This exposes your local vault to web AI clients over an **outbound** tunnel. Your
files never leave your machine; the model only receives the slices it requests.
Read [SECURITY.md](SECURITY.md) first.

## Choose a path
- **Just testing?** Use the quick `trycloudflare` tunnel below — zero accounts,
  but the URL rotates and dies on restart.
- **Durable (permanent URL, survives reboot)?** Pick one and follow its guide:
  - [docs/deploy-cloudflare.md](docs/deploy-cloudflare.md) — your own custom
    domain on Cloudflare (named tunnel installed as a service).
  - [docs/deploy-tailscale.md](docs/deploy-tailscale.md) — free `*.ts.net` URL,
    no domain needed.

  Both durable paths use `scripts\install-server-task.ps1` to auto-start the
  server at log on (restart on crash) and disable sleep on AC power. The server
  stays on your machine; when it's off/asleep, clients cleanly error and you
  retry — no data loss.

---

## Quick test (ephemeral)

## 0. One-time setup

```powershell
cd second-brain-web-mcp
.\scripts\setup.ps1     # creates the venv, installs the server, writes .env with fresh secrets
```

(Manual alternative: `python -m venv .venv`, `.\.venv\Scripts\python.exe -m pip
install -e .`, `copy .env.example .env`, then fill `VAULT_MCP_TOKEN` /
`VAULT_OAUTH_PASSWORD` from `python -c "import secrets;print(secrets.token_hex(32))"`.)

Install `cloudflared` (the tunnel client), e.g. `winget install Cloudflare.cloudflared`.

## 1. Start the server (loopback only)

```powershell
.\run.ps1
```

It binds `127.0.0.1:8531`, hardens the secrets-dir ACL, and fails closed if the
secrets are missing. Leave it running.

## 2. Open a quick tunnel (ephemeral HTTPS URL — for testing)

In a second terminal:

```powershell
cloudflared tunnel --url http://127.0.0.1:8531
```

It prints a URL like `https://random-words.trycloudflare.com`. **This URL
rotates each run** — fine for testing; use a named tunnel + a domain for a
stable deployment.

## 3. Pin the public URL, then restart

In `.env`, set both to the tunnel origin (no trailing path), then re-run `run.ps1`:

```
VAULT_MCP_PUBLIC_URL=https://random-words.trycloudflare.com
VAULT_MCP_ALLOWED_HOSTS=random-words.trycloudflare.com
```

Sanity check from anywhere:
```
curl https://random-words.trycloudflare.com/health
```

## 4. Register the connector

The OAuth login gate uses `VAULT_OAUTH_USERNAME` / `VAULT_OAUTH_PASSWORD` from
your `.env`.

### Claude.ai (paid plan required)
Settings → **Connectors** → **Add custom connector** → paste the tunnel URL →
follow the OAuth prompt → log in at the gate → approve. Then ask Claude something
from your vault.

### ChatGPT (workspace admin must enable Developer mode)
Settings → **Connectors** → enable **Developer mode** →  **Create** → paste the
tunnel URL → complete OAuth. Developer mode exposes all tools (read + write);
without it, only `search`/`fetch`-style servers are accepted.

## 5. When done testing

Stop `cloudflared` (closes the public URL) and stop `run.ps1`. The ephemeral URL
dies with the tunnel.

---

## Going stable (later)

Replace the quick tunnel with a **named Cloudflare Tunnel** on a hostname in your
Cloudflare account, and put **Cloudflare Access** in front, restricted to your
identity. See `scripts/setup-tunnel.sh` (upstream) and the Cloudflare docs.

## Running under WSL2 / Linux instead

Linux gives real `0600` perms on the secrets file. Trade-off: watching a vault on
`/mnt/c` usually misses Windows-side (Obsidian) edits, so the live re-index won't
pick them up until restart. Set `VAULT_PATH=/mnt/c/Users/you/Documents/My Vault`,
install deps in a Linux venv, and run `second-brain-mcp` the same way.
