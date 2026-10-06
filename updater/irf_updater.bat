@echo off
rem Chrome can't launch a .py file directly on Windows, so it launches this.
rem Anything Python prints to stderr (including "not found" errors) is kept
rem in updater.log, next to this file. Pass --test to try an update by hand.
set "LOG=%~dp0updater.log"
where py >nul 2>nul
if %errorlevel%==0 (
  >>"%LOG%" echo %date% %time%  launching: py -3
  py -3 "%~dp0irf_updater.py" %* 2>>"%LOG%"
) else (
  >>"%LOG%" echo %date% %time%  launching: python ^(no py launcher found^)
  python "%~dp0irf_updater.py" %* 2>>"%LOG%"
)
set "RC=%errorlevel%"
>>"%LOG%" echo %date% %time%  exit code %RC%
exit /b %RC%
