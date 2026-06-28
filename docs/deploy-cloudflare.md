# Durable deploy — Cloudflare named tunnel (custom domain)

A permanent public URL on **your own domain** (e.g. `https://vault.yourdomain.com`)
that survives reboots, backed by a Cloudflare Tunnel installed as an auto-starting
service. The server stays on your machine (laptop-bound, local-first); the tunnel
is outbound-only, so no inbound ports are opened.

> **Auth note:** Do **not** enable Cloudflare **Access** on this hostname. Access
> uses its own browser login, which AI connectors (Claude/ChatGPT) can't complete
> — it breaks the connector. The server's built-in **OAuth 2.0 + PKCE login gate
> and bearer token** are the authentication wall. Cloudflare here gives you a
> stable hostname + the free encrypted tunnel, nothing more.

## Prerequisites
- A domain you own (any registrar — e.g. Namecheap).
- A free Cloudflare account.
- `cloudflared` installed (`winget install Cloudflare.cloudflared`).
- The server installed and runnable via `run.ps1` (see [../DEPLOY.md](../DEPLOY.md)).

## Step 1 — Add your domain to Cloudflare (browser, one time)
1. Cloudflare dashboard → **Add a site** → enter your domain → choose the **Free** plan.
2. Cloudflare shows two **nameservers** (e.g. `xx.ns.cloudflare.com`).
3. In your registrar (Namecheap → Domain List → **Manage** → *Nameservers* →
   **Custom DNS**), replace the nameservers with Cloudflare's two. Save.
4. Wait for Cloudflare to show the domain **Active** (minutes to a few hours).

## Step 2 — Create the tunnel (CLI — no Zero Trust onboarding needed)
This uses the regular Cloudflare account (avoids the Zero Trust dashboard team
setup, which can ask for a card). Run from any terminal:

```powershell
$cf = "C:\Program Files (x86)\cloudflared\cloudflared.exe"
& $cf tunnel login                                   # browser: authorize your domain
& $cf tunnel create second-brain                     # creates tunnel + creds json
& $cf tunnel route dns second-brain vault.yourdomain.com   # creates the DNS record
```

Then write `C:\Users\<you>\.cloudflared\config.yml` (use the tunnel ID printed by
`create`):

```yaml
tunnel: <TUNNEL-ID>
credentials-file: C:\Users\<you>\.cloudflared\<TUNNEL-ID>.json

ingress:
  - hostname: vault.yourdomain.com
    service: http://127.0.0.1:8531
  - service: http_status:404
```

Run it (foreground to test): `& $cf tunnel run second-brain`. Verify
`https://vault.yourdomain.com/health` once the server is up (Step 4). For
permanent auto-start, Step 4's script registers the tunnel as a task too.

## Step 3 — Pin the public URL in `.env`
So a spoofed Host header can't redirect OAuth discovery:
```
VAULT_MCP_PUBLIC_URL=https://vault.yourdomain.com
VAULT_MCP_ALLOWED_HOSTS=vault.yourdomain.com
```

## Step 4 — Auto-start the server + tunnel + never sleep
Run once **as Administrator** (right-click PowerShell → Run as administrator) from
the repo root:
```powershell
.\scripts\install-server-task.ps1 -CloudflaredTunnel second-brain
```
This registers two Task Scheduler jobs — the server (`run.ps1`) and the tunnel
(`cloudflared tunnel run second-brain`) — that start at log on and restart on
crash, and sets "never sleep while plugged in" so the laptop stays reachable when
the lid is open. (Asleep/off = cleanly unavailable; clients just error and you
retry — no data loss.) Admin is required to register tasks and change power settings.

## Step 5 — Register the connector (once, on the stable URL)
- **Claude.ai:** Settings → Connectors → Add custom connector → `https://vault.yourdomain.com`
  → leave OAuth Client ID/Secret **blank** (dynamic registration) → log in at the gate.
- **ChatGPT:** enable Developer mode → Connectors → Create → same URL → OAuth.

Because the URL never changes now, you only register once.

## Step 6 — Reboot test
Restart the laptop, log in, wait ~1 min, then hit `https://vault.yourdomain.com/health`.
Both the tunnel (service) and the server (task) should come back automatically.

## Optional — uptime alerts
Create a free check at Healthchecks.io and set in `.env`:
```
VAULT_MCP_HEARTBEAT_URL=https://hc-ping.com/your-uuid
```
The server pings it periodically; you get notified if it goes down.

## Does this affect gaming ping?
No. When idle the tunnel only holds a tiny outbound keepalive and carries traffic
only for `vault.yourdomain.com` — your game traffic is untouched and goes direct.
