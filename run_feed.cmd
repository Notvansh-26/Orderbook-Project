@echo off
rem Launch the live feed pipeline through cmd.exe, whose pipes pass raw
rem bytes between processes. PowerShell 5.1 pipes re-encode text and inject
rem a UTF-8 BOM, which corrupts the stream protocol -- don't pipe these
rem two programs together directly in PowerShell.
rem
rem Usage: run_feed [symbol] [logfile]   (default btcusdt; Ctrl+C to stop)
rem        run_feed btcusdt quotes.csv   records top-of-book changes to CSV

setlocal
set SYMBOL=%1
if "%SYMBOL%"=="" set SYMBOL=btcusdt
if "%2"=="" (
    python "%~dp0feed\binance_feed.py" %SYMBOL% | "%~dp0feed_consumer.exe"
) else (
    python "%~dp0feed\binance_feed.py" %SYMBOL% | "%~dp0feed_consumer.exe" --log %2
)
