@echo off
rem Launch the live feed pipeline through cmd.exe, whose pipes pass raw
rem bytes between processes. PowerShell 5.1 pipes re-encode text and inject
rem a UTF-8 BOM, which corrupts the stream protocol -- don't pipe these
rem two programs together directly in PowerShell.
rem
rem Usage: run_feed [symbol] [quotesfile] [tradesfile] [minutes]
rem        (default btcusdt; Ctrl+C to stop)
rem        run_feed btcusdt quotes.csv               records top-of-book changes
rem        run_feed btcusdt quotes.csv trades.csv    also records aggressor trades
rem        run_feed btcusdt quotes.csv trades.csv 90 timed unattended recording

setlocal
set SYMBOL=%1
if "%SYMBOL%"=="" set SYMBOL=btcusdt
set FLAGS=
if not "%2"=="" set FLAGS=--log %2
if not "%3"=="" set FLAGS=%FLAGS% --trades %3
set FEEDFLAGS=
if not "%4"=="" set FEEDFLAGS=--minutes %4
python "%~dp0feed\binance_feed.py" %SYMBOL% %FEEDFLAGS% | "%~dp0feed_consumer.exe" %FLAGS%
