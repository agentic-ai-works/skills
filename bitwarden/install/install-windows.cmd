@echo off
rem Double-click launcher for the Windows installer (see install-windows.ps1).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-windows.ps1" %*
