@echo off
rem Chrome can't launch a .ps1 file directly on Windows, so it launches this.
rem Anything PowerShell prints to stderr goes to updater-errors.log (a separate
rem file, since the helper writes updater.log itself). Pass --check or --test
rem to try the helper by hand.
set "LOG=%~dp0updater.log"
>>"%LOG%" echo %date% %time%  launching: powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0irf_updater.ps1" %* 2>>"%~dp0updater-errors.log"
set "RC=%errorlevel%"
>>"%LOG%" echo %date% %time%  exit code %RC%
exit /b %RC%
