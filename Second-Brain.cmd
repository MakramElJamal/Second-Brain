@echo off
REM Double-click this file to open Second Brain MCP. No terminal knowledge needed.
REM It opens a small window with buttons (Set up / Connect / Start / Stop / Uninstall).
REM If the window doesn't appear, it falls back to a simple text menu.

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\gui.ps1"
if %errorlevel% neq 0 (
  echo.
  echo Opening the text menu instead...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\manage.ps1"
)
