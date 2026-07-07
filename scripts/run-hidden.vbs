' Launch a PowerShell script with NO visible window.
'
' Task Scheduler launching powershell.exe directly flashes a console window for
' a fraction of a second even with -WindowStyle Hidden, because the console host
' is allocated before the script can hide it. wscript.exe is a GUI-subsystem
' host (no console of its own), and Run(..., 0, ...) starts the child fully
' hidden -- so the heal tasks run truly invisibly in the background.
'
' Arg 0: full path to the .ps1 to run.
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & WScript.Arguments(0) & """"
sh.Run cmd, 0, False   ' 0 = hidden, False = don't wait
