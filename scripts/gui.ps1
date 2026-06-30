# Second Brain - friendly setup window. No terminal, no console windows.
# Launched by "Install Second Brain.cmd". Everything is buttons; background tasks
# run hidden and show a clean "Please wait" progress bar inside the app.

try {
    # Hide this PowerShell console window so only the app window shows (and so the
    # user can't accidentally close the console and kill the app).
    try {
        $sbHide = Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);' -Name H -Namespace SBHide -PassThru
        [void]$sbHide::ShowWindow($sbHide::GetConsoleWindow(), 0)   # 0 = SW_HIDE
    }
    catch { }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $scripts = $PSScriptRoot
    $root = Split-Path -Parent $scripts

    # ---- modern (Explorer-style) folder picker via IFileDialog -------------
    $script:modernPicker = $false
    try {
        if (-not ("SB.FolderPicker" -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SB {
  [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] internal class FileOpenDialogRCW { }
  [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  internal interface IFileDialog {
    [PreserveSig] int Show(IntPtr parent);
    void SetFileTypes(); void SetFileTypeIndex(uint i); void GetFileTypeIndex(out uint i);
    void Advise(); void Unadvise();
    void SetOptions(uint fos); void GetOptions(out uint fos);
    void SetDefaultFolder(IntPtr psi); void SetFolder(IntPtr psi); void GetFolder(out IntPtr ppsi);
    void GetCurrentSelection(out IntPtr ppsi);
    void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string n); void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string n);
    void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string t);
    void SetOkButtonLabel(); void SetFileNameLabel();
    void GetResult(out IShellItem ppsi);
    void AddPlace(); void SetDefaultExtension(); void Close(int hr); void SetClientGuid(); void ClearClientData(); void SetFilter();
  }
  [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  internal interface IShellItem {
    void BindToHandler(); void GetParent();
    void GetDisplayName(uint sigdn, [MarshalAs(UnmanagedType.LPWStr)] out string name);
    void GetAttributes(); void Compare();
  }
  public static class FolderPicker {
    public static string Pick(string title, IntPtr owner) {
      IFileDialog d = (IFileDialog)new FileOpenDialogRCW();
      uint o; d.GetOptions(out o); d.SetOptions(o | 0x20 | 0x40); // PICKFOLDERS | FORCEFILESYSTEM
      if (!string.IsNullOrEmpty(title)) d.SetTitle(title);
      if (d.Show(owner) != 0) return null;
      IShellItem it; d.GetResult(out it);
      string p; it.GetDisplayName(0x80058000, out p); // SIGDN_FILESYSPATH
      return p;
    }
  }
}
'@
        }
        $script:modernPicker = $true
    }
    catch { $script:modernPicker = $false }

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
    function Find-Tailscale {
        $c = Get-Command tailscale -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        foreach ($p in @("$env:ProgramFiles\Tailscale\tailscale.exe", "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe")) {
            if ($p -and (Test-Path $p)) { return $p }
        }
        return $null
    }
    function Info($m, $t = "Second Brain") { [void][System.Windows.Forms.MessageBox]::Show($m, $t) }
    function Tail($text, $n = 8) {
        if (-not $text) { return "" }
        (($text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last $n) -join "`r`n"
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
    function Run-Hidden([string]$file, [string[]]$rest) {
        # Fire-and-forget hidden process (used for the long-lived server).
        Start-Process powershell -WindowStyle Hidden -ArgumentList (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$file`"") + $rest)
    }
    function Pick-Folder($title) {
        if ($script:modernPicker) {
            try { return [SB.FolderPicker]::Pick($title, $form.Handle) } catch { }
        }
        $dlg = New-Object Windows.Forms.FolderBrowserDialog
        $dlg.Description = $title
        if ($dlg.ShowDialog() -eq "OK") { return $dlg.SelectedPath } else { return $null }
    }
    function Invoke-Hidden([string]$file, [string[]]$argList, [string]$workingText, [string]$successToken) {
        # Run a script HIDDEN while showing a clean "please wait" bar; return Ok + Output.
        # Success is judged by a marker the script prints on completion (reliable),
        # falling back to the exit code when no marker is given.
        $out = [System.IO.Path]::GetTempFileName(); $err = [System.IO.Path]::GetTempFileName()
        $a = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$file`"") + $argList
        $script:hpProc = Start-Process powershell -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err -ArgumentList $a

        $w = New-Object Windows.Forms.Form
        $w.Text = "Please wait"; $w.Size = New-Object Drawing.Size(370, 150); $w.StartPosition = "CenterParent"
        $w.FormBorderStyle = "FixedDialog"; $w.ControlBox = $false; $w.MinimizeBox = $false; $w.MaximizeBox = $false
        $lbl = New-Object Windows.Forms.Label; $lbl.Text = $workingText
        $lbl.Location = New-Object Drawing.Point(18, 18); $lbl.Size = New-Object Drawing.Size(330, 56)
        $pb = New-Object Windows.Forms.ProgressBar; $pb.Style = "Marquee"; $pb.MarqueeAnimationSpeed = 30
        $pb.Location = New-Object Drawing.Point(18, 84); $pb.Size = New-Object Drawing.Size(330, 18)
        $w.Controls.Add($lbl); $w.Controls.Add($pb)
        $script:hpForm = $w
        $script:hpTimer = New-Object Windows.Forms.Timer; $script:hpTimer.Interval = 400
        $script:hpTimer.Add_Tick({ if ($script:hpProc.HasExited) { $script:hpTimer.Stop(); $script:hpForm.Close() } })
        $script:hpTimer.Start()
        [void]$w.ShowDialog($form)
        $script:hpTimer.Dispose()
        try { $script:hpProc.WaitForExit() } catch { }   # ensure output is fully flushed

        $text = ""
        try { $text = ((Get-Content $out -Raw -ErrorAction SilentlyContinue) + "`r`n" + (Get-Content $err -Raw -ErrorAction SilentlyContinue)).Trim() } catch { }
        Remove-Item $out, $err -ErrorAction SilentlyContinue

        if ($successToken) {
            $ok = [bool]($text -match [regex]::Escape($successToken))
            $text = ($text -replace [regex]::Escape($successToken), "").Trim()
        }
        else {
            $ok = $false; try { $ok = ($script:hpProc.ExitCode -eq 0) } catch { }
        }
        return [pscustomobject]@{ Ok = $ok; Output = $text }
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
    $title.Location = New-Object Drawing.Point(20, 12); $title.AutoSize = $true
    $form.Controls.Add($title)

    $sub = New-Object Windows.Forms.Label
    $sub.Text = "Connect your notes to Claude in a few clicks."
    $sub.Location = New-Object Drawing.Point(22, 44); $sub.Size = New-Object Drawing.Size(450, 20)
    $sub.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($sub)

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

    $btnSetup = New-Object Windows.Forms.Button
    $btnSetup.Text = "Step 2  -  Choose my notes folder and set up"
    $btnSetup.Location = New-Object Drawing.Point(20, 150); $btnSetup.Size = New-Object Drawing.Size(450, 42)
    $btnSetup.Font = New-Object Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($btnSetup)

    $btnWeb = New-Object Windows.Forms.Button
    $btnWeb.Text = "Step 3  -  Set up my web link (phone and web)"
    $btnWeb.Location = New-Object Drawing.Point(20, 200); $btnWeb.Size = New-Object Drawing.Size(450, 42)
    $btnWeb.Font = New-Object Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($btnWeb)
    $lblWeb = New-Object Windows.Forms.Label
    $lblWeb.Location = New-Object Drawing.Point(22, 244); $lblWeb.Size = New-Object Drawing.Size(450, 16)
    $lblWeb.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($lblWeb)

    $btnStart = New-Object Windows.Forms.Button
    $btnStart.Text = "Step 4  -  Start"
    $btnStart.Location = New-Object Drawing.Point(20, 268); $btnStart.Size = New-Object Drawing.Size(220, 42)
    $btnStart.Font = New-Object Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($btnStart)
    $btnStop = New-Object Windows.Forms.Button
    $btnStop.Text = "Stop"
    $btnStop.Location = New-Object Drawing.Point(250, 268); $btnStop.Size = New-Object Drawing.Size(220, 42)
    $form.Controls.Add($btnStop)

    $g3 = New-Object Windows.Forms.GroupBox
    $g3.Text = "Step 5  -  Add this to Claude"
    $g3.Location = New-Object Drawing.Point(20, 318); $g3.Size = New-Object Drawing.Size(450, 100)
    $form.Controls.Add($g3)
    $lblConn = New-Object Windows.Forms.Label
    $lblConn.Location = New-Object Drawing.Point(14, 22); $lblConn.Size = New-Object Drawing.Size(424, 46)
    $lblConn.Font = New-Object Drawing.Font("Consolas", 9)
    $g3.Controls.Add($lblConn)
    $btnCopy = New-Object Windows.Forms.Button
    $btnCopy.Text = "Copy link + password"
    $btnCopy.Location = New-Object Drawing.Point(14, 70); $btnCopy.Size = New-Object Drawing.Size(200, 26)
    $g3.Controls.Add($btnCopy)

    $lblStatus = New-Object Windows.Forms.Label
    $lblStatus.Location = New-Object Drawing.Point(22, 426); $lblStatus.Size = New-Object Drawing.Size(300, 34)
    $lblStatus.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($lblStatus)

    $chkAuto = New-Object Windows.Forms.CheckBox
    $chkAuto.Text = "Start automatically when I turn on my PC"
    $chkAuto.Location = New-Object Drawing.Point(22, 464); $chkAuto.Size = New-Object Drawing.Size(325, 24)
    $form.Controls.Add($chkAuto)
    $script:autoBusy = $false

    $btnUninstall = New-Object Windows.Forms.Button
    $btnUninstall.Text = "Uninstall"
    $btnUninstall.Location = New-Object Drawing.Point(355, 460); $btnUninstall.Size = New-Object Drawing.Size(115, 28)
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
        $btnStart.Enabled = ($configured -and $installed -and -not $running)
        $btnStop.Enabled = $running

        if (-not $configured) { $lblWeb.Text = "" }
        elseif ($pub) { $lblWeb.Text = "Web link ready - works on your phone and claude.ai."; $lblWeb.ForeColor = [Drawing.Color]::SeaGreen }
        else { $lblWeb.Text = "Installs Tailscale (free) and signs you in once. Recommended."; $lblWeb.ForeColor = [Drawing.Color]::DimGray }

        if (-not $configured) { $lblConn.Text = "(finish Step 2 first)"; $btnCopy.Enabled = $false }
        elseif (-not $pub) { $lblConn.Text = "Do Step 3 to create your web link -`r`nit appears here with your password."; $btnCopy.Enabled = $false }
        else {
            $pass = Get-EnvVal "VAULT_OAUTH_PASSWORD"
            $lblConn.Text = "Link:      $pub`r`nUsername:  obsidian`r`nPassword:  $pass"
            $btnCopy.Enabled = $true
        }
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
                Start-Process "https://www.python.org/downloads/"; Refresh-UI
            }
        })

    $btnSetup.Add_Click({
            $folder = Pick-Folder "Choose your notes folder (your Obsidian vault)"
            if (-not $folder) { return }
            $r = Invoke-Hidden (Join-Path $scripts "setup.ps1") @("-Force", "-VaultPath", "`"$folder`"") "Setting up - installing components.`r`nThis takes about a minute. Please wait..." "SB_SETUP_SUCCESS"
            Refresh-UI
            if ($r.Ok) { Info("Setup complete! Now do Step 3 - set up your web link.") }
            else { Info("Setup couldn't finish. This is often a temporary internet issue - please try again.`n`nLast details:`n" + (Tail $r.Output)) }
        })

    $btnWeb.Add_Click({
            $ts = Find-Tailscale
            if (-not $ts) {
                if (Have-Winget) {
                    Info("Installing Tailscale (free) so you can reach it from anywhere. Windows will ask for permission - click Yes, and let the window finish.")
                    Start-Process winget -ArgumentList "install", "-e", "--id", "Tailscale.Tailscale", "--accept-source-agreements", "--accept-package-agreements" -Wait
                    Refresh-Path; $ts = Find-Tailscale
                }
                if (-not $ts) {
                    Info("Opening the Tailscale download page. Install it, then come back and click Step 3 again.")
                    Start-Process "https://tailscale.com/download"; return
                }
            }
            $tsDir = Split-Path -Parent $ts
            if (";$env:Path;" -notlike "*;$tsDir;*") { $env:Path = "$tsDir;$env:Path" }
            $r = Invoke-Hidden (Join-Path $scripts "connect.ps1") @("-Mode", "tailscale") "Setting up your web link...`r`nIf a browser opens, sign in to Tailscale, then come back." "SB_WEBLINK_SUCCESS"
            Refresh-UI
            if ($r.Ok) {
                $pub = Get-EnvVal "VAULT_MCP_PUBLIC_URL"
                Info("Your web link is ready:`n`n$pub`n`nNow click Step 4 - Start.")
            }
            else {
                Info("Couldn't finish the web link - please try again.`n`nLast details:`n" + (Tail $r.Output))
            }
        })

    $btnStart.Add_Click({
            Run-Hidden (Join-Path $root "run.ps1") @()
            Start-Sleep -Seconds 3
            Refresh-UI
            if (Test-Running) { Info("Server is ON (running quietly in the background). Now do Step 5 - copy the link into Claude.") }
            else { Info("It didn't start. Make sure Step 2 finished, then click Start again.") }
        })
    $btnStop.Add_Click({ Invoke-Hidden (Join-Path $scripts "stop.ps1") @("-Quiet") "Stopping the server..." | Out-Null; Refresh-UI })

    $btnCopy.Add_Click({
            $pub = Get-EnvVal "VAULT_MCP_PUBLIC_URL"
            if (-not $pub) { Info("Do Step 3 first to create your web link."); return }
            $pass = Get-EnvVal "VAULT_OAUTH_PASSWORD"
            [System.Windows.Forms.Clipboard]::SetText("Link: $pub`r`nUsername: obsidian`r`nPassword: $pass")
            Info("Copied. In Claude: Settings -> Connectors -> Add custom connector, paste the Link, then sign in with the username and password.")
        })

    $btnUninstall.Add_Click({
            $r = [System.Windows.Forms.MessageBox]::Show("Remove the install? Your notes are NOT touched.", "Uninstall", "YesNo")
            if ($r -eq "Yes") { Invoke-Hidden (Join-Path $scripts "uninstall.ps1") @("-Yes") "Removing the install..." | Out-Null; Refresh-UI }
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
