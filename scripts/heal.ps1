# Silent self-heal runner for the web link. Called by the scheduled tasks that
# watchdog.ps1 registers (on resume-from-sleep + every 15 minutes). Runs the
# end-to-end public check in tailscale.ps1 (which reconnects a stale Tailscale
# session automatically) and appends one line per run to logs\heal.log.
# No window, no prompts, exits 0 always -- a heal failure must never surface as
# a scary scheduled-task error to the user.
$ErrorActionPreference = "SilentlyContinue"
$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root ".env"
if (-not (Test-Path $envFile)) { exit 0 }

function Get-EnvVal($key) {
    $l = Get-Content $envFile | Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -First 1
    if ($l) { ($l -replace "^\s*$key\s*=\s*", "").Trim() }
}

$pub = Get-EnvVal "VAULT_MCP_PUBLIC_URL"
if (-not $pub) { exit 0 }   # local-only setup: nothing to heal
$port = Get-EnvVal "VAULT_MCP_PORT"; if (-not $port) { $port = "8531" }

$out = (& (Join-Path $PSScriptRoot "tailscale.ps1") -Action check -Port ([int]$port) 2>&1 | Out-String)
$marker = ([regex]::Match($out, "TS_[A-Z_]+")).Value
if (-not $marker) { $marker = "NO_MARKER" }

$logDir = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "heal.log"
Add-Content -Path $log -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $marker) -Encoding utf8
# Keep the log small: trim to the newest 100 lines once it passes 200.
$lines = @(Get-Content $log)
if ($lines.Count -gt 200) { $lines | Select-Object -Last 100 | Set-Content $log -Encoding utf8 }
exit 0
