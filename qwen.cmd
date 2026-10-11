@echo off
if /I "%~1"=="chat" goto chat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\qwen.ps1" %*
exit /b %ERRORLEVEL%
:chat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\qwen_chat.ps1"
exit /b %ERRORLEVEL%
