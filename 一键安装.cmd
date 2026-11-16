@echo off
setlocal
REM Default entry point is read-only. No automatic elevation or security changes.
pushd "%~dp0"
powershell.exe -NoProfile -File "%~dp0Install-SynologyDrive.ps1" -Mode CheckOnly
set "INSTALLER_EXIT=%ERRORLEVEL%"
popd
echo.
echo Check completed with exit code %INSTALLER_EXIT%.
echo Read README.md for DownloadOnly and Install modes.
pause
exit /b %INSTALLER_EXIT%
