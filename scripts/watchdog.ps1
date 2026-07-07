# Auto-reconnect for the web link after sleep/hibernate.
#
# Sleep/hibernate leaves the Tailscale Funnel session stale: everything looks
# fine locally, but the public relays reset every incoming connection -- so
# Claude reports "Couldn't connect" / OAuth errors until the session is
# bounced. This registers two NON-ADMIN scheduled tasks (run as the current
# user, no elevation, removed by 'disable' and by uninstall.ps1):
#
#   SecondBrainHealOnWake   - fires ~1 minute after the PC resumes from
#                             sleep/hibernate (System event: Power-Troubleshooter
#                             id 1, delayed 60s so Wi-Fi can come back first)
#   SecondBrainHealPeriodic - safety net, every 30 minutes
#
# Both run scripts\heal.ps1 via scripts\run-hidden.vbs, which tests the web link
# END-TO-END through Tailscale's public relays and reconnects a stale session
# automatically. When the link is healthy the run is a no-op (one cheap HTTPS
# probe, ~1-2s, a few short-lived processes -- negligible CPU/memory). The VBS
# launcher keeps it fully windowless: launching powershell.exe from Task
# Scheduler flashes a console for a split second even with -WindowStyle Hidden.
#
#   .\scripts\watchdog.ps1 -Action enable
#   .\scripts\watchdog.ps1 -Action disable
#   .\scripts\watchdog.ps1 -Action status     # prints 'enabled' or 'disabled'
[CmdletBinding()]
param([ValidateSet("enable", "disable", "status")][string]$Action = "status")
$ErrorActionPreference = "Stop"
$heal = Join-Path $PSScriptRoot "heal.ps1"
$vbs = Join-Path $PSScriptRoot "run-hidden.vbs"
$wakeName = "SecondBrainHealOnWake"
$periodicName = "SecondBrainHealPeriodic"

switch ($Action) {
    "enable" {
        # Run through wscript + run-hidden.vbs so the background heal never flashes
        # a console window (powershell.exe launched by Task Scheduler does, even
        # hidden). wscript.exe lives in System32 and is on PATH.
        $taskAction = New-ScheduledTaskAction -Execute "wscript.exe" `
            -Argument "`"$vbs`" `"$heal`""
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew

        # Resume-from-sleep trigger. New-ScheduledTaskTrigger can't express event
        # triggers, so build the CIM instance directly (works without admin).
        $class = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
        $wake = New-CimInstance -CimClass $class -ClientOnly
        $wake.Enabled = $true
        $wake.Delay = "PT60S"   # give the network a minute to come back before testing
        $wake.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]</Select></Query></QueryList>'
        Register-ScheduledTask -TaskName $wakeName -Action $taskAction -Trigger $wake -Settings $settings -Force | Out-Null

        # Periodic safety net: every 30 minutes, indefinitely. The wake trigger
        # handles the real case immediately; this only catches anything it misses,
        # so a lighter cadence keeps background churn minimal.
        $periodic = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 30)
        Register-ScheduledTask -TaskName $periodicName -Action $taskAction -Trigger $periodic -Settings $settings -Force | Out-Null

        Write-Output "WATCHDOG_ON"
    }
    "disable" {
        foreach ($n in @($wakeName, $periodicName)) {
            Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
        }
        Write-Output "WATCHDOG_OFF"
    }
    "status" {
        if (Get-ScheduledTask -TaskName $wakeName -ErrorAction SilentlyContinue) { "enabled" } else { "disabled" }
    }
}
