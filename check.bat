@echo off
title Sanitaryware ERP - check
cd /d "%~dp0"
set "FLUTTER_BIN=E:\Apps , Software , 2026\applications\programming\flutter\bin"
set "PATH=%FLUTTER_BIN%;%PATH%"
if exist check_log.txt del check_log.txt

echo [1/3] Generating database code...
echo ---- BUILD_RUNNER ---- >> check_log.txt
call dart run build_runner build >> check_log.txt 2>&1

echo [2/3] Analyzing code...
echo ---- ANALYZE ---- >> check_log.txt
call flutter analyze >> check_log.txt 2>&1

echo [3/3] Running tests...
echo ---- TEST ---- >> check_log.txt
call flutter test >> check_log.txt 2>&1

echo ---- FINISHED ---- >> check_log.txt
type check_log.txt
echo.
echo Saved to check_log.txt - tell Claude it is done.
pause
