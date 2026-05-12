@echo off
chcp 65001 > nul
title Synology Drive 自启动检查工具

echo.
echo ============================================================
echo     Synology Drive 开机自启动 - 快速检查工具
echo ============================================================
echo.
echo  本工具会检查:
echo    1. SynologyDrive.exe 是否存在
echo    2. 是否已配置开机自启动 (注册表 / 启动文件夹)
echo    3. 自启动指向的路径是否有效
echo.
echo  如未配置, 会询问您是否要立即启用。
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-autostart.ps1"

echo.
pause
