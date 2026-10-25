@echo off
rem Double-click = update + launch. Arguments go to play.ps1 (e.g. play.cmd -Scene missions101).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0play.ps1" %*
if errorlevel 1 pause
