# Start the server automatically when you log in (no Administrator needed).
# It drops a hidden-launch shortcut into your Startup folder; remove it to stop.
#
#   .\scripts\autostart.ps1 -Action enable
#   .\scripts\autostart.ps1 -Action disable
#   .\scripts\autostart.ps1 -Action status     # prints 'enabled' or 'disabled'
[CmdletBinding()]
param([ValidateSet("enable", "disable", "status")][string]$Action = "status")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$startup = [Environment]::GetFolderPath("Startup")
$lnk = Join-Path $startup "Second Brain MCP.lnk"
$runPs1 = Join-Path $root "run.ps1"

switch ($Action) {
    "enable" {
        $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath = $psExe
        $sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runPs1`""
        $sc.WorkingDirectory = $root
        $sc.WindowStyle = 7   # minimized; -WindowStyle Hidden keeps it invisible
        $sc.Description = "Starts the Second Brain MCP server at login"
        $sc.Save()
        Write-Host "Auto-start is ON. The server will start quietly when you log in." -ForegroundColor Green
        Write-Host "(This starts the server only. For web access, the tunnel still needs to be started.)"
    }
    "disable" {
        if (Test-Path $lnk) { Remove-Item $lnk -Force }
        Write-Host "Auto-start is OFF." -ForegroundColor Green
    }
    "status" {
        if (Test-Path $lnk) { "enabled" } else { "disabled" }
    }
}
