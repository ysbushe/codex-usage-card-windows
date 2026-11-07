@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage-shortcut.ps1" install
pause
