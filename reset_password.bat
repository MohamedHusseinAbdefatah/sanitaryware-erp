@echo off
chcp 65001 >nul
title Sanitaryware ERP - reset a password
cd /d "%~dp0"
set "FLUTTER_BIN=E:\Apps , Software , 2026\applications\programming\flutter\bin"
set "PATH=%FLUTTER_BIN%;%PATH%"

echo Close the Sanitaryware ERP program before continuing.
echo.
echo Database file (press Enter for this computer's data folder):
set "ERP_DB="
set /p ERP_DB=
set "ERP_USER="
set "ERP_PASSWORD="

echo.
echo Users in the database:
call flutter test tool\admin\reset_password_test.dart --reporter=expanded 2>&1 | findstr /b /c:"USERS:" /c:"No database"
echo.
set /p ERP_USER=Username to reset:
set /p ERP_PASSWORD=New password (at least 4 characters):

echo.
call flutter test tool\admin\reset_password_test.dart --reporter=expanded 2>&1 | findstr /c:"BACKUP:" /c:"DONE:" /c:"No user" /c:"at least" /c:"Some tests failed"
echo.
pause
