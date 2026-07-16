@echo off
title Synology Drive Client 一键安装工具

REM ==== 自动申请管理员权限 (兼容中文路径 + 防死循环) ====
REM 已带标记参数 = 已是提权后的实例, 直接进主流程
if "%~1"=="elevated" goto :main
REM fltmc 需要管理员权限, 返回 0 表示已是管理员 (不依赖任何系统服务)
fltmc >nul 2>&1
if "%errorlevel%"=="0" goto :main
REM 未提权: 写一个临时 VBS, 用 ShellExecute runas 以管理员重启自己。
REM 用 VBS 从文件读取路径, 避免中文路径经命令行传参被搞乱。
set "_vbs=%TEMP%\syno_elevate.vbs"
> "%_vbs%" echo Set o = CreateObject("Shell.Application")
>>"%_vbs%" echo o.ShellExecute "%~f0", "elevated", "", "runas", 1
cscript //nologo "%_vbs%"
set "_rc=%errorlevel%"
del "%_vbs%" >nul 2>&1
if not "%_rc%"=="0" (
    echo.
    echo   提权被取消或失败, 请右键本文件手动选择 "以管理员身份运行"
    echo.
    pause
)
exit /b

:main
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
echo    - 启用系统 TLS 1.2 (SCHANNEL/WinHTTP 注册表; 只开新协议,
echo      不关闭任何现有协议, 属微软推荐的安全增强, 可改回)
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
echo ============================================================
echo.
pause

echo.
echo 正在启动安装脚本...
echo.

REM 切到脚本所在目录, 再用 -File 调用 (中文路径 -File 传参是可靠的)
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0安装Synology Drive Client.ps1"
set "EXITCODE=%ERRORLEVEL%"
popd
echo.
if "%EXITCODE%"=="0" (
    echo ============================================================
    echo  安装流程已结束
    echo ============================================================
) else (
    echo ============================================================
    echo  脚本异常退出, 错误码: %EXITCODE%
    echo  请把 downloads 文件夹里的 install-log-*.txt 发出来排查
    echo ============================================================
)
echo.
pause
