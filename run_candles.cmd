@echo off
rem Live candlestick chart window. Spawns the feed pipeline itself
rem (no shell piping involved), so this is safe to run from anywhere.
rem
rem Usage: run_candles [symbol]     (default btcusdt; close window to stop)

setlocal
set SYMBOL=%1
if "%SYMBOL%"=="" set SYMBOL=btcusdt
python "%~dp0research\live_candles.py" %SYMBOL%
