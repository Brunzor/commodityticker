@echo off
rem Dry run: prints the Discord message CommodityTicker would send. Sends nothing.
where py >nul 2>nul
if %errorlevel%==0 (py -3 "%~dp0update_feed.py" --discord --dry-run %*) else (python "%~dp0update_feed.py" --discord --dry-run %*)
pause
