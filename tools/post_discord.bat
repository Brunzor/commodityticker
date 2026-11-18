@echo off
rem Post (or edit) the CommodityTicker Discord message from the Feed.lua already on disk. No fetch. Add --lists both to change lists.
where py >nul 2>nul
if %errorlevel%==0 (py -3 "%~dp0update_feed.py" --discord %*) else (python "%~dp0update_feed.py" --discord %*)
pause
