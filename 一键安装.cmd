@echo off
title Synology Drive Client 一键安装工具

echo.
echo ============================================================
echo     Synology Drive Client 一键安装工具 (Win7 兼容版)
echo ============================================================
echo.
echo  本工具会自动完成以下操作:
echo    [1] 从群晖官网下载 Synology Drive Client (x86)
echo    [2] 从 GitHub 下载 VxKex-NEXT (Win7 兼容层)
echo    [3] 依次启动两个安装程序
echo    [4] 自动定位 Synology Drive 的 bin 目录
echo    [5] 打开 VxKex 设置窗口供您添加程序
echo    [6] 验证并按需配置开机自启动
echo.
echo  本工具会做这些系统改动 (都是为了让程序正常运行):
echo    - 配置开机自启动 (第 7 步, 可当场选择跳过)
echo    - 写入 TLS 1.2 注册表项 (用于访问 GitHub / 群晖下载)
echo    - 必要时启用系统自带的 BITS 下载服务
echo.
echo  本工具不会:
echo    - 删除或替换任何系统文件
echo    - 上传或收集任何数据
echo    - 静默安装 (每一步都需要您确认)
echo.
echo ============================================================
echo  执行前请阅读:
echo ============================================================
echo  1. 建议先临时关闭 360 或将本文件夹加入白名单
echo     (VxKex-NEXT 会 hook 系统 DLL 加载, 杀毒软件可能误报)
echo  2. 安装完成后可以重新开启 360
echo  3. 如果脚本无法运行, 请右键本 cmd 文件选择
echo     "以管理员身份运行"
echo ============================================================
echo.
pause

echo.
echo 正在启动安装脚本...
echo.

REM 使用系统自带 PowerShell, 不使用任何隐藏窗口/编码命令参数
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0安装Synology Drive Client.ps1"

set EXITCODE=%ERRORLEVEL%
echo.
if %EXITCODE% EQU 0 (
    echo ============================================================
    echo  安装流程已结束
    echo ============================================================
) else (
    echo ============================================================
    echo  脚本异常退出, 错误码: %EXITCODE%
    echo  请截图错误信息以便排查
    echo ============================================================
)
echo.
pause
