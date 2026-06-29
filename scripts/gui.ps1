# Second Brain MCP - a simple click-through window for non-technical users.
# Launched by the "Second-Brain.cmd" file in the project folder (double-click it).
# It just wires buttons to the tested scripts (setup/connect/run/stop/uninstall).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scripts = $PSScriptRoot
$root = Split-Path -Parent $scripts

function Get-Port {
    $port = "8531"; $envFile = Join-Path $root ".env"
    if (Test-Path $envFile) {
        $l = Get-Content $envFile | Where-Object { $_ -match "^\s*VAULT_MCP_PORT\s*=" } | Select-Object -First 1
        if ($l) { $v = ($l -replace "^\s*VAULT_MCP_PORT\s*=\s*", "").Trim(); if ($v) { $port = $v } }
    }
    $port
}
function Test-Running {
    try { [bool](Get-NetTCPConnection -LocalPort (Get-Port) -State Listen -ErrorAction SilentlyContinue) }
    catch { $false }
}
function Run-Window([string]$file, [string[]]$rest, [switch]$Wait) {
    # Run a .ps1 in its own visible window (so the user sees progress + secrets).
    $a = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-File", "`"$file`"") + $rest
    if ($Wait) { Start-Process powershell -ArgumentList $a -Wait } else { Start-Process powershell -ArgumentList $a }
}
function Info($m) { [void][System.Windows.Forms.MessageBox]::Show($m, "Second Brain MCP") }

$form = New-Object Windows.Forms.Form
$form.Text = "Second Brain MCP"
$form.Size = New-Object Drawing.Size(440, 470)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$title = New-Object Windows.Forms.Label
$title.Text = "Second Brain MCP"
$title.Font = New-Object Drawing.Font("Segoe UI", 15, [Drawing.FontStyle]::Bold)
$title.Location = New-Object Drawing.Point(20, 15); $title.AutoSize = $true
$form.Controls.Add($title)

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(22, 55); $status.Size = New-Object Drawing.Size(390, 40)
$status.ForeColor = [Drawing.Color]::DimGray
$form.Controls.Add($status)

function Refresh-Status {
    $installed = Test-Path (Join-Path $root ".venv")
    $configured = Test-Path (Join-Path $root ".env")
    $run = Test-Running
    $status.Text = "Installed: $(if($installed){'yes'}else{'no'})   " +
                   "Configured: $(if($configured){'yes'}else{'no'})`n" +
                   "Server: $(if($run){"RUNNING on port $(Get-Port)"}else{'stopped'})"
}

$y = 105
function Add-Button([string]$text, [scriptblock]$onClick) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object Drawing.Point(22, $script:y)
    $b.Size = New-Object Drawing.Size(390, 42)
    $b.Font = New-Object Drawing.Font("Segoe UI", 10)
    $b.Add_Click($onClick)
    $form.Controls.Add($b)
    $script:y += 50
    return $b
}

Add-Button "1.  Set up  (first time)" {
    if (-not (Get-Command python -ErrorAction SilentlyContinue) -and -not (Get-Command py -ErrorAction SilentlyContinue)) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Python is required and was not found.`n`nClick OK to open the Python download page. Install it (tick 'Add python.exe to PATH'), then come back and click Set up again.",
            "Install Python first", "OKCancel")
        if ($r -eq "OK") { Start-Process "https://www.python.org/downloads/" }
        return
    }
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Choose your notes folder (your Obsidian vault)"
    if ($dlg.ShowDialog() -ne "OK") { return }
    Info("Setting up... a window will open and show your login password. Keep it.`nThis can take a minute the first time.")
    Run-Window (Join-Path $scripts "setup.ps1") @("-Force", "-VaultPath", "`"$($dlg.SelectedPath)`"")
    Refresh-Status
} | Out-Null

Add-Button "2.  Choose how to connect" {
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "Use it from the WEB / phone?`n`nYes  = Tailscale (free account, stable link - recommended)`nNo   = Local only (this computer)`nCancel = Cloudflare quick (temporary link)",
        "Connect", "YesNoCancel")
    $mode = switch ($choice) { "Yes" { "tailscale" } "No" { "local" } "Cancel" { "cloudflare" } }
    Run-Window (Join-Path $scripts "connect.ps1") @("-Mode", $mode)
} | Out-Null

Add-Button "3.  Start the server" {
    Run-Window (Join-Path $root "run.ps1") @()
    Start-Sleep -Seconds 1; Refresh-Status
} | Out-Null

Add-Button "4.  Stop the server" {
    Run-Window (Join-Path $scripts "stop.ps1") @("-Quiet") -Wait
    Refresh-Status
} | Out-Null

Add-Button "Open the health check (browser)" {
    Start-Process ("http://127.0.0.1:" + (Get-Port) + "/health")
} | Out-Null

$btnUninstall = Add-Button "Uninstall" {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Remove the install? Your notes/vault are NOT touched.", "Uninstall", "YesNo")
    if ($r -eq "Yes") { Run-Window (Join-Path $scripts "uninstall.ps1") @("-Yes") -Wait; Refresh-Status }
}
$btnUninstall.ForeColor = [Drawing.Color]::Firebrick

Refresh-Status
[void]$form.ShowDialog()
