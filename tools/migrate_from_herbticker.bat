@echo off
rem One-time: copy HerbTicker's saved data and tools settings into CommodityTicker. Run with the game closed.
where py >nul 2>nul
if %errorlevel%==0 (py -3 "%~dp0migrate_from_herbticker.py"  %*) else (python "%~dp0migrate_from_herbticker.py"  %*)
pause
