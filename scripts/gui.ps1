# Second Brain - Control Center (WPF). Lightweight, no install.
# Two-column layout: setup steps on the left, server/connector/activity on the
# right. State-aware with a live Activity log; heavy work runs in child
# processes so the UI can never freeze.

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

    # Full activity/error log to a file, for debugging.
    $script:logDir = Join-Path $root "logs"
    try { if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null } } catch { }
    $script:logFile = Join-Path $script:logDir ("app-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")

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
    function Find-TailscaleGui {
        $ts = Find-Tailscale; if (-not $ts) { return $null }
        $g = Join-Path (Split-Path $ts) "tailscale-ipn.exe"; if (Test-Path $g) { return $g }
        return $null
    }
    function Refresh-Path { $m = [Environment]::GetEnvironmentVariable("Path", "Machine"); $u = [Environment]::GetEnvironmentVariable("Path", "User"); $env:Path = (@($m, $u) | Where-Object { $_ }) -join ";" }
    function Info($m, $t = "Second Brain") { [void][System.Windows.MessageBox]::Show($m, $t) }
    function Confirm($m, $t = "Second Brain") { [System.Windows.MessageBox]::Show($m, $t, "YesNo") -eq "Yes" }
    function Test-Health([string]$baseUrl) {
        if (-not $baseUrl) { return $false }
        try { $r = Invoke-WebRequest -Uri ($baseUrl.TrimEnd("/") + "/health") -TimeoutSec 4 -UseBasicParsing; return ($r.StatusCode -eq 200) } catch { return $false }
    }

    # Run a CLI and capture stdout with a HARD timeout (async reads avoid pipe
    # deadlock; the process is killed on timeout). Returns $null on failure -
    # bounded blocking, so a wedged tool can stall the UI a few seconds at most.
    function Invoke-CliCapture([string]$exe, [string]$argStr, [int]$ms = 4000) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exe; $psi.Arguments = $argStr
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $to = $p.StandardOutput.ReadToEndAsync(); $te = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit($ms)) { try { $p.Kill() } catch { }; return $null }
            return ($to.Result + "`n" + $te.Result)
        }
        catch { return $null }
    }

    function Ts-State {
        $s = @{ Installed = $false; LoggedIn = $false; Dns = ""; FunnelOn = $false }
        $ts = Find-Tailscale; if (-not $ts) { return $s }
        $s.Installed = $true
        $j = Invoke-CliCapture $ts "status --json" 4000
        if ($j) { try { $o = $j | ConvertFrom-Json; $s.Dns = ([string]$o.Self.DNSName).TrimEnd("."); $s.LoggedIn = ($o.BackendState -eq "Running") } catch { } }
        $f = Invoke-CliCapture $ts "funnel status" 4000
        if ($f -and ($f -match "https://")) { $s.FunnelOn = $true }
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

    function Show-Wait([string]$text, [scriptblock]$doneCheck) {
        $w = New-Object System.Windows.Window
        $w.Title = "Working..."; $w.Width = 400; $w.Height = 155; $w.WindowStartupLocation = "CenterOwner"
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

    # Run a script hidden behind the wait window; success = printed marker.
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

    # Run any exe in the BACKGROUND behind the wait bar, with a hard timeout.
    function Run-CliBg([string]$exe, [string[]]$a, [string]$workText, [int]$timeoutSec) {
        $o = [System.IO.Path]::GetTempFileName(); $e = [System.IO.Path]::GetTempFileName()
        try { $script:bgp = Start-Process $exe -ArgumentList $a -WindowStyle Hidden -PassThru -RedirectStandardOutput $o -RedirectStandardError $e }
        catch { return @{ Code = -1; Output = $_.Exception.Message; TimedOut = $false } }
        $script:bgDeadline = (Get-Date).AddSeconds($timeoutSec)
        Show-Wait $workText { $script:bgp.HasExited -or ((Get-Date) -gt $script:bgDeadline) }
        $timedOut = $false
        if (-not $script:bgp.HasExited) { $timedOut = $true; try { Stop-Process -Id $script:bgp.Id -Force } catch { } }
        Start-Sleep -Milliseconds 200
        $t = ""; try { $t = ((Get-Content $o -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content $e -Raw -ErrorAction SilentlyContinue)).Trim() } catch { }
        Remove-Item $o, $e -ErrorAction SilentlyContinue
        @{ Code = $(try { $script:bgp.ExitCode } catch { -1 }); Output = $t; TimedOut = $timedOut }
    }

    function Show-ConnectorHelp {
        $h = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Add the connector" Height="540" Width="470" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="White" FontFamily="Segoe UI">
  <ScrollViewer Padding="22" VerticalScrollBarVisibility="Auto"><StackPanel>
    <TextBlock Text="Add the connector" FontSize="19" FontWeight="Bold" Foreground="#111827" Margin="0,0,0,10"/>
    <TextBlock TextWrapping="Wrap" Foreground="#374151" Margin="0,0,0,16">Use the Link from the app to connect your Second Brain to Claude or ChatGPT.</TextBlock>
    <TextBlock Text="Claude  (paid plan)" FontSize="14" FontWeight="Bold" Foreground="#4F46E5" Margin="0,0,0,6"/>
    <TextBlock TextWrapping="Wrap" Foreground="#111827" Margin="0,0,0,16">1.  Settings  -&gt;  Connectors  -&gt;  Add custom connector<LineBreak/>2.  Paste the Link (use the Copy button)<LineBreak/>3.  Click Add / Connect</TextBlock>
    <TextBlock Text="ChatGPT" FontSize="14" FontWeight="Bold" Foreground="#4F46E5" Margin="0,0,0,6"/>
    <TextBlock TextWrapping="Wrap" Foreground="#111827" Margin="0,0,0,16">1.  Settings  -&gt;  Connectors  -&gt;  turn on Developer mode<LineBreak/>2.  Add the same Link</TextBlock>
    <Border Background="#FEF2F2" BorderBrush="#FCA5A5" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,16"><StackPanel>
      <TextBlock Text="Important - about the password" FontWeight="Bold" Foreground="#991B1B" Margin="0,0,0,6"/>
      <TextBlock TextWrapping="Wrap" Foreground="#7F1D1D">Do NOT type your username or password into the Claude / ChatGPT form. After you add the Link, a separate sign-in window pops up - enter the username (obsidian) and the password THERE.</TextBlock>
    </StackPanel></Border>
    <TextBlock TextWrapping="Wrap" Foreground="#6B7280" FontSize="12">After adding, it can take a minute or two for the tools to appear (the web link is still warming up). If it says "no tools available", wait a moment and refresh / re-open the connector.</TextBlock>
    <Button x:Name="btnOk" Content="Got it" HorizontalAlignment="Right" Margin="0,18,0,0"/>
  </StackPanel></ScrollViewer>
</Window>
'@
        try {
            [xml]$hx = $h
            $wd = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $hx))
            try { $wd.Owner = $script:win } catch { }
            $wd.FindName("btnOk").Add_Click({ $wd.Close() }.GetNewClosure())
            [void]$wd.ShowDialog()
        }
        catch { Info("In Claude/ChatGPT, add a custom connector with the Link. When a sign-in window pops up, enter username 'obsidian' and the password there - do NOT type them into the connector form.") }
    }

    # ---------- UI ----------
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Second Brain - Control Center" Height="680" Width="960"
        MinHeight="620" MinWidth="900"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip"
        Background="#F3F4F6" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#4F46E5"/><Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="16,8"/>
      <Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.88"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#E5E7EB"/><Setter Property="Foreground" Value="#111827"/><Setter Property="Padding" Value="13,6"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/><Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18"/><Setter Property="Margin" Value="0,0,0,14"/>
      <Setter Property="BorderBrush" Value="#E5E7EB"/><Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="H" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#111827"/><Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="Dot" TargetType="TextBlock">
      <Setter Property="Text" Value="&#9679;"/><Setter Property="FontSize" Value="10"/>
      <Setter Property="Margin" Value="0,0,8,0"/><Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Foreground" Value="#9CA3AF"/>
    </Style>
  </Window.Resources>
  <Grid Margin="22,18,22,14">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

    <!-- header -->
    <DockPanel Grid.Row="0" Margin="0,0,0,16">
      <StackPanel>
        <TextBlock Text="Second Brain" FontSize="23" FontWeight="Bold" Foreground="#111827"/>
        <TextBlock Text="Connect your notes to Claude - everything stays on your computer." FontSize="12" Foreground="#6B7280" Margin="1,2,0,0"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" HorizontalAlignment="Right" VerticalAlignment="Center">
        <Button x:Name="btnUpdate" Content="Update" Style="{StaticResource Ghost}" Margin="0,0,8,0"/>
        <Button x:Name="btnRefresh" Content="Refresh" Style="{StaticResource Ghost}" Margin="0,0,12,0"/>
        <Border x:Name="pillBorder" Background="#FEE2E2" CornerRadius="14" Padding="14,7">
          <TextBlock x:Name="txtServerPill" Text="Server: stopped" Foreground="#991B1B" FontSize="12" FontWeight="SemiBold"/></Border>
      </StackPanel>
    </DockPanel>

    <!-- content: two columns -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <!-- LEFT: setup -->
      <StackPanel Grid.Column="0">
        <Border Style="{StaticResource Card}"><StackPanel>
          <TextBlock Style="{StaticResource H}" Text="1.  What you need"/>
          <DockPanel>
            <TextBlock x:Name="dotPy" Style="{StaticResource Dot}"/>
            <TextBlock x:Name="txtPy" Text="Python: checking..." VerticalAlignment="Center"/>
            <Button x:Name="btnPy" Content="Install for me" DockPanel.Dock="Right" HorizontalAlignment="Right"/>
          </DockPanel>
        </StackPanel></Border>

        <Border Style="{StaticResource Card}"><StackPanel>
          <TextBlock Style="{StaticResource H}" Text="2.  Your notes folder"/>
          <DockPanel>
            <TextBlock x:Name="dotVault" Style="{StaticResource Dot}"/>
            <TextBlock x:Name="txtVault" Text="Not set up yet" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            <Button x:Name="btnSetup" Content="Set up" DockPanel.Dock="Right" HorizontalAlignment="Right"/>
          </DockPanel>
          <TextBlock Text="This is the folder Claude will read and write (your Obsidian vault)." FontSize="11" Foreground="#9CA3AF" Margin="18,8,0,0"/>
        </StackPanel></Border>

        <Border Style="{StaticResource Card}"><StackPanel>
          <TextBlock Style="{StaticResource H}" Text="3.  Connect your Second Brain"/>
          <DockPanel Margin="0,0,0,10">
            <TextBlock x:Name="dotTsInst" Style="{StaticResource Dot}"/>
            <TextBlock x:Name="txtTsInst" Text="Tailscale app: ..." VerticalAlignment="Center"/>
            <Button x:Name="btnTsInst" Content="Install" Style="{StaticResource Ghost}" DockPanel.Dock="Right" HorizontalAlignment="Right"/>
          </DockPanel>
          <DockPanel Margin="0,0,0,4">
            <TextBlock x:Name="dotTsConn" Style="{StaticResource Dot}"/>
            <TextBlock x:Name="txtTsLogin" Text="Connection: ..." VerticalAlignment="Center"/>
            <Button x:Name="btnTsLogin" Content="Connect" Style="{StaticResource Ghost}" DockPanel.Dock="Right" HorizontalAlignment="Right"/>
          </DockPanel>
          <TextBlock x:Name="fbLogin" Margin="18,0,0,10" Visibility="Collapsed" FontSize="12"><Hyperlink x:Name="hlLogin">Still not connected? Click here to open the Tailscale app</Hyperlink></TextBlock>
          <DockPanel Margin="0,0,0,4">
            <TextBlock x:Name="dotTsLink" Style="{StaticResource Dot}"/>
            <TextBlock x:Name="txtTsFunnel" Text="Web link: ..." VerticalAlignment="Center"/>
            <Button x:Name="btnTsFunnel" Content="Turn on" Style="{StaticResource Ghost}" DockPanel.Dock="Right" HorizontalAlignment="Right"/>
          </DockPanel>
          <TextBlock x:Name="fbFunnel" Margin="18,0,0,0" Visibility="Collapsed" FontSize="12"><Hyperlink x:Name="hlFunnel">Asked to enable Funnel? Click here, then Turn on again</Hyperlink></TextBlock>
          <TextBlock Text="Creates a private web link so Claude on your phone and claude.ai can reach this computer." FontSize="11" Foreground="#9CA3AF" Margin="18,8,0,0"/>
        </StackPanel></Border>
      </StackPanel>

      <!-- RIGHT: server + connector + activity -->
      <Grid Grid.Column="2">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>

        <Border Grid.Row="0" Style="{StaticResource Card}"><StackPanel>
          <TextBlock Style="{StaticResource H}" Text="4.  Server"/>
          <DockPanel>
            <TextBlock x:Name="dotSrv" Style="{StaticResource Dot}"/>
            <TextBlock x:Name="txtSrv" Text="Stopped" VerticalAlignment="Center"/>
            <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" HorizontalAlignment="Right">
              <Button x:Name="btnStart" Content="Start" Margin="0,0,8,0"/>
              <Button x:Name="btnRestart" Content="Restart" Style="{StaticResource Ghost}" Margin="0,0,8,0"/>
              <Button x:Name="btnStop" Content="Stop" Style="{StaticResource Ghost}"/>
            </StackPanel>
          </DockPanel>
        </StackPanel></Border>

        <Border Grid.Row="1" Style="{StaticResource Card}"><StackPanel>
          <DockPanel Margin="0,0,0,14">
            <TextBlock Text="5.  Add connector (Claude / ChatGPT)" FontSize="14" FontWeight="SemiBold" Foreground="#111827" VerticalAlignment="Center"/>
            <Button x:Name="btnConnInfo" Content="How do I add it?" DockPanel.Dock="Right" HorizontalAlignment="Right" Padding="13,5"/>
          </DockPanel>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="84"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="34"/><RowDefinition Height="34"/><RowDefinition Height="34"/></Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Grid.Column="0" Text="Link" VerticalAlignment="Center" Foreground="#6B7280"/>
            <TextBlock Grid.Row="0" Grid.Column="1" VerticalAlignment="Center" Margin="0,0,10,0" TextTrimming="CharacterEllipsis"><Hyperlink x:Name="hlUrl"><Run x:Name="runUrl" Text="(do step 3)"/></Hyperlink></TextBlock>
            <Button Grid.Row="0" Grid.Column="2" x:Name="btnCopyLink" Content="Copy" Style="{StaticResource Ghost}" Margin="0,4" MinWidth="72"/>
            <TextBlock Grid.Row="1" Grid.Column="0" Text="Username" VerticalAlignment="Center" Foreground="#6B7280"/>
            <TextBlock Grid.Row="1" Grid.Column="1" x:Name="txtUser" Text="obsidian" VerticalAlignment="Center" FontFamily="Consolas"/>
            <Button Grid.Row="1" Grid.Column="2" x:Name="btnCopyUser" Content="Copy" Style="{StaticResource Ghost}" Margin="0,4" MinWidth="72"/>
            <TextBlock Grid.Row="2" Grid.Column="0" Text="Password" VerticalAlignment="Center" Foreground="#6B7280"/>
            <TextBlock Grid.Row="2" Grid.Column="1" x:Name="txtPass" Text="-" VerticalAlignment="Center" FontFamily="Consolas"/>
            <Button Grid.Row="2" Grid.Column="2" x:Name="btnCopyPass" Content="Copy" Style="{StaticResource Ghost}" Margin="0,4" MinWidth="72"/>
          </Grid>
          <Separator Margin="0,12,0,10" Background="#E5E7EB"/>
          <TextBlock x:Name="txtReach" Text="Start the server, then Test before adding the connector." FontSize="12" Foreground="#6B7280" TextWrapping="Wrap" Margin="0,0,0,10"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnTest" Content="Test connection" Style="{StaticResource Ghost}" MinWidth="130" Margin="0,0,8,0"/>
            <Button x:Name="btnFixConn" Content="Fix connection" Style="{StaticResource Ghost}" MinWidth="120"/>
          </StackPanel>
        </StackPanel></Border>

        <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0">
          <DockPanel>
            <TextBlock DockPanel.Dock="Top" Style="{StaticResource H}" Text="Activity"/>
            <TextBox x:Name="logBox" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                     FontFamily="Consolas" FontSize="11" Background="#F9FAFB" BorderBrush="#E5E7EB"/>
          </DockPanel>
        </Border>
      </Grid>
    </Grid>

    <!-- footer -->
    <DockPanel Grid.Row="2" Margin="2,14,2,0">
      <CheckBox x:Name="chkAuto" Content="Start automatically when I turn on my PC" VerticalAlignment="Center"/>
      <Button x:Name="btnUninstall" Content="Uninstall" Style="{StaticResource Ghost}" DockPanel.Dock="Right" HorizontalAlignment="Right"/>
    </DockPanel>
  </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:win = $win
    try {
        $win.Dispatcher.add_UnhandledException({
                param($s, $ev)
                try { Add-Content -Path $script:logFile -Value ("UNHANDLED " + (Get-Date -Format o) + ": " + $ev.Exception.ToString()) -Encoding utf8 } catch { }
                try { $ev.Handled = $true } catch { }
            })
    }
    catch { }
    $el = { param($n) $win.FindName($n) }

    $btnUpdate = & $el "btnUpdate"; $btnRefresh = & $el "btnRefresh"; $pillBorder = & $el "pillBorder"; $txtServerPill = & $el "txtServerPill"
    $dotPy = & $el "dotPy"; $txtPy = & $el "txtPy"; $btnPy = & $el "btnPy"
    $dotVault = & $el "dotVault"; $txtVault = & $el "txtVault"; $btnSetup = & $el "btnSetup"
    $dotTsInst = & $el "dotTsInst"; $txtTsInst = & $el "txtTsInst"; $btnTsInst = & $el "btnTsInst"
    $dotTsConn = & $el "dotTsConn"; $txtTsLogin = & $el "txtTsLogin"; $btnTsLogin = & $el "btnTsLogin"; $fbLogin = & $el "fbLogin"; $hlLogin = & $el "hlLogin"
    $dotTsLink = & $el "dotTsLink"; $txtTsFunnel = & $el "txtTsFunnel"; $btnTsFunnel = & $el "btnTsFunnel"; $fbFunnel = & $el "fbFunnel"; $hlFunnel = & $el "hlFunnel"
    $dotSrv = & $el "dotSrv"; $txtSrv = & $el "txtSrv"; $btnStart = & $el "btnStart"; $btnRestart = & $el "btnRestart"; $btnStop = & $el "btnStop"
    $btnFixConn = & $el "btnFixConn"; $btnConnInfo = & $el "btnConnInfo"; $hlUrl = & $el "hlUrl"; $runUrl = & $el "runUrl"
    $btnCopyLink = & $el "btnCopyLink"; $txtUser = & $el "txtUser"; $btnCopyUser = & $el "btnCopyUser"; $txtPass = & $el "txtPass"; $btnCopyPass = & $el "btnCopyPass"
    $txtReach = & $el "txtReach"; $btnTest = & $el "btnTest"
    $logBox = & $el "logBox"; $chkAuto = & $el "chkAuto"; $btnUninstall = & $el "btnUninstall"

    $bc = New-Object System.Windows.Media.BrushConverter
    $brGreen = $bc.ConvertFromString("#16A34A"); $brRed = $bc.ConvertFromString("#DC2626")
    $brGray = $bc.ConvertFromString("#9CA3AF"); $brAmber = $bc.ConvertFromString("#D97706")
    $brGreenBg = $bc.ConvertFromString("#DCFCE7"); $brGreenFg = $bc.ConvertFromString("#166534")
    $brRedBg = $bc.ConvertFromString("#FEE2E2"); $brRedFg = $bc.ConvertFromString("#991B1B")

    $script:funnelUrl = $null

    function Log([string]$m) {
        $line = (Get-Date -Format "HH:mm:ss") + "  " + $m
        try { $logBox.AppendText($line + "`r`n"); $logBox.ScrollToEnd() } catch { }
        try { Add-Content -Path $script:logFile -Value $line -Encoding utf8 } catch { }
    }
    function LogFile([string]$m) { try { Add-Content -Path $script:logFile -Value $m -Encoding utf8 } catch { } }
    function Copy-To([string]$s) { try { [System.Windows.Clipboard]::SetText($s) } catch { } }
    function Flash-Copied($btn) {
        try {
            $btn.Content = "Copied!"
            $t = New-Object System.Windows.Threading.DispatcherTimer
            $t.Interval = [TimeSpan]::FromMilliseconds(1200)
            $t.Add_Tick( { $btn.Content = "Copy"; $t.Stop() }.GetNewClosure())
            $t.Start()
        }
        catch { }
    }
    function Restart-Server {
        if (Test-Running) {
            [void](Run-Task (Join-Path $scripts "stop.ps1") @("-Quiet") "Restarting the server..." $null)
            # Wait for the TCP port to actually release before rebinding.
            $freeBy = (Get-Date).AddSeconds(8)
            while ((Test-Running) -and ((Get-Date) -lt $freeBy)) { Start-Sleep -Milliseconds 300 }
        }
        Run-Hidden (Join-Path $root "run.ps1") @()
        $script:srvUrl = "http://127.0.0.1:$(Get-Port)"; $script:srvReady = $false; $script:srvDeadline = (Get-Date).AddSeconds(20)
        Show-Wait "Starting the server..." { if (Test-Health $script:srvUrl) { $script:srvReady = $true }; $script:srvReady -or ((Get-Date) -gt $script:srvDeadline) }
    }

    function Refresh-UI {
        $py = Have-Python; $conf = Test-Configured; $inst = Test-Installed; $run = Test-Running
        $pub = Get-EnvVal "VAULT_MCP_PUBLIC_URL"

        if ($run) { $txtServerPill.Text = "Server: running"; $txtServerPill.Foreground = $brGreenFg; $pillBorder.Background = $brGreenBg }
        else { $txtServerPill.Text = "Server: stopped"; $txtServerPill.Foreground = $brRedFg; $pillBorder.Background = $brRedBg }
        $txtSrv.Text = $(if ($run) { "Running" } else { "Stopped" })
        $dotSrv.Foreground = $(if ($run) { $brGreen } else { $brRed })
        $btnStart.IsEnabled = ($conf -and $inst -and -not $run); $btnRestart.IsEnabled = ($conf -and $inst); $btnStop.IsEnabled = $run

        if ($py) { $txtPy.Text = "Python installed"; $dotPy.Foreground = $brGreen; $btnPy.Visibility = "Collapsed" }
        else { $txtPy.Text = "Python is not installed"; $dotPy.Foreground = $brRed; $btnPy.Visibility = "Visible" }

        $btnSetup.IsEnabled = $py
        if ($conf) { $txtVault.Text = (Get-EnvVal "VAULT_PATH"); $dotVault.Foreground = $brGreen; $btnSetup.Content = "Change" }
        else { $txtVault.Text = "Not set up yet"; $dotVault.Foreground = $brGray; $btnSetup.Content = "Set up" }

        $ts = Ts-State
        if ($ts.Installed) { $txtTsInst.Text = "Tailscale app installed"; $dotTsInst.Foreground = $brGreen; $btnTsInst.Visibility = "Collapsed" }
        else { $txtTsInst.Text = "Tailscale app is not installed"; $dotTsInst.Foreground = $brRed; $btnTsInst.Visibility = "Visible" }
        $btnTsLogin.IsEnabled = $ts.Installed
        if ($ts.LoggedIn) { $txtTsLogin.Text = "Connected" + $(if ($ts.Dns) { "  ($($ts.Dns))" } else { "" }); $dotTsConn.Foreground = $brGreen; $btnTsLogin.Visibility = "Collapsed"; $fbLogin.Visibility = "Collapsed" }
        else { $txtTsLogin.Text = "Not connected"; $dotTsConn.Foreground = $(if ($ts.Installed) { $brAmber } else { $brGray }); $btnTsLogin.Visibility = $(if ($ts.Installed) { "Visible" } else { "Collapsed" }) }
        $btnTsFunnel.IsEnabled = $ts.Installed
        if ($ts.FunnelOn -and $pub) { $txtTsFunnel.Text = "Web link is ON"; $dotTsLink.Foreground = $brGreen; $btnTsFunnel.Visibility = "Collapsed" }
        else { $txtTsFunnel.Text = "Web link is off"; $dotTsLink.Foreground = $(if ($ts.Installed) { $brAmber } else { $brGray }); $btnTsFunnel.Visibility = $(if ($ts.Installed) { "Visible" } else { "Collapsed" }) }

        if ($conf -and $pub) {
            $runUrl.Text = $pub; $txtPass.Text = (Get-EnvVal "VAULT_OAUTH_PASSWORD")
            $btnCopyLink.IsEnabled = $true; $btnCopyPass.IsEnabled = $true
        }
        elseif ($conf) { $runUrl.Text = "(do step 3 to create your link)"; $txtPass.Text = (Get-EnvVal "VAULT_OAUTH_PASSWORD"); $btnCopyLink.IsEnabled = $false; $btnCopyPass.IsEnabled = $true }
        else { $runUrl.Text = "(finish step 2 first)"; $txtPass.Text = "-"; $btnCopyLink.IsEnabled = $false; $btnCopyPass.IsEnabled = $false }
    }

    # ---------- events ----------
    $btnRefresh.Add_Click({ Log "Refreshing status..."; Refresh-UI; Log "Ready." })

    $btnUpdate.Add_Click({
            try {
                if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                    Info("Updating needs Git, which isn't installed. You can download the latest version from the project page instead (opening it now).")
                    Start-Process "https://github.com/MakramElJamal/Second-Brain"; return
                }
                if (-not (Test-Path (Join-Path $root ".git"))) {
                    Info("This copy wasn't installed with Git, so it can't update itself. Download the latest ZIP from the project page (opening now) and replace this folder.")
                    Start-Process "https://github.com/MakramElJamal/Second-Brain"; return
                }
                Log "Checking for updates..."
                $before = (Invoke-CliCapture "git" "-C `"$root`" rev-parse HEAD" 10000)
                $r = Run-CliBg "git" @("-C", "`"$root`"", "pull", "--ff-only", "origin", "main") "Checking for updates..." 90
                LogFile ("UPDATE (timedOut=$($r.TimedOut)):`n" + $r.Output)
                $after = (Invoke-CliCapture "git" "-C `"$root`" rev-parse HEAD" 10000)
                if ($r.Output -match "Already up to date") { Log "You're on the latest version."; Info("You're already on the latest version.") }
                elseif ($before -and $after -and ($before.Trim() -ne $after.Trim())) {
                    Log "Updated to the latest version - restarting the app..."
                    Info("Updated to the latest version! The app will now restart.")
                    Start-Process (Join-Path $root "Install Second Brain.cmd")
                    $win.Close()
                }
                else { Log "Update didn't complete - details saved to the log."; Info("Couldn't update. Details were saved to the log - try again, or download the latest ZIP from the project page.") }
            }
            catch { Log ("Update error: " + $_.Exception.Message); LogFile ("UPDATE EXC: " + $_.Exception.ToString()) }
        })

    $btnPy.Add_Click({
            if (Have-Winget) {
                Log "Installing Python (this can take a couple of minutes)..."
                $r = Run-CliBg "winget" @("install", "-e", "--id", "Python.Python.3.12", "--scope", "user", "--accept-source-agreements", "--accept-package-agreements") "Installing Python for you...`r`nThis can take a couple of minutes." 600
                LogFile ("PYTHON INSTALL (timedOut=$($r.TimedOut)):`n" + $r.Output)
                Refresh-Path
                if (Have-Python) { Log "Python installed."; Info("Python is installed. Continue with step 2.") }
                else { Log "Python didn't finish installing - restarting the app to pick it up..."; Start-Process (Join-Path $root "Install Second Brain.cmd"); $win.Close(); return }
            }
            else { Start-Process "https://www.python.org/downloads/"; Log "Opened the Python download page - install it (tick 'Add to PATH'), then reopen this app." }
            Refresh-UI
        })

    $btnSetup.Add_Click({
            $folder = Pick-Folder "Choose your notes folder (your Obsidian vault)"
            if (-not $folder) { return }
            Log "Setting up your Second Brain at: $folder"
            $r = Run-Task (Join-Path $scripts "setup.ps1") @("-Force", "-VaultPath", "`"$folder`"") "Setting up - installing components.`r`nAbout a minute, please wait..." "SB_SETUP_SUCCESS"
            if ($r.Ok) { Log "Setup complete."; Info("Done. Your Second Brain is set up. Next: step 3 - connect it.") } else { Log "Setup FAILED: $($r.Output)"; Info("Setup couldn't finish - see the Activity log.") }
            Refresh-UI
        })

    $btnTsInst.Add_Click({
            if (-not (Have-Winget)) { Start-Process "https://tailscale.com/download"; Log "Opened the Tailscale download page."; return }
            Log "Installing Tailscale (Windows may ask for permission)..."
            $r = Run-CliBg "winget" @("install", "-e", "--id", "Tailscale.Tailscale", "--accept-source-agreements", "--accept-package-agreements") "Installing Tailscale (free)...`r`nWindows may ask for permission - click Yes." 600
            LogFile ("TS INSTALL (timedOut=$($r.TimedOut)):`n" + $r.Output)
            Refresh-Path
            Log "Tailscale install finished."
            Refresh-UI
        })

    $btnTsLogin.Add_Click({
            try {
                Log "Connecting to Tailscale (opening the app and waiting for it)..."
                $r = Run-CliBg "powershell" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$(Join-Path $scripts 'tailscale.ps1')`"", "-Action", "connect") "Connecting to Tailscale..." 40
                LogFile ("CONNECT (timedOut=$($r.TimedOut)):`n" + $r.Output)
                if ($r.Output -match "TS_CONNECTED") { Log "Tailscale is connected." }
                elseif ($r.Output -match "TS_NOT_FOUND") { Log "Tailscale isn't installed - use the Install button first." }
                else { Log "Tailscale didn't connect. Open 'Tailscale' from the Start menu, make sure it shows Connected, then click Refresh."; $fbLogin.Visibility = "Visible" }
                Refresh-UI
            }
            catch { Log ("Connect error: " + $_.Exception.Message); LogFile ("CONNECT EXC: " + $_.Exception.ToString()) }
        })
    $hlLogin.Add_Click({ $g = Find-TailscaleGui; if ($g) { try { Start-Process $g } catch { } } })

    $btnTsFunnel.Add_Click({
            try {
                if (-not (Test-Configured)) { Log "Finish step 2 first (set up your notes folder), then turn on the web link."; return }
                $port = Get-Port
                Log "Turning on your web link (connecting Tailscale, then Funnel)..."
                $r = Run-CliBg "powershell" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$(Join-Path $scripts 'tailscale.ps1')`"", "-Action", "weblink", "-Port", $port) "Turning on your web link..." 55
                LogFile ("WEBLINK (timedOut=$($r.TimedOut)):`n" + $r.Output)
                if ($r.Output -match "TS_FUNNEL_ON https://(\S+)") {
                    $dns = $matches[1]; Set-EnvVal "VAULT_MCP_PUBLIC_URL" "https://$dns"; Set-EnvVal "VAULT_MCP_ALLOWED_HOSTS" $dns; Log "Web link is ON: https://$dns"
                    if (Test-Running) { Log "Restarting the server so it uses the web link..."; Restart-Server }
                }
                elseif ($r.Output -match "TS_FUNNEL_NEEDS_ENABLE (\S+)") {
                    $u = $matches[1]; $script:funnelUrl = $u; try { Start-Process $u } catch { }; $fbFunnel.Visibility = "Visible"
                    Log "One-time step: approve Funnel on the page that just opened (click 'Enable'), then click Turn on again."
                    Info("Almost there! A Tailscale page opened - click 'Enable' / approve Funnel there (one time only), then come back and click 'Turn on' again.")
                }
                elseif ($r.Output -match "TS_NOT_CONNECTED") { Log "Tailscale isn't connected. Click Connect above (or open Tailscale from the Start menu), then Turn on again." }
                elseif ($r.TimedOut) { Log "It took too long and was stopped (details in the log). Open 'Tailscale' from the Start menu, ensure Connected, then Turn on again." }
                else { Log "Couldn't turn on the web link (details saved to the log). Open Tailscale, ensure it's Connected, then try again." }
                Refresh-UI
            }
            catch { Log ("Web link error: " + $_.Exception.Message); LogFile ("WEBLINK EXC: " + $_.Exception.ToString()) }
        })
    $hlFunnel.Add_Click({ if ($script:funnelUrl) { try { Start-Process $script:funnelUrl } catch { } } })

    $btnStart.Add_Click({
            Log "Starting the server..."
            Run-Hidden (Join-Path $root "run.ps1") @()
            $script:srvUrl = "http://127.0.0.1:$(Get-Port)"; $script:srvReady = $false; $script:srvDeadline = (Get-Date).AddSeconds(20)
            Show-Wait "Starting the server..." { if (Test-Health $script:srvUrl) { $script:srvReady = $true }; $script:srvReady -or ((Get-Date) -gt $script:srvDeadline) }
            Refresh-UI
            if ($script:srvReady) { Log "Server is running and ready." } else { Log "Server isn't responding yet. Wait a few seconds and click Refresh, or check step 2 finished." }
        })
    $btnRestart.Add_Click({ Log "Restarting the server..."; Restart-Server; Refresh-UI; if ($script:srvReady) { Log "Server restarted and ready." } else { Log "Restarted, but not responding yet - wait a few seconds and Refresh." } })
    $btnStop.Add_Click({ Log "Stopping the server..."; [void](Run-Task (Join-Path $scripts "stop.ps1") @("-Quiet") "Stopping the server..." $null); Refresh-UI; Log "Server stopped." })

    $btnFixConn.Add_Click({
            if (-not (Confirm("This clears the saved connector logins and restarts the server, so you can add the connector fresh (fixes 'token exchange failed'). Your notes are NOT affected. Continue?"))) { return }
            try {
                $oc = Get-EnvVal "OAUTH_CLIENTS_PATH"; if (-not $oc) { $oc = ".secrets\oauth_clients.json" }
                $ocPath = if ([System.IO.Path]::IsPathRooted($oc)) { $oc } else { Join-Path $root $oc }
                if (Test-Path $ocPath) { Remove-Item $ocPath -Force -ErrorAction SilentlyContinue; Log "Cleared saved connector logins." } else { Log "No saved connector logins to clear." }
                Restart-Server
                Log "Reset done. In Claude/ChatGPT: REMOVE the old connector, then add it again with the Link."
                Info("Reset complete. Now, in Claude/ChatGPT: remove the old connector, then add it again with the Link. A fresh sign-in window will pop up.")
            }
            catch { Log ("Fix error: " + $_.Exception.Message); LogFile ("FIX EXC: " + $_.Exception.ToString()) }
        })

    $btnConnInfo.Add_Click({ Show-ConnectorHelp })

    $btnTest.Add_Click({
            $pub = Get-EnvVal "VAULT_MCP_PUBLIC_URL"; $u = if ($pub) { $pub } else { "http://127.0.0.1:$(Get-Port)" }
            Log "Testing the connection at $u ..."
            $script:reachUrl = $u; $script:reach = $false; $script:reachDeadline = (Get-Date).AddSeconds(8)
            Show-Wait "Checking the connection..." { if (Test-Health $script:reachUrl) { $script:reach = $true }; $script:reach -or ((Get-Date) -gt $script:reachDeadline) }
            if ($script:reach) { $txtReach.Text = "Reachable - ready to add the connector."; $txtReach.Foreground = $brGreenFg; Log "Connection OK - ready to add the connector." }
            else { $txtReach.Text = "Not reachable yet. If you just turned the web link on, wait ~1-2 min (it warms up), then Test again."; $txtReach.Foreground = $brRedFg; Log "Not reachable yet." }
        })

    $hlUrl.Add_Click({ $u = Get-EnvVal "VAULT_MCP_PUBLIC_URL"; if ($u) { try { Start-Process $u } catch { } } })
    $btnCopyLink.Add_Click({ Copy-To (Get-EnvVal "VAULT_MCP_PUBLIC_URL"); Flash-Copied $btnCopyLink; Log "Copied the link." })
    $btnCopyUser.Add_Click({ Copy-To "obsidian"; Flash-Copied $btnCopyUser; Log "Copied the username." })
    $btnCopyPass.Add_Click({ Copy-To (Get-EnvVal "VAULT_OAUTH_PASSWORD"); Flash-Copied $btnCopyPass; Log "Copied the password." })

    $btnUninstall.Add_Click({ if (Confirm("Remove the install? Your notes are NOT touched.")) { Log "Uninstalling..."; [void](Run-Task (Join-Path $scripts "uninstall.ps1") @("-Yes") "Removing the install..." $null); Refresh-UI; Log "Uninstalled." } })

    $script:autoBusy = $true
    try { $chkAuto.IsChecked = ((& (Join-Path $scripts "autostart.ps1") -Action status) -eq "enabled") } catch { }
    $script:autoBusy = $false
    $chkAuto.Add_Click({
            if ($script:autoBusy) { return }
            try { $act = if ($chkAuto.IsChecked) { "enable" } else { "disable" }; & (Join-Path $scripts "autostart.ps1") -Action $act | Out-Null; Log "Auto-start: $act" } catch { Info("Couldn't change auto-start: $($_.Exception.Message)") }
        })

    Refresh-UI
    Log "Ready. Follow steps 1-3 on the left, then Start the server and add the connector."
    [void]$win.ShowDialog()
}
catch {
    try { Add-Type -AssemblyName PresentationFramework } catch { }
    try { Add-Content -Path $script:logFile -Value ("FATAL: " + $_.Exception.ToString()) -Encoding utf8 } catch { }
    [void][System.Windows.MessageBox]::Show("Sorry, the app couldn't open:`n`n$($_.Exception.Message)", "Second Brain")
}
