# Second Brain MCP

**Give your AI a memory of your own notes.** Second Brain MCP is a private
*context layer* that connects your personal notes (a folder of Obsidian / markdown
files) to Claude and other AI assistants — so the AI can look things up in *your*
knowledge and file new notes for you, instead of starting from scratch every time.
Everything stays **on your own computer**; your notes are never uploaded to anyone.

It's **efficient by design**: instead of stuffing whole files into the AI (slow and
costly), it hands over the *smallest useful slice* — a ranked snippet or a single
section — and only fetches more when asked. New notes follow *your* style (where
things go, how they're tagged), so every assistant files them consistently. Your
notes stay plain markdown on disk — no lock-in, nothing proprietary.

*(For developers: it's a local-first, token-light **MCP server** over your vault —
ranked snippet/section retrieval with progressive disclosure, plus a house-style
write layer. Details below.)*

Built on the hardened [`obsidian-web-mcp`](https://github.com/jimprosser/obsidian-web-mcp)
core (MIT) — OAuth, path-safety, atomic writes — with our token-light retrieval
and opinionated write layer added through its extension seam (the upstream core is
unmodified). See [`NOTICE.md`](NOTICE.md).

---

## ⚠️ Disclaimers — read before you deploy

- **This is a personal project, provided as-is, with no warranty.** Use it at your
  own risk (MIT License). It is **not** an official Anthropic or Obsidian product
  and is not affiliated with either.
- **It exposes a personal knowledge base to an AI, optionally over the internet.**
  Treat it as security-sensitive. Read [`SECURITY.md`](SECURITY.md) before any
  remote deployment.
- **Back up your vault first.** The write tools modify files on disk. Keep your
  vault under version control (git) or a backup before enabling writes. There is
  no hard delete (notes move to `.trash`), but edits are real.
- **Keep a human in the loop for writes, and beware prompt injection.** Note
  content is untrusted text — a malicious note could try to steer the model.
  Review tool calls; be cautious clipping untrusted web content into the vault.
- **Single-user by design.** One shared login + bearer token grants full vault
  access. There is no multi-user/per-client scoping yet.

---

## Install — for everyone (no coding, ~5 minutes)

**You only need a Windows PC. The app installs everything else for you** — you
never open a terminal or type a command.

1. **Download it.** At the top of this page, click the green **`< > Code`** button
   → **Download ZIP**. Open your Downloads, **right-click the ZIP → Extract All**.
2. **Open the folder** and **double-click `Install Second Brain`**.
3. A window opens and walks you through it:
   - **Step 1 — What you need:** if something is missing (like Python), click
     **Install for me** — it installs automatically and the app keeps going.
   - **Step 2 — Choose my notes folder:** pick the folder where your notes live. A
     progress bar shows it working (the first install takes about a minute).
   - **Step 3 — Connect your Second Brain (phone & web):** follow the three little
     steps in the card — **Install** Tailscale (free), **Sign in** (a browser
     opens; there's a "click here" fallback if it doesn't), and **Turn on** your
     web link. Each shows a check once it's done. This gives **Claude on your
     phone** and **claude.ai in a browser** a link to reach your PC (they can't
     see an address that only exists on your machine).
   - **Step 4 — Start.** The server runs quietly in the background (no window to
     babysit).
   - **Step 5 — Add to Claude:** the window shows a **link** and **password** with a
     **Copy** button.
4. **In Claude:** Settings → Connectors → **Add custom connector**, paste the link,
   and sign in with username `obsidian` and that password. Done.

**Always on?** Tick **"Start automatically when I turn on my PC"** in the window
and the server starts by itself every time you log in.

**Updating:** click **Update** at the top of the window — it fetches the latest
version and restarts the app for you.

To turn it off or remove it later, open the same window and click **Stop** or
**Uninstall** (your notes are never touched).

> First run may show **"Windows protected your PC"** — click **More info → Run
> anyway** (that appears only because the file was downloaded).

*Developers / advanced users: the manual PowerShell setup is
[further down](#setup-manual--powershell).*

---

## What the assistant sees: 10 curated tools

| Tool | Kind | What it does |
|---|---|---|
| `search_notes` | read | Ranked snippets + summaries (never full notes). Filters: bucket, tags, dates. |
| `get_note` | read | One note by id; `section=` returns a single heading, `outline=true` just the headings. |
| `related_notes` | read | Hop the wikilink graph: what a note links to + what links back — ids/titles only, no bodies. |
| `vault_map` | read | Cheap overview: buckets, **folder tree** (incl. empty folders), projects, approved tags, recent. Call before writing. |
| `create_note` | write | New note — PARA-placed, templated, tag- and folder-governed, idempotent. |
| `create_folder` | write | New folder in a bucket ("create a project for X"); snaps to near-duplicate existing folders. |
| `edit_note` | write | `append` / `replace_section` / `set_frontmatter` — send only the changed slice. |
| `archive_chat` | write | Distill *this* conversation into a compact, searchable note for cross-LLM memory. |
| `vault_search_frontmatter` | read | Query notes by a frontmatter field (kept from upstream). |
| `vault_move` | write | Move / rename a note **or a whole folder** (e.g. archive a project); indexes refresh automatically. |

The underlying core ships ~20 low-level tools; we prune to this allowlist to save
tokens and steer the model to safe, house-style operations (reversible — see
`ALLOWLIST` in `src/second_brain_ext/extension.py`).

---

## Setup (manual / PowerShell)

> The commands below are **PowerShell on Windows** (the primary supported
> platform). macOS/Linux work too — use a `python3 -m venv` + the equivalents, and
> see the upstream README for `launchd`/systemd. The remote step uses the same
> `cloudflared` / `tailscale` tools cross-platform.

### What you need

- [**Python 3.12+**](https://www.python.org/downloads/) — during install, tick
  *"Add python.exe to PATH"*.
- An **Obsidian vault** (any folder of `.md` files). Don't have one? Any folder
  with a couple of markdown files works.
- *(Remote access only)* either a free [Tailscale](https://tailscale.com/) account
  **or** [`cloudflared`](https://github.com/cloudflare/cloudflared) — set up below.

### Step 1 — Get the code

```powershell
git clone <your-fork-url> second-brain-web-mcp
cd second-brain-web-mcp
```

### Step 2 — One-command setup

```powershell
.\scripts\setup.ps1
```

This creates the virtualenv, installs the server, **generates your two secrets**,
and writes a ready `.env` (locked down to your user) — it only asks for the path
to your vault. It prints a **username (`obsidian`) and password**; save them,
you'll type them once when connecting. (Re-run with `-Force` to regenerate.)

### Step 3 — Choose how to reach it

```powershell
.\scripts\connect.ps1
```

It asks how you want to connect and sets everything up:

| Option | Cost / account | URL | Best for |
|---|---|---|---|
| **1. Local only** | free | `http://127.0.0.1:8531` | Claude Desktop / Claude Code on the same machine |
| **2. Cloudflare quick** | free, no account | rotates each run | quick test of web/mobile access |
| **3. Tailscale Funnel** | free account | stable `https://…ts.net` | the easy permanent web option — **recommended** |

It writes the public URL into `.env` (so the server trusts it) and starts the
tunnel. For **option 1**, skip the tunnel and go straight to Step 4.

> **Own a domain and want a branded permanent URL?** Use a *named* Cloudflare
> Tunnel instead — see [`DEPLOY.md`](DEPLOY.md) and
> [`docs/deploy-cloudflare.md`](docs/deploy-cloudflare.md). The Tailscale path is
> in [`docs/deploy-tailscale.md`](docs/deploy-tailscale.md).

### Step 4 — Start the server

In a **second** terminal (leave the tunnel running in the first):

```powershell
.\run.ps1
```

It binds to `127.0.0.1:8531`, hardens the secrets folder, and **fails closed** if
a secret is missing. Check it's alive: open `http://127.0.0.1:8531/health` →
`{"status": "ok"}`.

### Step 5 — Connect your client

- **Claude (web/desktop/mobile), paid plan:** Settings → **Connectors** → **Add
  custom connector** → paste your URL (from Step 3, or `http://127.0.0.1:8531`
  locally) → complete the browser sign-in with your `obsidian` username + the
  password from Step 2.
- **ChatGPT:** Settings → **Connectors** → enable **Developer mode** → add the
  same URL. Developer mode is required for write tools.

Done. Ask *"what do my notes say about …"* and the assistant will search your
vault.

### Manage / stop / uninstall

```powershell
.\scripts\manage.ps1      # text menu: set up / connect / start / stop / uninstall
.\scripts\stop.ps1        # turn the server off (and an attached Cloudflare tunnel)
.\scripts\uninstall.ps1   # remove the install (your vault is never touched)
```

(Or just use the buttons in the **Install Second Brain** window.)

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| *"Windows protected your PC"* on the `.cmd` | SmartScreen warning on a downloaded file — click **More info → Run anyway** (only if you got it from the official repo). |
| `run.ps1`: *".env not found"* | Run `.\scripts\setup.ps1` first. |
| *"VAULT_MCP_TOKEN … must be set"* | A secret is missing — `.\scripts\setup.ps1 -Force`. |
| `connect.ps1`: *"cloudflared not found"* | `winget install Cloudflare.cloudflared`, then retry. |
| `connect.ps1`: *"tailscale not found"* | Install from [tailscale.com/download](https://tailscale.com/download), run `tailscale up`, retry. |
| Client says *"server not connected"* (remote) | In Cloudflare, turn **OFF** "Block AI Scrapers and Crawlers" for the host — it blocks the LLM's tool calls. |
| ChatGPT can read but not write | Enable **Developer mode** (Settings → Apps → Advanced). |
| Changed code, nothing happened | No live reload — stop and re-run `.\run.ps1`, then reconnect the client. |
| Public URL changed (Cloudflare quick) | Expected — it rotates each run. Use **Tailscale Funnel** for a stable URL. |
| Stopped working after laptop sleep/hibernate | It self-heals within ~1 min of waking (auto-reconnect task). If Claude still errors, open the app and click **Test connection** — it reconnects a stale web link automatically. |

---

## Security

Built to fail closed: a human OAuth login gates every client, each request needs a
bearer token, path-traversal and writes-outside-the-vault are rejected, writes are
atomic, and there is no hard-delete tool. Mutations are audit-logged (the token is
hashed, never stored). Secrets live in a gitignored `.env` / `.secrets/`, never in
the repo. **Full threat model and the deployment hardening checklist:**
[`SECURITY.md`](SECURITY.md).

Found a vulnerability? Please report it **privately** (see `SECURITY.md`), not via
a public issue.

---

## Develop

```powershell
.\.venv\Scripts\python.exe -m pytest tests\ -q             # test suite
.\.venv\Scripts\python.exe -m second_brain_ext.benchmark   # token cost per answer
.\.venv\Scripts\python.exe -m second_brain_ext.eval_search # search accuracy (recall@k, MRR)
```

Our layer lives in `src/second_brain_ext/` (token-light retrieval + the write
subsystem); the upstream secure core in `src/obsidian_vault_mcp/` is unmodified.
Architecture and design notes: [`docs_v1.0.md`](docs_v1.0.md).

---

## Contributing & contact

Issues, fixes, reviews, and ideas are all welcome — open an issue or a PR. If you
want to **collaborate, review, or just reach out**, find me on LinkedIn:

**Makram El Jamal — https://www.linkedin.com/in/makrameljamal**

(For security issues, please use private reporting as described in
[`SECURITY.md`](SECURITY.md) rather than a public issue.)

## Acknowledgements

This project stands on [`obsidian-web-mcp`](https://github.com/jimprosser/obsidian-web-mcp)
by **Jim Prosser** (MIT). The entire hardened server substrate — the Streamable
HTTP transport, OAuth 2.0 + PKCE login gate, bearer auth, path-traversal / atomic-
write safety, audit logging, and the extension seam this project
plugs into — is his work, used unmodified under `src/obsidian_vault_mcp/`. Huge
thanks; please check out and support the upstream project. See [`NOTICE.md`](NOTICE.md).

## License

MIT — see [`LICENSE`](LICENSE). This fork's additions are © 2026 Makram El Jamal;
the bundled upstream code retains its original MIT copyright.
