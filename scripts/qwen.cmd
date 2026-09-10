@echo off
if /I "%~1"=="chat" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0qwen_chat.ps1"
    exit /b %ERRORLEVEL%
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0qwen.ps1" %*
exit /b %ERRORLEVEL%
