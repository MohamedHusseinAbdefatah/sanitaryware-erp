@echo off
chcp 65001 >nul
title Sanitaryware ERP - release build
cd /d "%~dp0"
set "FLUTTER_BIN=E:\Apps , Software , 2026\applications\programming\flutter\bin"
set "PATH=%FLUTTER_BIN%;%PATH%"

rem Version from lib\core\version.dart (const appVersion = 'x.y.z';)
for /f "tokens=2 delims='" %%v in ('findstr /c:"appVersion" lib\core\version.dart') do set "APP_VERSION=%%v"
echo Building version %APP_VERSION%

echo.
echo [1/4] Running all tests (the release stops if any fails)...
call flutter test
if errorlevel 1 goto fail

echo.
echo [2/4] Building the release...
call flutter build windows --release
if errorlevel 1 goto fail

echo.
echo [3/4] Copying the Visual C++ runtime next to the program (for clean PCs)...
for %%d in (msvcp140.dll vcruntime140.dll vcruntime140_1.dll) do (
  copy /y "%SystemRoot%\System32\%%d" "build\windows\x64\runner\Release\" >nul
  if errorlevel 1 goto fail
)

echo.
echo [4/4] Making setup.exe with Inno Setup...
set "ISCC="
if exist "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" set "ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if exist "%ProgramFiles%\Inno Setup 6\ISCC.exe" set "ISCC=%ProgramFiles%\Inno Setup 6\ISCC.exe"
if exist "%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe" set "ISCC=%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe"
if "%ISCC%"=="" (
  echo Inno Setup 6 is not installed. Install it from https://jrsoftware.org/isdl.php
  echo and run this file again. The program itself is ready in build\windows\x64\runner\Release
  goto end
)
"%ISCC%" /DAppVersion=%APP_VERSION% installer\sanitaryware_erp.iss
if errorlevel 1 goto fail
echo.
echo Done: dist\SanitarywareERP-Setup-%APP_VERSION%.exe
goto end

:fail
echo.
echo *** Something failed. Nothing was released. Read the messages above. ***

:end
echo.
pause
