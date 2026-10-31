@echo off
chcp 65001 >nul
setlocal

rem === Flutter SDK location (drive E) ===
set "FLUTTER_BIN=E:\Apps , Software , 2026\applications\programming\flutter\bin"
set "PATH=%FLUTTER_BIN%;%PATH%"

cd /d "%~dp0"

echo.
echo [1/5] Creating the Flutter Windows project...
call flutter create --platforms=windows --org com.erp --project-name sanitaryware_erp .
if errorlevel 1 goto fail

echo.
echo [2/5] Copying the starter files (RTL app, sidebar, Arabic strings)...
xcopy "_starter" "." /E /Y /I /Q
if errorlevel 1 goto fail

echo.
echo [3/5] Adding packages...
call flutter pub add flutter_riverpod go_router window_manager intl drift sqlite3_flutter_libs path_provider path pdf printing excel crypto archive file_picker
if errorlevel 1 goto fail
call flutter pub add flutter_localizations --sdk=flutter
if errorlevel 1 goto fail
call flutter pub add --dev drift_dev build_runner
if errorlevel 1 goto fail

echo.
echo [4/5] Running the first test...
call flutter test
if errorlevel 1 goto fail

echo.
echo [5/5] Done. Starting the app on Windows (first build takes a few minutes)...
call flutter run -d windows
goto end

:fail
echo.
echo *** Something failed. Copy the messages above and send them to Claude. ***

:end
echo.
pause
endlocal
