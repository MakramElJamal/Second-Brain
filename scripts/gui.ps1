# Second Brain - friendly setup window. No terminal, no commands.
# Launched by "Install Second Brain.cmd". Everything below is buttons.
# It checks what's needed, installs anything missing with one click, then walks
# you through Set up -> Start -> connect to Claude.

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $scripts = $PSScriptRoot
    $root = Split-Path -Parent $scripts

    # ---------- helpers ----------
    function Get-Port {
        $port = "8531"; $envFile = Join-Path $root ".env"
        if (Test-Path $envFile) {
            $l = Get-Content $envFile | Where-Object { $_ -match "^\s*VAULT_MCP_PORT\s*=" } | Select-Object -First 1
            if ($l) { $v = ($l -replace "^\s*VAULT_MCP_PORT\s*=\s*", "").Trim(); if ($v) { $port = $v } }
        }
        $port
    }
    function Get-EnvVal($key) {
        $envFile = Join-Path $root ".env"
        if (Test-Path $envFile) {
            $l = Get-Content $envFile | Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -First 1
            if ($l) { return ($l -replace "^\s*$key\s*=\s*", "").Trim() }
        }
        ""
    }
    function Test-Running {
        try { [bool](Get-NetTCPConnection -LocalPort (Get-Port) -State Listen -ErrorAction SilentlyContinue) } catch { $false }
    }
    function Have-Python { [bool]((Get-Command python -ErrorAction SilentlyContinue) -or (Get-Command py -ErrorAction SilentlyContinue)) }
    function Have-Winget { [bool](Get-Command winget -ErrorAction SilentlyContinue) }
    function Info($m, $t = "Second Brain") { [void][System.Windows.Forms.MessageBox]::Show($m, $t) }
    function Run-Window([string]$file, [string[]]$rest, [switch]$Wait) {
        $a = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-File", "`"$file`"") + $rest
        if ($Wait) { Start-Process powershell -ArgumentList $a -Wait } else { Start-Process powershell -ArgumentList $a }
    }

    # ---------- window ----------
    $form = New-Object Windows.Forms.Form
    $form.Text = "Second Brain - Setup"
    $form.Size = New-Object Drawing.Size(500, 560)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
    $form.BackColor = [Drawing.Color]::White

    $title = New-Object Windows.Forms.Label
    $title.Text = "Second Brain"
    $title.Font = New-Object Drawing.Font("Segoe UI", 16, [Drawing.FontStyle]::Bold)
    $title.Location = New-Object Drawing.Point(20, 14); $title.AutoSize = $true
    $form.Controls.Add($title)

    $sub = New-Object Windows.Forms.Label
    $sub.Text = "Connect your notes to Claude in a few clicks."
    $sub.Location = New-Object Drawing.Point(22, 48); $sub.Size = New-Object Drawing.Size(450, 20)
    $sub.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($sub)

    # ----- Step 1: requirements -----
    $g1 = New-Object Windows.Forms.GroupBox
    $g1.Text = "Step 1  -  What you need"
    $g1.Location = New-Object Drawing.Point(20, 80); $g1.Size = New-Object Drawing.Size(450, 80)
    $form.Controls.Add($g1)

    $lblPy = New-Object Windows.Forms.Label
    $lblPy.Location = New-Object Drawing.Point(14, 26); $lblPy.Size = New-Object Drawing.Size(280, 22)
    $g1.Controls.Add($lblPy)

    $btnPy = New-Object Windows.Forms.Button
    $btnPy.Text = "Install for me"
    $btnPy.Location = New-Object Drawing.Point(300, 22); $btnPy.Size = New-Object Drawing.Size(135, 30)
    $g1.Controls.Add($btnPy)

    # ----- Step 2: set up -----
    $btnSetup = New-Object Windows.Forms.Button
    $btnSetup.Text = "Step 2  -  Choose my notes folder and set up"
    $btnSetup.Location = New-Object Drawing.Point(20, 172); $btnSetup.Size = New-Object Drawing.Size(450, 44)
    $btnSetup.Font = New-Object Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($btnSetup)

    # ----- Step 3: start + login info -----
    $btnStart = New-Object Windows.Forms.Button
    $btnStart.Text = "Step 3  -  Start"
    $btnStart.Location = New-Object Drawing.Point(20, 226); $btnStart.Size = New-Object Drawing.Size(220, 44)
    $btnStart.Font = New-Object Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($btnStart)

    $btnStop = New-Object Windows.Forms.Button
    $btnStop.Text = "Stop"
    $btnStop.Location = New-Object Drawing.Point(250, 226); $btnStop.Size = New-Object Drawing.Size(220, 44)
    $form.Controls.Add($btnStop)

    $g3 = New-Object Windows.Forms.GroupBox
    $g3.Text = "Step 4  -  Add this to Claude"
    $g3.Location = New-Object Drawing.Point(20, 282); $g3.Size = New-Object Drawing.Size(450, 110)
    $form.Controls.Add($g3)

    $lblConn = New-Object Windows.Forms.Label
    $lblConn.Location = New-Object Drawing.Point(14, 24); $lblConn.Size = New-Object Drawing.Size(420, 50)
    $lblConn.Font = New-Object Drawing.Font("Consolas", 9)
    $g3.Controls.Add($lblConn)

    $btnCopy = New-Object Windows.Forms.Button
    $btnCopy.Text = "Copy link + password"
    $btnCopy.Location = New-Object Drawing.Point(14, 74); $btnCopy.Size = New-Object Drawing.Size(200, 28)
    $g3.Controls.Add($btnCopy)

    $btnWeb = New-Object Windows.Forms.Button
    $btnWeb.Text = "Use from phone / web (advanced)"
    $btnWeb.Location = New-Object Drawing.Point(224, 74); $btnWeb.Size = New-Object Drawing.Size(210, 28)
    $g3.Controls.Add($btnWeb)

    # ----- status + uninstall -----
    $lblStatus = New-Object Windows.Forms.Label
    $lblStatus.Location = New-Object Drawing.Point(22, 404); $lblStatus.Size = New-Object Drawing.Size(330, 40)
    $lblStatus.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($lblStatus)

    $btnUninstall = New-Object Windows.Forms.Button
    $btnUninstall.Text = "Uninstall"
    $btnUninstall.Location = New-Object Drawing.Point(355, 410); $btnUninstall.Size = New-Object Drawing.Size(115, 28)
    $btnUninstall.ForeColor = [Drawing.Color]::Firebrick
    $form.Controls.Add($btnUninstall)

    # ---------- state refresh ----------
    function Refresh-UI {
        $py = Have-Python
        $configured = Test-Path (Join-Path $root ".env")
        $installed = Test-Path (Join-Path $root ".venv")
        $running = Test-Running

        if ($py) { $lblPy.Text = "Python:  installed  (OK)"; $lblPy.ForeColor = [Drawing.Color]::SeaGreen; $btnPy.Enabled = $false }
        else { $lblPy.Text = "Python:  missing"; $lblPy.ForeColor = [Drawing.Color]::Firebrick; $btnPy.Enabled = $true }

        $btnSetup.Enabled = $py
        $btnStart.Enabled = ($configured -and $installed -and -not $running)
        $btnStop.Enabled = $running

        if ($configured) {
            $port = Get-Port; $pass = Get-EnvVal "VAULT_OAUTH_PASSWORD"
            $url = Get-EnvVal "VAULT_MCP_PUBLIC_URL"; if (-not $url) { $url = "http://127.0.0.1:$port" }
            $lblConn.Text = "Link:      $url`r`nUsername:  obsidian`r`nPassword:  $pass"
            $btnCopy.Enabled = $true
        }
        else { $lblConn.Text = "(finish Step 2 first)"; $btnCopy.Enabled = $false }

        $lblStatus.Text = "Installed: $(if($installed){'yes'}else{'no'})   Set up: $(if($configured){'yes'}else{'no'})`r`nServer: $(if($running){'RUNNING'}else{'stopped'})"
    }

    # ---------- actions ----------
    $btnPy.Add_Click({
            if (Have-Winget) {
                Info("Windows will now install Python for you. A window may appear - let it finish, then CLOSE this app and open 'Install Second Brain' again.")
                Start-Process winget -ArgumentList "install", "-e", "--id", "Python.Python.3.12", "--scope", "user", "--accept-source-agreements", "--accept-package-agreements" -Wait
                Info("If Python finished installing, please close this window and open 'Install Second Brain' again.")
            }
            else {
                Info("Your Windows can't auto-install. The download page will open - install Python (tick 'Add python.exe to PATH'), then reopen this app.")
                Start-Process "https://www.python.org/downloads/"
            }
            Refresh-UI
        })

    $btnSetup.Add_Click({
            $dlg = New-Object Windows.Forms.FolderBrowserDialog
            $dlg.Description = "Choose your notes folder (your Obsidian vault)"
            if ($dlg.ShowDialog() -ne "OK") { return }
            Info("Setting up. A black window will open and show your PASSWORD when it finishes - keep it. This can take a minute. Then come back and click Step 3.")
            Run-Window (Join-Path $scripts "setup.ps1") @("-Force", "-VaultPath", "`"$($dlg.SelectedPath)`"")
        })

    $btnStart.Add_Click({ Run-Window (Join-Path $root "run.ps1") @(); Start-Sleep -Seconds 1; Refresh-UI })
    $btnStop.Add_Click({ Run-Window (Join-Path $scripts "stop.ps1") @("-Quiet") -Wait; Refresh-UI })

    $btnCopy.Add_Click({
            $port = Get-Port; $pass = Get-EnvVal "VAULT_OAUTH_PASSWORD"
            $url = Get-EnvVal "VAULT_MCP_PUBLIC_URL"; if (-not $url) { $url = "http://127.0.0.1:$port" }
            [System.Windows.Forms.Clipboard]::SetText("Link: $url`r`nUsername: obsidian`r`nPassword: $pass")
            Info("Copied. In Claude: Settings -> Connectors -> Add custom connector, paste the Link, then sign in with the username and password.")
        })

    $btnWeb.Add_Click({
            $choice = [System.Windows.Forms.MessageBox]::Show(
                "Get a web link so you can use it from your phone / claude.ai?`n`nYes  = Tailscale (free account, stable link - recommended)`nNo   = keep it on this computer only",
                "Web access", "YesNo")
            if ($choice -eq "Yes") { Run-Window (Join-Path $scripts "connect.ps1") @("-Mode", "tailscale") }
        })

    $btnUninstall.Add_Click({
            $r = [System.Windows.Forms.MessageBox]::Show("Remove the install? Your notes are NOT touched.", "Uninstall", "YesNo")
            if ($r -eq "Yes") { Run-Window (Join-Path $scripts "uninstall.ps1") @("-Yes") -Wait; Refresh-UI }
        })

    Refresh-UI
    [void]$form.ShowDialog()
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("Sorry, something went wrong opening the setup window:`n`n$($_.Exception.Message)", "Second Brain")
}
