@echo off
title Sanitaryware ERP - continue setup
cd /d "%~dp0"
set "FLUTTER_BIN=E:\Apps , Software , 2026\applications\programming\flutter\bin"
set "PATH=%FLUTTER_BIN%;%PATH%"

echo.
echo [1/3] Adding the remaining packages...
call flutter pub add flutter_localizations --sdk=flutter
if errorlevel 1 goto fail
call flutter pub add --dev drift_dev build_runner
if errorlevel 1 goto fail

echo.
echo [2/3] Running the first test...
call flutter test
if errorlevel 1 goto fail

echo.
echo [3/3] Starting the app on Windows (first build takes a few minutes)...
call flutter run -d windows
goto end

:fail
echo.
echo *** Something failed. Send the messages above to Claude. ***

:end
echo.
pause
