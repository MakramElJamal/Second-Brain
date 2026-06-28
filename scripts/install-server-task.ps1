# Registers auto-starting, self-restarting Task Scheduler jobs for the MCP server
# (and optionally the Cloudflare tunnel), and disables sleep on AC power so the
# laptop stays reachable. MUST be run in an Administrator PowerShell.
#
#   .\scripts\install-server-task.ps1                          # server only
#   .\scripts\install-server-task.ps1 -CloudflaredTunnel second-brain   # + tunnel
#
param(
    [string]$CloudflaredTunnel = "",
    [string]$CloudflaredPath = "C:\Program Files (x86)\cloudflared\cloudflared.exe"
)
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$runPs1 = Join-Path $root "run.ps1"
$logDir = Join-Path $root "logs"
$log = Join-Path $logDir "server.log"
$taskName = "SecondBrainMCP"

if (-not (Test-Path $runPs1)) { throw "run.ps1 not found at $runPs1" }
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# Admin check (needed for powercfg and a robust task registration).
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Not elevated. Re-run this in an Administrator PowerShell for powercfg + reliable task setup."
}

# Run run.ps1 at log on, restart on crash, append output to a log file.
$cmd = "& '$runPs1' *>> '$log' 2>&1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$cmd`"" `
    -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Force `
    -Description "Second Brain MCP server (auto-start at logon, restart on crash)." | Out-Null
Write-Host "Registered scheduled task '$taskName' (starts at log on; logs -> $log)."

# Optional: auto-start the Cloudflare named tunnel the same way.
if ($CloudflaredTunnel) {
    if (-not (Test-Path $CloudflaredPath)) { throw "cloudflared not found at $CloudflaredPath" }
    $tAction = New-ScheduledTaskAction -Execute $CloudflaredPath -Argument "tunnel run $CloudflaredTunnel"
    Register-ScheduledTask -TaskName "SecondBrainTunnel" -Action $tAction -Trigger $trigger `
        -Settings $settings -Force `
        -Description "Cloudflare named tunnel for the Second Brain MCP server." | Out-Null
    Write-Host "Registered scheduled task 'SecondBrainTunnel' (cloudflared tunnel run $CloudflaredTunnel)."
}

# Keep the machine reachable while plugged in (sleep/hibernate = unreachable).
if ($isAdmin) {
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
    Write-Host "Set: never sleep/hibernate while on AC power."
} else {
    Write-Host "Skipped powercfg (needs admin). Run: powercfg /change standby-timeout-ac 0"
}

Write-Host "`nStart it now without rebooting:  Start-ScheduledTask -TaskName '$taskName'"
Write-Host "Remove later:                    Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false"
