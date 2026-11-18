@echo off
title CommodityTicker price feed (every 5 min) - leave open
rem Double-click to start the CommodityTicker price feed. It asks Blizzard's auction house API every 5 minutes (Blizzard publishes a new snapshot about once an hour) and only adds a point when a new snapshot appears. Needs tools\blizzard.json (see README). Close this window to stop it.
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (py -3 "%~dp0update_feed.py" --loop --every 5) else (python "%~dp0update_feed.py" --loop --every 5)
pause
