# Second Brain - friendly setup window. No terminal, no commands.
# Launched by "Install Second Brain.cmd". Everything below is buttons.
# Flow: 1) requirements  2) set up  3) how you'll use it  4) start  5) add to Claude.

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
    function Have-Tailscale { [bool](Get-Command tailscale -ErrorAction SilentlyContinue) }
    function Info($m, $t = "Second Brain") { [void][System.Windows.Forms.MessageBox]::Show($m, $t) }
    function Run-Window([string]$file, [string[]]$rest, [switch]$Wait) {
        $a = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-File", "`"$file`"") + $rest
        if ($Wait) { Start-Process powershell -ArgumentList $a -Wait } else { Start-Process powershell -ArgumentList $a }
    }
    function Run-Hidden([string]$file, [string[]]$rest) {
        Start-Process powershell -WindowStyle Hidden -ArgumentList (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$file`"") + $rest)
    }
    function Refresh-Path {
        $m = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $u = [Environment]::GetEnvironmentVariable("Path", "User")
        $env:Path = (@($m, $u) | Where-Object { $_ }) -join ";"
    }
    function Restart-App {
        Refresh-Path
        Start-Process (Join-Path $root "Install Second Brain.cmd")
        $form.Close()
    }

    # ---------- window ----------
    $form = New-Object Windows.Forms.Form
    $form.Text = "Second Brain - Setup"
    $form.Size = New-Object Drawing.Size(500, 620)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
    $form.BackColor = [Drawing.Color]::White

    $title = New-Object Windows.Forms.Label
    $title.Text = "Second Brain"
    $title.Font = New-Object Drawing.Font("Segoe UI", 16, [Drawing.FontStyle]::Bold)
    $title.Location = New-Object Drawing.Point(20, 12); $title.AutoSize = $true
    $form.Controls.Add($title)

    $sub = New-Object Windows.Forms.Label
    $sub.Text = "Connect your notes to Claude in a few clicks."
    $sub.Location = New-Object Drawing.Point(22, 44); $sub.Size = New-Object Drawing.Size(450, 20)
    $sub.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($sub)

    # ----- Step 1: requirements -----
    $g1 = New-Object Windows.Forms.GroupBox
    $g1.Text = "Step 1  -  What you need"
    $g1.Location = New-Object Drawing.Point(20, 72); $g1.Size = New-Object Drawing.Size(450, 70)
    $form.Controls.Add($g1)
    $lblPy = New-Object Windows.Forms.Label
    $lblPy.Location = New-Object Drawing.Point(14, 26); $lblPy.Size = New-Object Drawing.Size(280, 22)
    $g1.Controls.Add($lblPy)
    $btnPy = New-Object Windows.Forms.Button
    $btnPy.Text = "Install for me"
    $btnPy.Location = New-Object Drawing.Point(300, 20); $btnPy.Size = New-Object Drawing.Size(135, 30)
    $g1.Controls.Add($btnPy)

    # ----- Step 2: set up -----
    $btnSetup = New-Object Windows.Forms.Button
    $btnSetup.Text = "Step 2  -  Choose my notes folder and set up"
    $btnSetup.Location = New-Object Drawing.Point(20, 150); $btnSetup.Size = New-Object Drawing.Size(450, 42)
    $btnSetup.Font = New-Object Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($btnSetup)

    # ----- Step 3: how will you use it -----
    $g2 = New-Object Windows.Forms.GroupBox
    $g2.Text = "Step 3  -  How will you use it?"
    $g2.Location = New-Object Drawing.Point(20, 200); $g2.Size = New-Object Drawing.Size(450, 112)
    $form.Controls.Add($g2)
    $btnWeb = New-Object Windows.Forms.Button
    $btnWeb.Text = "From my phone and the web   (recommended)"
    $btnWeb.Location = New-Object Drawing.Point(14, 22); $btnWeb.Size = New-Object Drawing.Size(420, 34)
    $btnWeb.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $g2.Controls.Add($btnWeb)
    $btnLocal = New-Object Windows.Forms.Button
    $btnLocal.Text = "Only on this computer"
    $btnLocal.Location = New-Object Drawing.Point(14, 60); $btnLocal.Size = New-Object Drawing.Size(420, 26)
    $g2.Controls.Add($btnLocal)
    $lblMode = New-Object Windows.Forms.Label
    $lblMode.Location = New-Object Drawing.Point(16, 90); $lblMode.Size = New-Object Drawing.Size(418, 18)
    $g2.Controls.Add($lblMode)

    # ----- Step 4: start -----
    $btnStart = New-Object Windows.Forms.Button
    $btnStart.Text = "Step 4  -  Start"
    $btnStart.Location = New-Object Drawing.Point(20, 322); $btnStart.Size = New-Object Drawing.Size(220, 42)
    $btnStart.Font = New-Object Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($btnStart)
    $btnStop = New-Object Windows.Forms.Button
    $btnStop.Text = "Stop"
    $btnStop.Location = New-Object Drawing.Point(250, 322); $btnStop.Size = New-Object Drawing.Size(220, 42)
    $form.Controls.Add($btnStop)

    # ----- Step 5: add to Claude -----
    $g3 = New-Object Windows.Forms.GroupBox
    $g3.Text = "Step 5  -  Add this to Claude"
    $g3.Location = New-Object Drawing.Point(20, 372); $g3.Size = New-Object Drawing.Size(450, 100)
    $form.Controls.Add($g3)
    $lblConn = New-Object Windows.Forms.Label
    $lblConn.Location = New-Object Drawing.Point(14, 22); $lblConn.Size = New-Object Drawing.Size(424, 46)
    $lblConn.Font = New-Object Drawing.Font("Consolas", 9)
    $g3.Controls.Add($lblConn)
    $btnCopy = New-Object Windows.Forms.Button
    $btnCopy.Text = "Copy link + password"
    $btnCopy.Location = New-Object Drawing.Point(14, 70); $btnCopy.Size = New-Object Drawing.Size(200, 26)
    $g3.Controls.Add($btnCopy)

    # ----- status, auto-start, uninstall -----
    $lblStatus = New-Object Windows.Forms.Label
    $lblStatus.Location = New-Object Drawing.Point(22, 480); $lblStatus.Size = New-Object Drawing.Size(300, 34)
    $lblStatus.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($lblStatus)

    $chkAuto = New-Object Windows.Forms.CheckBox
    $chkAuto.Text = "Start automatically when I turn on my PC"
    $chkAuto.Location = New-Object Drawing.Point(22, 518); $chkAuto.Size = New-Object Drawing.Size(325, 24)
    $form.Controls.Add($chkAuto)
    $script:autoBusy = $false

    $btnUninstall = New-Object Windows.Forms.Button
    $btnUninstall.Text = "Uninstall"
    $btnUninstall.Location = New-Object Drawing.Point(355, 514); $btnUninstall.Size = New-Object Drawing.Size(115, 28)
    $btnUninstall.ForeColor = [Drawing.Color]::Firebrick
    $form.Controls.Add($btnUninstall)

    # ---------- state refresh ----------
    function Refresh-UI {
        $py = Have-Python
        $configured = Test-Path (Join-Path $root ".env")
        $installed = Test-Path (Join-Path $root ".venv")
        $running = Test-Running
        $pub = Get-EnvVal "VAULT_MCP_PUBLIC_URL"

        if ($py) { $lblPy.Text = "Python:  installed  (OK)"; $lblPy.ForeColor = [Drawing.Color]::SeaGreen; $btnPy.Enabled = $false }
        else { $lblPy.Text = "Python:  missing"; $lblPy.ForeColor = [Drawing.Color]::Firebrick; $btnPy.Enabled = $true }

        $btnSetup.Enabled = $py
        $btnWeb.Enabled = $configured
        $btnLocal.Enabled = $configured
        $btnStart.Enabled = ($configured -and $installed -and -not $running)
        $btnStop.Enabled = $running

        if (-not $configured) { $lblMode.Text = "(finish Step 2 first)"; $lblMode.ForeColor = [Drawing.Color]::Gray }
        elseif ($pub) { $lblMode.Text = "Now: web link (Tailscale) - works on your phone and claude.ai"; $lblMode.ForeColor = [Drawing.Color]::SeaGreen }
        else { $lblMode.Text = "Now: this computer only (pick an option above)"; $lblMode.ForeColor = [Drawing.Color]::DimGray }

        if ($configured) {
            $port = Get-Port; $pass = Get-EnvVal "VAULT_OAUTH_PASSWORD"
            $url = $pub; if (-not $url) { $url = "http://127.0.0.1:$port" }
            $lblConn.Text = "Link:      $url`r`nUsername:  obsidian`r`nPassword:  $pass"
            $btnCopy.Enabled = $true
        }
        else { $lblConn.Text = "(finish Step 2 first)"; $btnCopy.Enabled = $false }

        $lblStatus.Text = "Installed: $(if($installed){'yes'}else{'no'})   Set up: $(if($configured){'yes'}else{'no'})`r`nServer: $(if($running){'RUNNING'}else{'stopped'})"
    }

    # ---------- actions ----------
    $btnPy.Add_Click({
            if (Have-Winget) {
                Info("Windows will now install Python for you. Let the window finish - then the app continues on its own.")
                Start-Process winget -ArgumentList "install", "-e", "--id", "Python.Python.3.12", "--scope", "user", "--accept-source-agreements", "--accept-package-agreements" -Wait
                Refresh-Path
                if (Have-Python) { Info("Python is installed. You're set - go to Step 2."); Refresh-UI }
                else { Info("Finishing the Python setup - reopening the app for you."); Restart-App }
            }
            else {
                Info("Your Windows can't auto-install. The download page will open - install Python (tick 'Add python.exe to PATH'), then reopen this app.")
                Start-Process "https://www.python.org/downloads/"
                Refresh-UI
            }
        })

    $btnSetup.Add_Click({
            $dlg = New-Object Windows.Forms.FolderBrowserDialog
            $dlg.Description = "Choose your notes folder (your Obsidian vault)"
            if ($dlg.ShowDialog() -ne "OK") { return }
            Info("Setting up. A window opens with a progress bar - let it finish (about a minute). Then come back and choose Step 3.")
            Run-Window (Join-Path $scripts "setup.ps1") @("-Force", "-VaultPath", "`"$($dlg.SelectedPath)`"")
        })

    $btnWeb.Add_Click({
            if (-not (Have-Tailscale)) {
                if (Have-Winget) {
                    Info("Installing Tailscale (free) so you can reach it from anywhere. Windows may ask for permission - click Yes, and let it finish.")
                    Start-Process winget -ArgumentList "install", "-e", "--id", "tailscale.tailscale", "--accept-source-agreements", "--accept-package-agreements" -Wait
                    Refresh-Path
                }
                else {
                    Info("Please install Tailscale from the page that opens, then click this again.")
                    Start-Process "https://tailscale.com/download"; return
                }
            }
            if (-not (Have-Tailscale)) {
                Info("Tailscale isn't ready yet. Open 'Tailscale' from the Start menu and sign in, then click this again.")
                return
            }
            Info("A window opens next. Sign in to Tailscale if asked - it then creates your web link. When you see the link, close that window, come back, and click Step 4 - Start.")
            Run-Window (Join-Path $scripts "connect.ps1") @("-Mode", "tailscale")
        })

    $btnLocal.Add_Click({
            try { & (Join-Path $scripts "connect.ps1") -Mode local | Out-Null }
            catch { Info("Couldn't set local mode:`n$($_.Exception.Message)"); return }
            Refresh-UI
            Info("Set to: only on this computer. This works with Claude Desktop / Claude Code on THIS PC. Now click Step 4 - Start.")
        })

    $btnStart.Add_Click({
            Run-Hidden (Join-Path $root "run.ps1") @()
            Start-Sleep -Seconds 3
            Refresh-UI
            if (Test-Running) { Info("Server is ON (running quietly in the background). Now do Step 5 - copy the link into Claude.") }
            else { Info("It didn't start. Make sure Step 2 finished, then click Start again.") }
        })
    $btnStop.Add_Click({ Run-Window (Join-Path $scripts "stop.ps1") @("-Quiet") -Wait; Refresh-UI })

    $btnCopy.Add_Click({
            $port = Get-Port; $pass = Get-EnvVal "VAULT_OAUTH_PASSWORD"
            $url = Get-EnvVal "VAULT_MCP_PUBLIC_URL"; if (-not $url) { $url = "http://127.0.0.1:$port" }
            [System.Windows.Forms.Clipboard]::SetText("Link: $url`r`nUsername: obsidian`r`nPassword: $pass")
            Info("Copied. In Claude: Settings -> Connectors -> Add custom connector, paste the Link, then sign in with the username and password.")
        })

    $btnUninstall.Add_Click({
            $r = [System.Windows.Forms.MessageBox]::Show("Remove the install? Your notes are NOT touched.", "Uninstall", "YesNo")
            if ($r -eq "Yes") { Run-Window (Join-Path $scripts "uninstall.ps1") @("-Yes") -Wait; Refresh-UI }
        })

    $chkAuto.Add_CheckedChanged({
            if ($script:autoBusy) { return }
            try {
                $act = if ($chkAuto.Checked) { "enable" } else { "disable" }
                & (Join-Path $scripts "autostart.ps1") -Action $act | Out-Null
            }
            catch { Info("Couldn't change auto-start:`n$($_.Exception.Message)") }
        })

    $script:autoBusy = $true
    try { $chkAuto.Checked = ((& (Join-Path $scripts "autostart.ps1") -Action status) -eq "enabled") } catch { }
    $script:autoBusy = $false

    Refresh-UI
    [void]$form.ShowDialog()
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("Sorry, something went wrong opening the setup window:`n`n$($_.Exception.Message)", "Second Brain")
}
