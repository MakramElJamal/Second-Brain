# Loads .env, hardens the secrets directory ACL (covers the NTFS perms gap),
# and starts the server (upstream hardened core + our token-light tools).
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$envFile = Join-Path $root ".env"
if (-not (Test-Path $envFile)) {
    throw ".env not found. Copy .env.example to .env and fill it in."
}

# Load KEY=VALUE pairs from .env into the process environment.
Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq "" -or $line.StartsWith("#")) { return }
    $idx = $line.IndexOf("=")
    if ($idx -lt 1) { return }
    $key = $line.Substring(0, $idx).Trim()
    $val = $line.Substring($idx + 1).Trim()
    Set-Item -Path "Env:$key" -Value $val
}

# Fail closed: refuse to start without the two secrets.
if (-not $env:VAULT_MCP_TOKEN -or -not $env:VAULT_OAUTH_PASSWORD) {
    throw "VAULT_MCP_TOKEN and VAULT_OAUTH_PASSWORD must be set in .env."
}

# Restrict the secrets directory to the current user only. On NTFS the upstream
# 0600 chmod is a no-op, so we set an explicit ACL here instead.
if ($env:OAUTH_CLIENTS_PATH) {
    $secretsDir = Split-Path -Parent $env:OAUTH_CLIENTS_PATH
    New-Item -ItemType Directory -Force -Path $secretsDir | Out-Null
    icacls $secretsDir /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null
    Write-Host "Secured secrets dir: $secretsDir"
}

Write-Host "Starting second-brain-web-mcp on $($env:VAULT_MCP_HOST):$($env:VAULT_MCP_PORT) ..."

# Capture the server's output to a log file so OAuth / connection errors are
# visible for debugging (the app otherwise runs it hidden with no console).
$logDir = Join-Path $root "logs"
try { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } catch { }
$serverLog = Join-Path $logDir ("server-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
"=== server start $(Get-Date -Format o) | public=$($env:VAULT_MCP_PUBLIC_URL) ===" | Out-File -FilePath $serverLog -Encoding utf8
# The server logs to stderr; under EAP=Stop, capturing stderr turns the first log
# line into a terminating error and KILLS the server. Switch to Continue so it
# keeps running while we tee its output to the log file.
$ErrorActionPreference = "Continue"
& (Join-Path $root ".venv\Scripts\second-brain-mcp.exe") 2>&1 | Tee-Object -FilePath $serverLog -Append
