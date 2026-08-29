@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0qwen.ps1" %*
exit /b %ERRORLEVEL%