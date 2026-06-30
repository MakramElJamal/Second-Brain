@echo off
REM ============================================================
REM   DOUBLE-CLICK THIS FILE to set up Second Brain.
REM   A window opens with simple buttons - no typing, no terminal.
REM ============================================================
cd /d "%~dp0"
start "" powershell -NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0scripts\gui.ps1"
