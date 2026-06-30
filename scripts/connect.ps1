# Choose how to reach the server, then set it up and run it.
#
#   .\scripts\connect.ps1                 # interactive menu
#   .\scripts\connect.ps1 -Mode local
#   .\scripts\connect.ps1 -Mode cloudflare   # free, no account; URL rotates each run
#   .\scripts\connect.ps1 -Mode tailscale    # free account; stable https URL
#
# It writes the public URL into .env (VAULT_MCP_PUBLIC_URL / VAULT_MCP_ALLOWED_HOSTS)
# so the server trusts it, then starts the tunnel. Run .\run.ps1 in a second
# window to start the server itself.
[CmdletBinding()]
param([ValidateSet('local', 'cloudflare', 'tailscale')][string]$Mode)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root ".env"
if (-not (Test-Path $envFile)) { throw "No .env found. Run .\scripts\setup.ps1 first." }

function Get-EnvVal($key) {
    $line = Get-Content $envFile | Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -First 1
    if ($line) { ($line -replace "^\s*$key\s*=\s*", "").Trim() }
}
function Set-EnvVal($key, $val) {
    $found = $false
    $out = Get-Content $envFile | ForEach-Object {
        if ($_ -match "^\s*$key\s*=") { $found = $true; "$key=$val" } else { $_ }
    }
    if (-not $found) { $out += "$key=$val" }
    Set-Content -Path $envFile -Value $out -Encoding utf8
}

$port = (Get-EnvVal "VAULT_MCP_PORT"); if (-not $port) { $port = "8531" }

if (-not $Mode) {
    Write-Host "How do you want to reach the server?"
    Write-Host "  [1] Local only       - same machine only (Claude Desktop / Code)"
    Write-Host "  [2] Cloudflare quick  - FREE, no account; public URL changes each run"
    Write-Host "  [3] Tailscale Funnel  - FREE account; stable https URL, survives restarts"
    $c = Read-Host "Choose 1 / 2 / 3"
    $Mode = @{ "1" = "local"; "2" = "cloudflare"; "3" = "tailscale" }[$c]
    if (-not $Mode) { throw "Please choose 1, 2, or 3." }
}

switch ($Mode) {
    "local" {
        Set-EnvVal "VAULT_MCP_PUBLIC_URL" ""
        Set-EnvVal "VAULT_MCP_ALLOWED_HOSTS" ""
        Write-Host ""
        Write-Host "Local mode set. Start the server:  .\run.ps1" -ForegroundColor Green
        Write-Host "Then add this connector URL in your client:  http://127.0.0.1:$port"
    }

    "cloudflare" {
        if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
            throw "cloudflared not found. Install it:  winget install Cloudflare.cloudflared"
        }
        $log = [System.IO.Path]::GetTempFileName()
        Write-Host "Starting Cloudflare quick tunnel ..."
        $proc = Start-Process cloudflared `
            -ArgumentList "tunnel", "--url", "http://127.0.0.1:$port" `
            -RedirectStandardError $log -RedirectStandardOutput "$log.out" `
            -PassThru -NoNewWindow
        $url = $null
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 1
            $hit = Select-String -Path $log, "$log.out" -Pattern "https://[a-z0-9-]+\.trycloudflare\.com" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $url = $hit.Matches[0].Value; break }
        }
        if (-not $url) {
            Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue
            throw "Could not read the tunnel URL. See cloudflared output: $log"
        }
        Set-EnvVal "VAULT_MCP_PUBLIC_URL" $url
        Set-EnvVal "VAULT_MCP_ALLOWED_HOSTS" ([uri]$url).Host
        Write-Host ""
        Write-Host "Tunnel live:  $url" -ForegroundColor Green
        Write-Host ".env updated. Now, in a SECOND terminal, start the server:  .\run.ps1"
        Write-Host "Add $url as a custom connector in Claude. Keep THIS window open (it is the tunnel)."
        Wait-Process -Id $proc.Id
    }

    "tailscale" {
        if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) {
            throw "tailscale not found. Install from https://tailscale.com/download, then run:  tailscale up"
        }
        # Make sure you're signed in (opens a browser the first time).
        $st = & tailscale status 2>&1
        if ($LASTEXITCODE -ne 0 -or ($st -match "Logged out")) {
            Write-Host "Signing in to Tailscale - a browser window will open. Approve it, then come back here."
            & tailscale up
        }
        $dns = ""
        try { $dns = ((tailscale status --json | ConvertFrom-Json).Self.DNSName).TrimEnd(".") } catch { }
        if (-not $dns) { throw "Not signed in to Tailscale yet. Run 'tailscale up', then try again." }
        $url = "https://$dns"
        Set-EnvVal "VAULT_MCP_PUBLIC_URL" $url
        Set-EnvVal "VAULT_MCP_ALLOWED_HOSTS" $dns
        Write-Host ""
        Write-Host "Your stable web link:  $url" -ForegroundColor Green
        Write-Host "Turning the public link on in the background (it stays on by itself)..."
        Write-Host "If it says Funnel is not enabled, open the link it prints to turn it on, then run this once more."
        & tailscale funnel --bg $port
        Write-Host ""
        Write-Host "Done. .env updated with your web link. You can CLOSE this window." -ForegroundColor Green
        Write-Host "Go back to the app and click Step 4 - Start.  (To turn the link off later: tailscale funnel reset)"
    }
}
