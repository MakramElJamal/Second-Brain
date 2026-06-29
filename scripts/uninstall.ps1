# Remove the installed environment (virtualenv + build artifacts), and optionally
# your secrets. YOUR VAULT AND NOTES ARE NEVER TOUCHED.
[CmdletBinding()]
param([switch]$Yes, [switch]$PurgeSecrets)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

Write-Host "This removes the Second Brain MCP install (virtualenv + build files)."
Write-Host "Your vault and notes are NOT touched." -ForegroundColor Yellow
if (-not $Yes) {
    if ((Read-Host "Proceed? (y/N)") -ne "y") { Write-Host "Cancelled."; return }
}

# Stop the server first so nothing is locked.
& (Join-Path $PSScriptRoot "stop.ps1") -Quiet

$targets = @(".venv", ".pytest_cache",
    "src\second_brain_ext.egg-info", "src\obsidian_vault_mcp.egg-info",
    "second_brain_web_mcp.egg-info", "build")
foreach ($t in $targets) {
    $p = Join-Path $root $t
    if (Test-Path $p) { Remove-Item -Recurse -Force $p; Write-Host "Removed $t" }
}

$purge = $PurgeSecrets
if (-not $purge -and -not $Yes) {
    $purge = ((Read-Host "Also delete your login secrets (.env and .secrets)? (y/N)") -eq "y")
}
if ($purge) {
    foreach ($t in @(".env", ".secrets")) {
        $p = Join-Path $root $t
        if (Test-Path $p) { Remove-Item -Recurse -Force $p; Write-Host "Removed $t" }
    }
}

Write-Host ""
Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host "To remove everything, just delete this folder."
Write-Host "If you set up auto-start (install-server-task.ps1), remove it as Administrator:"
Write-Host "  Unregister-ScheduledTask -TaskName 'SecondBrainMCP*' -Confirm:`$false"
