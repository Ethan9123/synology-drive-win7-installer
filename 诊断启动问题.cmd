@echo off
chcp 65001 > nul
title Synology Drive 启动失败诊断

echo.
echo ============================================================
echo     Synology Drive 启动失败诊断工具
echo ============================================================
echo.
echo  装完却打不开? 本工具帮你定位根因:
echo    1. 检查 SynologyDrive.exe 是否存在
echo    2. 检查 VxKex-NEXT 是否安装
echo    3. 逐个检查 bin 下每个 exe 是否被 VxKex 接管
echo       (最常见的失败原因就是漏加了某些 exe)
echo    4. 实际启动一次, 失败则扫描事件日志取证
echo.
echo  无需管理员权限即可运行。
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose-launch.ps1"

echo.
pause
