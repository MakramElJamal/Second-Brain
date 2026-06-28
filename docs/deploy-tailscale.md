# Durable deploy — Tailscale Funnel (no domain needed)

A permanent public URL like `https://<machine>.<tailnet>.ts.net` with **zero
domain cost**, backed by the Tailscale client (which already runs as an
auto-starting service). The server stays on your machine (laptop-bound,
local-first); Funnel exposes only the one port, outbound-only.

> **Auth note:** Funnel is public to the internet. That's fine here — the
> server's built-in **OAuth 2.0 + PKCE login gate and bearer token** are the
> authentication wall, exactly as with the Cloudflare option.

## Prerequisites
- A free Tailscale account (Personal plan is enough).
- The server installed and runnable via `run.ps1` (see [../DEPLOY.md](../DEPLOY.md)).

## Step 1 — Install Tailscale and sign in
1. `winget install tailscale.tailscale` (or download from tailscale.com).
2. Sign in (Google/GitHub/etc.). The Tailscale client installs as a Windows
   service that starts on boot and reconnects automatically.

## Step 2 — Enable HTTPS + Funnel for this node (admin console, one time)
1. Tailscale admin console → **Settings → Features → enable HTTPS certificates**.
2. **Access controls (ACLs):** ensure your node is allowed to use Funnel, e.g.
   add a `nodeAttrs` entry granting `funnel` to your device/tag. (Tailscale will
   prompt/guide you the first time you run `funnel`.)

## Step 3 — Start Funnel to the server port
```powershell
tailscale funnel 8531
```
This prints your permanent public URL, e.g.
`https://laptop.tailnet-name.ts.net`. Funnel config persists across reboots.

(To run in the background and persist explicitly: `tailscale funnel --bg 8531`.
Check status with `tailscale funnel status`.)

## Step 4 — Pin the public URL in `.env`
```
VAULT_MCP_PUBLIC_URL=https://laptop.tailnet-name.ts.net
VAULT_MCP_ALLOWED_HOSTS=laptop.tailnet-name.ts.net
```

## Step 5 — Auto-start the server + never sleep
Run once, as Administrator, from the repo root:
```powershell
.\scripts\install-server-task.ps1
```
Registers a Task Scheduler job (start at log on, restart on crash) and sets
"never sleep while plugged in."

## Step 6 — Register the connector (once, on the stable URL)
- **Claude.ai:** Settings → Connectors → Add custom connector → your `.ts.net` URL
  → leave OAuth Client ID/Secret **blank** → log in at the gate.
- **ChatGPT:** Developer mode → Connectors → Create → same URL → OAuth.

## Step 7 — Reboot test
Restart, log in, wait ~1 min, hit `https://<machine>.<tailnet>.ts.net/health`.
Tailscale (service) + Funnel config and the server (task) come back on their own.

## Notes / trade-offs vs Cloudflare
- **No domain, no cost** — fastest permanent URL.
- The hostname is a `.ts.net` subdomain, not your own brand.
- Funnel supports a fixed set of public ports (443/8443/10000) mapped to your
  local port — `tailscale funnel 8531` handles the mapping for you.

## Gaming ping
No impact. Tailscale does **not** route your normal/game traffic (no exit node
enabled); it only carries tailnet + Funnel traffic for this one service, with a
negligible idle keepalive.
