@echo off
rem Chrome can't launch a .py file directly on Windows, so it launches this.
where py >nul 2>nul && (
  py -3 "%~dp0irf_updater.py"
) || (
  python "%~dp0irf_updater.py"
)
