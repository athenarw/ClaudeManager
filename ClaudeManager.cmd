@echo off
rem Double-click to open ClaudeManager (no console window, no install needed).
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ClaudeManager.ps1"
