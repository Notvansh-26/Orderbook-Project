@echo off
rem Live terminal ladder view of the order book. See run_feed.cmd for why
rem this must pipe through cmd.exe rather than PowerShell.
rem
rem Usage: run_ladder [symbol]     (default btcusdt; Ctrl+C to stop)

setlocal
set SYMBOL=%1
if "%SYMBOL%"=="" set SYMBOL=btcusdt
python "%~dp0feed\binance_feed.py" %SYMBOL% | "%~dp0ladder.exe"
