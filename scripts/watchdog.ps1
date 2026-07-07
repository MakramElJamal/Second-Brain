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
#   SecondBrainHealPeriodic - safety net, every 15 minutes
#
# Both run scripts\heal.ps1, which tests the web link END-TO-END through
# Tailscale's public relays and reconnects a stale session automatically.
# When the link is healthy the run is a no-op (one cheap HTTPS probe).
#
#   .\scripts\watchdog.ps1 -Action enable
#   .\scripts\watchdog.ps1 -Action disable
#   .\scripts\watchdog.ps1 -Action status     # prints 'enabled' or 'disabled'
[CmdletBinding()]
param([ValidateSet("enable", "disable", "status")][string]$Action = "status")
$ErrorActionPreference = "Stop"
$heal = Join-Path $PSScriptRoot "heal.ps1"
$wakeName = "SecondBrainHealOnWake"
$periodicName = "SecondBrainHealPeriodic"

switch ($Action) {
    "enable" {
        $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$heal`""
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

        # Periodic safety net: every 15 minutes, indefinitely.
        $periodic = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 15)
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
