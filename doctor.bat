@echo off
title Flutter doctor
cd /d "%~dp0"
set "FLUTTER_BIN=E:\Apps , Software , 2026\applications\programming\flutter\bin"
set "PATH=%FLUTTER_BIN%;%PATH%"
call flutter doctor -v > doctor_log.txt 2>&1
type doctor_log.txt
echo.
echo Report saved to doctor_log.txt - tell Claude it is done.
pause
