@echo off
rem Refresh CommodityTicker's Feed.lua once (Python 3 from python.org). Add --loop to repeat every 30 minutes (or --every N, minimum 5). Updates the Discord ticker too if tools\discord.json has a webhook.
where py >nul 2>nul
if %errorlevel%==0 (py -3 "%~dp0update_feed.py"  %*) else (python "%~dp0update_feed.py"  %*)
pause
