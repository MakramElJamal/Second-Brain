# Second Brain - Control Center (WPF). Lightweight, no install, launched by
# "Install Second Brain.cmd". State-aware: shows what's done and only prompts for
# what's left. Heavy lifting stays in the tested scripts (setup.ps1 etc.).

try {
    # Hide this console window so only the app shows.
    try {
        $sbHide = Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);' -Name H -Namespace SBHide -PassThru
        [void]$sbHide::ShowWindow($sbHide::GetConsoleWindow(), 0)
    }
    catch { }

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms

    $scripts = $PSScriptRoot
    $root = Split-Path -Parent $scripts

    # ---- modern (Explorer-style) folder picker ----
    $script:modernPicker = $false
    try {
        if (-not ("SB.FolderPicker" -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace SB {
  [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] internal class FileOpenDialogRCW { }
  [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  internal interface IFileDialog {
    [PreserveSig] int Show(IntPtr p); void SetFileTypes(); void SetFileTypeIndex(uint i); void GetFileTypeIndex(out uint i);
    void Advise(); void Unadvise(); void SetOptions(uint o); void GetOptions(out uint o);
    void SetDefaultFolder(IntPtr p); void SetFolder(IntPtr p); void GetFolder(out IntPtr p); void GetCurrentSelection(out IntPtr p);
    void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string n); void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string n);
    void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string t); void SetOkButtonLabel(); void SetFileNameLabel();
    void GetResult(out IShellItem i); void AddPlace(); void SetDefaultExtension(); void Close(int hr); void SetClientGuid(); void ClearClientData(); void SetFilter();
  }
  [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  internal interface IShellItem { void BindToHandler(); void GetParent(); void GetDisplayName(uint s, [MarshalAs(UnmanagedType.LPWStr)] out string n); void GetAttributes(); void Compare(); }
  public static class FolderPicker {
    public static string Pick(string title) {
      IFileDialog d = (IFileDialog)new FileOpenDialogRCW(); uint o; d.GetOptions(out o); d.SetOptions(o | 0x20 | 0x40);
      if (!string.IsNullOrEmpty(title)) d.SetTitle(title);
      if (d.Show(IntPtr.Zero) != 0) return null;
      IShellItem it; d.GetResult(out it); string p; it.GetDisplayName(0x80058000, out p); return p;
    }
  }
}
'@
        }
        $script:modernPicker = $true
    }
    catch { $script:modernPicker = $false }

    # ---------- backend helpers ----------
    function Get-EnvVal($key) {
        $f = Join-Path $root ".env"
        if (Test-Path $f) { $l = Get-Content $f | Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -First 1; if ($l) { return ($l -replace "^\s*$key\s*=\s*", "").Trim() } }
        ""
    }
    function Set-EnvVal($key, $val) {
        $f = Join-Path $root ".env"; if (-not (Test-Path $f)) { return }
        $found = $false
        $out = Get-Content $f | ForEach-Object { if ($_ -match "^\s*$key\s*=") { $found = $true; "$key=$val" } else { $_ } }
        if (-not $found) { $out += "$key=$val" }
        Set-Content -Path $f -Value $out -Encoding utf8
    }
    function Get-Port { $p = Get-EnvVal "VAULT_MCP_PORT"; if ($p) { $p } else { "8531" } }
    function Test-Configured { Test-Path (Join-Path $root ".env") }
    function Test-Installed { Test-Path (Join-Path $root ".venv") }
    function Test-Running { try { [bool](Get-NetTCPConnection -LocalPort (Get-Port) -State Listen -ErrorAction SilentlyContinue) } catch { $false } }
    function Have-Python { [bool]((Get-Command python -ErrorAction SilentlyContinue) -or (Get-Command py -ErrorAction SilentlyContinue)) }
    function Have-Winget { [bool](Get-Command winget -ErrorAction SilentlyContinue) }
    function Find-Tailscale {
        $c = Get-Command tailscale -ErrorAction SilentlyContinue; if ($c) { return $c.Source }
        foreach ($p in @("$env:ProgramFiles\Tailscale\tailscale.exe", "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe")) { if ($p -and (Test-Path $p)) { return $p } }
        return $null
    }
    function Refresh-Path { $m = [Environment]::GetEnvironmentVariable("Path", "Machine"); $u = [Environment]::GetEnvironmentVariable("Path", "User"); $env:Path = (@($m, $u) | Where-Object { $_ }) -join ";" }
    function Info($m, $t = "Second Brain") { [void][System.Windows.MessageBox]::Show($m, $t) }
    function Confirm($m, $t = "Second Brain") { [System.Windows.MessageBox]::Show($m, $t, "YesNo") -eq "Yes" }

    function Ts-State {
        $s = @{ Installed = $false; LoggedIn = $false; Dns = ""; FunnelOn = $false; Exe = $null }
        $ts = Find-Tailscale; if (-not $ts) { return $s }
        $s.Installed = $true; $s.Exe = $ts
        try { $j = (& $ts status --json 2>$null | ConvertFrom-Json); if ($j) { $s.Dns = ([string]$j.Self.DNSName).TrimEnd("."); $s.LoggedIn = ($j.BackendState -eq "Running") } } catch { }
        try { $f = ((& $ts funnel status 2>$null) -join "`n"); $s.FunnelOn = ($f -match "https://") } catch { }
        return $s
    }

    function Run-Hidden([string]$file, [string[]]$rest) {
        Start-Process powershell -WindowStyle Hidden -ArgumentList (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$file`"") + $rest)
    }
    function Pick-Folder($title) {
        if ($script:modernPicker) { try { return [SB.FolderPicker]::Pick($title) } catch { } }
        $d = New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description = $title
        if ($d.ShowDialog() -eq "OK") { return $d.SelectedPath } else { return $null }
    }

    # Small modal "please wait" with an indeterminate bar; closes when $doneCheck is true.
    function Show-Wait([string]$text, [scriptblock]$doneCheck) {
        $w = New-Object System.Windows.Window
        $w.Title = "Please wait"; $w.Width = 380; $w.Height = 150; $w.WindowStartupLocation = "CenterOwner"
        try { $w.Owner = $script:win } catch { }
        $w.ResizeMode = "NoResize"; $w.WindowStyle = "ToolWindow"
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = "20"
        $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = $text; $tb.TextWrapping = "Wrap"; $tb.Margin = "0,0,0,16"
        $pb = New-Object System.Windows.Controls.ProgressBar; $pb.IsIndeterminate = $true; $pb.Height = 16
        [void]$sp.Children.Add($tb); [void]$sp.Children.Add($pb); $w.Content = $sp
        $t = New-Object System.Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromMilliseconds(300)
        $t.Add_Tick( { if (& $doneCheck) { $t.Stop(); $w.Close() } }.GetNewClosure())
        $t.Start(); [void]$w.ShowDialog(); $t.Stop()
    }

    # Run a script hidden behind the wait window; success = printed marker (reliable).
    function Run-Task([string]$file, [string[]]$argList, [string]$workText, [string]$marker) {
        $out = [System.IO.Path]::GetTempFileName(); $err = [System.IO.Path]::GetTempFileName()
        $a = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$file`"") + $argList
        $script:tp = Start-Process powershell -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err -ArgumentList $a
        Show-Wait $workText { $script:tp.HasExited }
        try { $script:tp.WaitForExit() } catch { }
        $text = ""; try { $text = ((Get-Content $out -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content $err -Raw -ErrorAction SilentlyContinue)).Trim() } catch { }
        Remove-Item $out, $err -ErrorAction SilentlyContinue
        $ok = if ($marker) { [bool]($text -match [regex]::Escape($marker)) } else { try { $script:tp.ExitCode -eq 0 } catch { $false } }
        if ($marker) { $text = ($text -replace [regex]::Escape($marker), "").Trim() }
        [pscustomobject]@{ Ok = $ok; Output = $text }
    }

    # Run a tailscale command hidden, watch its output for a login.tailscale.com
    # URL, open it in the browser, and return it (for the fallback link).
    function Run-TsCapture([string]$ts, [string[]]$tsArgs, [string]$workText, [string]$urlPattern) {
        $f = [System.IO.Path]::GetTempFileName(); $f2 = [System.IO.Path]::GetTempFileName()
        $script:cp = Start-Process $ts -ArgumentList $tsArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $f -RedirectStandardError $f2
        $script:capUrl = $null
        Show-Wait $workText {
            if (-not $script:capUrl) {
                $c = (Get-Content $f, $f2 -Raw -ErrorAction SilentlyContinue)
                if ($c -and $c -match $urlPattern) { $script:capUrl = $matches[0]; try { Start-Process $script:capUrl } catch { } }
            }
            ($null -ne $script:capUrl) -or $script:cp.HasExited
        }
        Remove-Item $f, $f2 -ErrorAction SilentlyContinue
        $script:capUrl
    }

    # ---------- UI ----------
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Second Brain - Control Center" Height="660" Width="520"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        Background="#F3F4F6" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#4F46E5"/><Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#E5E7EB"/><Setter Property="Foreground" Value="#111827"/><Setter Property="Padding" Value="12,5"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/><Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="16"/><Setter Property="Margin" Value="0,0,0,12"/>
      <Setter Property="BorderBrush" Value="#E5E7EB"/><Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="H" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#111827"/><Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
  </Window.Resources>
  <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="18">
    <StackPanel>
      <DockPanel Margin="0,0,0,14">
        <TextBlock Text="Second Brain" FontSize="22" FontWeight="Bold" Foreground="#111827"/>
        <Border DockPanel.Dock="Right" Background="#FEE2E2" CornerRadius="12" Padding="12,5" HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock x:Name="txtServerPill" Text="Server: stopped" Foreground="#991B1B" FontSize="12"/></Border>
      </DockPanel>

      <Border Style="{StaticResource Card}"><StackPanel>
        <TextBlock Style="{StaticResource H}" Text="1.  What you need"/>
        <DockPanel><TextBlock x:Name="txtPy" Text="Python: checking..." VerticalAlignment="Center"/>
          <Button x:Name="btnPy" Content="Install for me" DockPanel.Dock="Right" HorizontalAlignment="Right"/></DockPanel>
      </StackPanel></Border>

      <Border Style="{StaticResource Card}"><StackPanel>
        <TextBlock Style="{StaticResource H}" Text="2.  Your Second Brain (notes folder)"/>
        <DockPanel><TextBlock x:Name="txtVault" Text="Not set up yet" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
          <Button x:Name="btnSetup" Content="Set up" DockPanel.Dock="Right" HorizontalAlignment="Right"/></DockPanel>
      </StackPanel></Border>

      <Border Style="{StaticResource Card}"><StackPanel>
        <TextBlock Style="{StaticResource H}" Text="3.  Connect your Second Brain (phone &amp; web)"/>
        <DockPanel Margin="0,0,0,9"><TextBlock x:Name="txtTsInst" Text="Tailscale app: ..." VerticalAlignment="Center"/>
          <Button x:Name="btnTsInst" Content="Install" Style="{StaticResource Ghost}" DockPanel.Dock="Right" HorizontalAlignment="Right"/></DockPanel>
        <DockPanel Margin="0,0,0,3"><TextBlock x:Name="txtTsLogin" Text="Signed in: ..." VerticalAlignment="Center"/>
          <Button x:Name="btnTsLogin" Content="Sign in" Style="{StaticResource Ghost}" DockPanel.Dock="Right" HorizontalAlignment="Right"/></DockPanel>
        <TextBlock x:Name="fbLogin" Margin="0,0,0,9" Visibility="Collapsed" FontSize="12"><Hyperlink x:Name="hlLogin">Sign-in page didn't open? Click here</Hyperlink></TextBlock>
        <DockPanel Margin="0,0,0,3"><TextBlock x:Name="txtTsFunnel" Text="Web link: ..." VerticalAlignment="Center"/>
          <Button x:Name="btnTsFunnel" Content="Turn on" Style="{StaticResource Ghost}" DockPanel.Dock="Right" HorizontalAlignment="Right"/></DockPanel>
        <TextBlock x:Name="fbFunnel" Visibility="Collapsed" FontSize="12"><Hyperlink x:Name="hlFunnel">Needs Funnel enabled? Click here, then Turn on again</Hyperlink></TextBlock>
      </StackPanel></Border>

      <Border Style="{StaticResource Card}"><StackPanel>
        <TextBlock Style="{StaticResource H}" Text="4.  Server"/>
        <DockPanel><TextBlock x:Name="txtSrv" Text="Stopped" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" HorizontalAlignment="Right">
            <Button x:Name="btnStart" Content="Start" Margin="0,0,8,0"/><Button x:Name="btnStop" Content="Stop" Style="{StaticResource Ghost}"/></StackPanel></DockPanel>
      </StackPanel></Border>

      <Border Style="{StaticResource Card}"><StackPanel>
        <TextBlock Style="{StaticResource H}" Text="5.  Add to Claude"/>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition Height="30"/><RowDefinition Height="30"/><RowDefinition Height="30"/></Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Grid.Column="0" Text="Link" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="0" Grid.Column="1" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"><Hyperlink x:Name="hlUrl"><Run x:Name="runUrl" Text="(do step 3)"/></Hyperlink></TextBlock>
          <Button Grid.Row="0" Grid.Column="2" x:Name="btnCopyLink" Content="Copy" Style="{StaticResource Ghost}" Margin="6,3"/>
          <TextBlock Grid.Row="1" Grid.Column="0" Text="Username" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="1" Grid.Column="1" x:Name="txtUser" Text="obsidian" VerticalAlignment="Center" FontFamily="Consolas"/>
          <Button Grid.Row="1" Grid.Column="2" x:Name="btnCopyUser" Content="Copy" Style="{StaticResource Ghost}" Margin="6,3"/>
          <TextBlock Grid.Row="2" Grid.Column="0" Text="Password" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="2" Grid.Column="1" x:Name="txtPass" Text="-" VerticalAlignment="Center" FontFamily="Consolas"/>
          <Button Grid.Row="2" Grid.Column="2" x:Name="btnCopyPass" Content="Copy" Style="{StaticResource Ghost}" Margin="6,3"/>
        </Grid>
      </StackPanel></Border>

      <DockPanel Margin="2,2,2,0">
        <CheckBox x:Name="chkAuto" Content="Start automatically when I turn on my PC" VerticalAlignment="Center"/>
        <Button x:Name="btnUninstall" Content="Uninstall" Style="{StaticResource Ghost}" DockPanel.Dock="Right" HorizontalAlignment="Right"/></DockPanel>
    </StackPanel>
  </ScrollViewer>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:win = $win

    # element handles
    $el = {param($n) $win.FindName($n)}
    $txtServerPill = & $el "txtServerPill"
    $txtPy = & $el "txtPy"; $btnPy = & $el "btnPy"
    $txtVault = & $el "txtVault"; $btnSetup = & $el "btnSetup"
    $txtTsInst = & $el "txtTsInst"; $btnTsInst = & $el "btnTsInst"
    $txtTsLogin = & $el "txtTsLogin"; $btnTsLogin = & $el "btnTsLogin"; $fbLogin = & $el "fbLogin"; $hlLogin = & $el "hlLogin"
    $txtTsFunnel = & $el "txtTsFunnel"; $btnTsFunnel = & $el "btnTsFunnel"; $fbFunnel = & $el "fbFunnel"; $hlFunnel = & $el "hlFunnel"
    $txtSrv = & $el "txtSrv"; $btnStart = & $el "btnStart"; $btnStop = & $el "btnStop"
    $hlUrl = & $el "hlUrl"; $runUrl = & $el "runUrl"
    $btnCopyLink = & $el "btnCopyLink"; $txtUser = & $el "txtUser"; $btnCopyUser = & $el "btnCopyUser"; $txtPass = & $el "txtPass"; $btnCopyPass = & $el "btnCopyPass"
    $chkAuto = & $el "chkAuto"; $btnUninstall = & $el "btnUninstall"

    $script:loginUrl = $null; $script:funnelUrl = $null

    function Refresh-UI {
        $py = Have-Python; $conf = Test-Configured; $inst = Test-Installed; $run = Test-Running
        $pub = Get-EnvVal "VAULT_MCP_PUBLIC_URL"

        $txtServerPill.Text = "Server: " + $(if ($run) { "running" } else { "stopped" })
        $txtSrv.Text = $(if ($run) { "Running" } else { "Stopped" })
        $btnStart.IsEnabled = ($conf -and $inst -and -not $run); $btnStop.IsEnabled = $run

        if ($py) { $txtPy.Text = "Python: installed"; $btnPy.Visibility = "Collapsed" } else { $txtPy.Text = "Python: not installed"; $btnPy.Visibility = "Visible" }

        $btnSetup.IsEnabled = $py
        if ($conf) { $vp = Get-EnvVal "VAULT_PATH"; $txtVault.Text = "Folder: $vp"; $btnSetup.Content = "Change" } else { $txtVault.Text = "Not set up yet"; $btnSetup.Content = "Set up" }

        $ts = Ts-State
        if ($ts.Installed) { $txtTsInst.Text = "Tailscale app: installed"; $btnTsInst.Visibility = "Collapsed" } else { $txtTsInst.Text = "Tailscale app: not installed"; $btnTsInst.Visibility = "Visible" }
        $btnTsLogin.IsEnabled = $ts.Installed
        if ($ts.LoggedIn) { $txtTsLogin.Text = "Signed in: yes"; $btnTsLogin.Visibility = "Collapsed" } else { $txtTsLogin.Text = "Signed in: no"; $btnTsLogin.Visibility = $(if ($ts.Installed) { "Visible" } else { "Collapsed" }) }
        $btnTsFunnel.IsEnabled = $ts.LoggedIn
        if ($ts.FunnelOn -and $pub) { $txtTsFunnel.Text = "Web link: on"; $btnTsFunnel.Visibility = "Collapsed" } else { $txtTsFunnel.Text = "Web link: off"; $btnTsFunnel.Visibility = $(if ($ts.LoggedIn) { "Visible" } else { "Collapsed" }) }

        if ($conf -and $pub) {
            $runUrl.Text = $pub; $txtPass.Text = (Get-EnvVal "VAULT_OAUTH_PASSWORD")
            $btnCopyLink.IsEnabled = $true; $btnCopyPass.IsEnabled = $true
        }
        else { $runUrl.Text = "(finish step 3)"; $txtPass.Text = "-"; $btnCopyLink.IsEnabled = $false; $btnCopyPass.IsEnabled = $false }
    }

    function Copy-To([string]$s) { try { [System.Windows.Clipboard]::SetText($s) } catch { } }

    # ---------- events ----------
    $btnPy.Add_Click({
            if (Have-Winget) {
                Start-Process winget -ArgumentList "install", "-e", "--id", "Python.Python.3.12", "--scope", "user", "--accept-source-agreements", "--accept-package-agreements" -Wait
                Refresh-Path
                if (-not (Have-Python)) { Info("Python installed. Please close this app and open it again to continue."); $win.Close(); return }
            }
            else { Start-Process "https://www.python.org/downloads/"; Info("Install Python (tick 'Add to PATH'), then reopen this app.") }
            Refresh-UI
        })

    $btnSetup.Add_Click({
            $folder = Pick-Folder "Choose your notes folder (your Obsidian vault)"
            if (-not $folder) { return }
            $r = Run-Task (Join-Path $scripts "setup.ps1") @("-Force", "-VaultPath", "`"$folder`"") "Setting up - installing components. About a minute, please wait..." "SB_SETUP_SUCCESS"
            Refresh-UI
            if ($r.Ok) { Info("Done. Your Second Brain is set up.") } else { Info("Setup couldn't finish - please try again.`n`n" + $r.Output) }
        })

    $btnTsInst.Add_Click({
            if (-not (Have-Winget)) { Start-Process "https://tailscale.com/download"; Info("Install Tailscale, then come back."); return }
            Start-Process winget -ArgumentList "install", "-e", "--id", "Tailscale.Tailscale", "--accept-source-agreements", "--accept-package-agreements" -Wait
            Refresh-Path; Refresh-UI
        })

    $btnTsLogin.Add_Click({
            $ts = Find-Tailscale; if (-not $ts) { Refresh-UI; return }
            $u = Run-TsCapture $ts @("up") "Opening Tailscale sign-in in your browser..." "https://login\.tailscale\.com/\S+"
            if ($u) { $script:loginUrl = $u; $fbLogin.Visibility = "Visible" }
            Info("Finish signing in in the browser that opened, then this window updates. (If it didn't open, use the 'Click here' link.)")
            Refresh-UI
        })
    $hlLogin.Add_Click({ if ($script:loginUrl) { Start-Process $script:loginUrl } })

    $btnTsFunnel.Add_Click({
            $ts = Find-Tailscale; if (-not $ts) { return }
            $u = Run-TsCapture $ts @("funnel", "--bg", (Get-Port)) "Turning on your web link..." "https://login\.tailscale\.com/f/funnel\S+"
            if ($u) { $script:funnelUrl = $u; $fbFunnel.Visibility = "Visible" }
            $st = Ts-State
            if ($st.Dns) { Set-EnvVal "VAULT_MCP_PUBLIC_URL" "https://$($st.Dns)"; Set-EnvVal "VAULT_MCP_ALLOWED_HOSTS" $st.Dns }
            Refresh-UI
            if ((Get-EnvVal "VAULT_MCP_PUBLIC_URL") -and -not $u) { Info("Your web link is ready. Now Start the server (step 4).") }
        })
    $hlFunnel.Add_Click({ if ($script:funnelUrl) { Start-Process $script:funnelUrl } })

    $btnStart.Add_Click({ Run-Hidden (Join-Path $root "run.ps1") @(); Start-Sleep -Seconds 3; Refresh-UI; if (-not (Test-Running)) { Info("It didn't start. Make sure step 2 finished, then try again.") } })
    $btnStop.Add_Click({ [void](Run-Task (Join-Path $scripts "stop.ps1") @("-Quiet") "Stopping the server..." $null); Refresh-UI })

    $hlUrl.Add_Click({ $u = Get-EnvVal "VAULT_MCP_PUBLIC_URL"; if ($u) { Start-Process $u } })
    $btnCopyLink.Add_Click({ Copy-To (Get-EnvVal "VAULT_MCP_PUBLIC_URL") })
    $btnCopyUser.Add_Click({ Copy-To "obsidian" })
    $btnCopyPass.Add_Click({ Copy-To (Get-EnvVal "VAULT_OAUTH_PASSWORD") })

    $btnUninstall.Add_Click({ if (Confirm("Remove the install? Your notes are NOT touched.")) { [void](Run-Task (Join-Path $scripts "uninstall.ps1") @("-Yes") "Removing the install..." $null); Refresh-UI } })

    $script:autoBusy = $true
    try { $chkAuto.IsChecked = ((& (Join-Path $scripts "autostart.ps1") -Action status) -eq "enabled") } catch { }
    $script:autoBusy = $false
    $chkAuto.Add_Click({
            if ($script:autoBusy) { return }
            try { $act = if ($chkAuto.IsChecked) { "enable" } else { "disable" }; & (Join-Path $scripts "autostart.ps1") -Action $act | Out-Null } catch { Info("Couldn't change auto-start: $($_.Exception.Message)") }
        })

    Refresh-UI
    [void]$win.ShowDialog()
}
catch {
    try { Add-Type -AssemblyName PresentationFramework } catch { }
    [void][System.Windows.MessageBox]::Show("Sorry, the app couldn't open:`n`n$($_.Exception.Message)", "Second Brain")
}
