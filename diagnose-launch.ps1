# =============================================================
# Synology Drive 启动失败诊断工具
# =============================================================
# 当 Synology Drive 装完、VxKex 配完, 却仍然打不开时, 用本工具
# 定位根因。不需要管理员权限 (IFEO 注册表 + 应用程序事件日志
# 普通用户可读)。
#
# 核心原理: VxKex NEXT 通过 IFEO (映像文件执行选项) 注入兼容层 —
#   在 HKLM\...\Image File Execution Options\<exe> 下写入:
#     VerifierDlls = <VxKex 的 DLL>
#     GlobalFlag   = 含 0x100 位 (FLG_APPLICATION_VERIFIER)
#   只要某个 exe 没有这两项, Windows 加载它时就会因缺少
#   api-ms-win-crt-*.dll 而失败。本工具逐个检查 bin 下的 exe
#   是否都已被 VxKex 接管。
# =============================================================

# 控制台输出兼容层 —— 修复 PS2.0 上 Write-Host -ForegroundColor 写中文
# 触发缓冲区 Win32 错误(0x1F)导致崩溃; 改为无颜色纯文本输出, 并按
# 控制台自身代码页显示(中文 Win7 = GBK), 避免乱码。
function Write-Host {
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)] $Object = "",
        $Separator = " ",
        $ForegroundColor,
        $BackgroundColor,
        [switch] $NoNewline
    )
    $text = (@($Object) -join $Separator)
    try {
        if ($NoNewline) { [System.Console]::Write($text) } else { [System.Console]::WriteLine($text) }
    } catch {
        try { Microsoft.PowerShell.Utility\Write-Output $text } catch { }
    }
}

function Write-Section { param([string]$T)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  $T" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
}
function Write-OK   { param([string]$T) Write-Host "[OK] $T" -ForegroundColor Green }
function Write-Bad  { param([string]$T) Write-Host "[X ] $T" -ForegroundColor Red }
function Write-Warn { param([string]$T) Write-Host "[! ] $T" -ForegroundColor Yellow }
function Write-Info { param([string]$T) Write-Host "    $T" -ForegroundColor Gray }

# -------------------------------------------------------------
# 读取某个 exe 的 IFEO / VxKex 注册信息 (跨 32/64 位注册表视图)
# -------------------------------------------------------------
function Get-IfeoInfo {
    param([string]$ExeName)
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$ExeName",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$ExeName"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $props = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
            if ($props) {
                $verifier = $props.VerifierDlls
                $gf = $props.GlobalFlag
                $gfNum = 0
                # GlobalFlag 可能是 REG_DWORD(int) 或 REG_SZ 十六进制字符串 "0x100",
                # 两种都要能解析, 否则会误报 "缺 0x100 位"
                if ($null -ne $gf) {
                    try {
                        if ($gf -is [string]) {
                            $s = $gf.Trim()
                            if ($s -match '^0x') { $gfNum = [Convert]::ToInt64($s.Substring(2), 16) }
                            elseif ($s -ne '') { $gfNum = [Convert]::ToInt64($s, 10) }
                        } else {
                            $gfNum = [int64]$gf
                        }
                    } catch { $gfNum = 0 }
                }
                $hasVerifierBit = (($gfNum -band 0x100) -ne 0)
                if (-not [string]::IsNullOrEmpty($verifier)) {
                    return New-Object PSObject -Property @{
                        Path = $p
                        VerifierDlls = $verifier
                        GlobalFlag = $gf
                        VerifierBit = $hasVerifierBit
                        Enabled = $true
                    }
                }
            }
        }
    }
    return New-Object PSObject -Property @{
        Path = $null; VerifierDlls = $null; GlobalFlag = $null; VerifierBit = $false; Enabled = $false
    }
}

# -------------------------------------------------------------
# 1. 定位 SynologyDrive.exe 与 bin 目录
# -------------------------------------------------------------

Write-Section "诊断 1/4  定位 Synology Drive"

$synoExe = $null
$candidates = @(
    "$env:USERPROFILE\AppData\Local\SynologyDrive\SynologyDrive.app\SynologyDrive.exe",
    "${env:ProgramFiles(x86)}\Synology\SynologyDrive\SynologyDrive.exe",
    "$env:ProgramFiles\Synology\SynologyDrive\SynologyDrive.exe"
)
foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $synoExe = $c; break } }
if (-not $synoExe) {
    $roots = @(
        "$env:USERPROFILE\AppData\Local\SynologyDrive",
        "${env:ProgramFiles(x86)}\Synology",
        "$env:ProgramFiles\Synology"
    ) | Where-Object { $_ -and (Test-Path $_) }
    if ($roots) {
        $found = Get-ChildItem -Path $roots -Filter "SynologyDrive.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $synoExe = $found.FullName }
    }
}

if (-not $synoExe) {
    Write-Bad "未找到 SynologyDrive.exe — 请先运行 一键安装.cmd 完成安装"
    Read-Host "按回车退出" | Out-Null
    exit 1
}
Write-OK "主程序: $synoExe"

$binDir = Join-Path (Split-Path -Parent $synoExe) "bin"
if (-not (Test-Path $binDir)) {
    # 有些版本 SynologyDrive.exe 直接就在 .app 根, bin 在其下
    $maybeBin = "$env:USERPROFILE\AppData\Local\SynologyDrive\SynologyDrive.app\bin"
    if (Test-Path $maybeBin) { $binDir = $maybeBin }
}
Write-Info "bin 目录: $binDir"

# -------------------------------------------------------------
# 2. VxKex 是否安装
# -------------------------------------------------------------

Write-Section "诊断 2/4  VxKex-NEXT 安装状态"

$osVersion = (Get-WmiObject Win32_OperatingSystem).Version
$isWin7 = ($osVersion -like "6.1*")
if ($isWin7) {
    Write-Info "操作系统: Windows 7 (需要 VxKex)"
} else {
    Write-Info "操作系统版本: $osVersion (Win8+ 通常不需要 VxKex)"
}

$vxkexInstalled = $false
$vxkexProbes = @(
    "$env:SystemRoot\System32\KexLdr.dll",
    "$env:SystemRoot\System32\VxlBuild.dll",
    "$env:ProgramFiles\VxKex",
    "${env:ProgramFiles(x86)}\VxKex"
)
foreach ($p in $vxkexProbes) {
    if ($p -and (Test-Path $p)) { $vxkexInstalled = $true; Write-Info "命中: $p"; break }
}
if ($vxkexInstalled) {
    Write-OK "VxKex-NEXT 已安装"
} elseif ($isWin7) {
    Write-Bad "未检测到 VxKex-NEXT — 这是 Win7 上启动失败最常见原因"
    Write-Info "请运行 一键安装.cmd 安装 VxKex, 或从开始菜单确认是否已装"
} else {
    Write-Info "非 Win7, 跳过 VxKex 检查"
}

# -------------------------------------------------------------
# 3. 逐个检查 bin 下 exe 是否被 VxKex 接管 (IFEO 注册)
# -------------------------------------------------------------

Write-Section "诊断 3/4  VxKex 接管情况 (逐个 exe)"

$exes = @()
if (Test-Path $binDir) {
    $exes = @(Get-ChildItem -Path $binDir -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue)
}
# 主程序本身也要被接管
$mainExeItem = Get-Item $synoExe -ErrorAction SilentlyContinue
if ($mainExeItem -and ($exes.FullName -notcontains $synoExe)) { $exes = @($mainExeItem) + $exes }

$missing = @()
$enabledCount = 0
if ($exes.Count -eq 0) {
    Write-Warn "bin 目录下没有找到 exe (目录可能还没生成, 先运行一次 Synology Drive)"
} else {
    foreach ($exe in $exes) {
        $info = Get-IfeoInfo -ExeName $exe.Name
        if ($info.Enabled -and $info.VerifierBit) {
            $enabledCount++
            Write-OK "$($exe.Name)  — 已接管"
        } elseif ($info.Enabled -and -not $info.VerifierBit) {
            $missing += $exe.Name
            Write-Warn "$($exe.Name)  — 有 VerifierDlls 但 GlobalFlag 缺 0x100 位 (未生效)"
        } else {
            $missing += $exe.Name
            Write-Bad "$($exe.Name)  — 未被 VxKex 接管"
        }
    }
    Write-Host ""
    Write-Info "接管: $enabledCount / $($exes.Count) 个 exe"
}

# 仅在 Win7 且 VxKex 已装时, 未接管才是问题
$ifeoProblem = ($isWin7 -and $vxkexInstalled -and ($missing.Count -gt 0))

# -------------------------------------------------------------
# 4. 实际启动测试 + 事件日志取证
# -------------------------------------------------------------

Write-Section "诊断 4/4  启动测试"

# 关闭可能残留的进程, 保证测试干净
$pre = Get-Process -Name "SynologyDrive" -ErrorAction SilentlyContinue
if ($pre) {
    Write-Info "已有 SynologyDrive 进程在运行 (PID: $($pre.Id -join ','))"
    Write-OK "程序本身能运行 — 若你看不到界面, 检查任务栏托盘的隐藏图标"
    $launchedOK = $true
} else {
    $stamp = Get-Date
    Write-Info "启动 $synoExe ..."
    try { Start-Process -FilePath $synoExe -ErrorAction Stop } catch { Write-Bad "启动调用失败: $($_.Exception.Message)" }
    # 轮询最多 8 秒
    $launchedOK = $false
    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Seconds 1
        if (Get-Process -Name "SynologyDrive" -ErrorAction SilentlyContinue) { $launchedOK = $true; break }
    }
    if ($launchedOK) {
        Write-OK "进程已起来并存活 — 启动正常"
        Write-Info "若托盘没图标, 多等几秒或查看托盘溢出区"
    } else {
        Write-Bad "进程未能存活 — 启动失败"
        # 扫描应用程序事件日志取证
        Write-Info "正在扫描应用程序事件日志 (最近 3 分钟)..."
        try {
            $evts = Get-EventLog -LogName Application -After $stamp.AddSeconds(-5) -ErrorAction Stop |
                Where-Object {
                    ($_.Source -match 'Application Error|SideBySide|\.NET Runtime|Application Hang|Windows Error Reporting') -and
                    ($_.Message -match 'Synology|SynologyDrive')
                } | Select-Object -First 5
            if ($evts) {
                foreach ($e in $evts) {
                    Write-Host ""
                    Write-Warn "事件: [$($e.Source)] EventID=$($e.EventID) @ $($e.TimeGenerated)"
                    # 截取消息前几行 + 含关键字的行
                    $msgLines = ($e.Message -split "`n") | Where-Object { $_ -match 'dll|module|Synology|0x|fault|assembly' } | Select-Object -First 6
                    foreach ($ln in $msgLines) { Write-Info ($ln.Trim()) }
                }
            } else {
                Write-Info "事件日志里没有相关错误记录 (常见于'缺少 DLL'弹窗 — 加载器直接弹框不写日志)"
            }
        } catch {
            Write-Info "无法读取事件日志: $($_.Exception.Message)"
        }
    }
}

# -------------------------------------------------------------
# 结论 + 针对性建议
# -------------------------------------------------------------

Write-Section "诊断结论"

if ($launchedOK -and -not $ifeoProblem) {
    Write-OK "Synology Drive 可以正常启动, 未发现问题"
    Write-Info "如果你是因为'看不到窗口'来诊断的, 那是程序最小化到托盘了 —"
    Write-Info "点任务栏右下角的向上小箭头, 找到 Synology Drive 图标双击即可。"
} else {
    Write-Bad "发现可能导致启动失败的问题, 按优先级处理:"
    Write-Host ""

    $n = 1
    if ($isWin7 -and -not $vxkexInstalled) {
        Write-Host "  $n. [根因] VxKex-NEXT 没装。Win7 缺它必然报缺少 api-ms-win-crt-*.dll" -ForegroundColor Yellow
        Write-Info "     -> 运行 一键安装.cmd 安装 VxKex"
        $n++
    }
    if ($ifeoProblem) {
        Write-Host "  $n. [根因] 下列 exe 还没被 VxKex 接管 (最常见: 漏加了部分 exe):" -ForegroundColor Yellow
        foreach ($m in $missing) { Write-Info "       - $m" }
        Write-Info "     -> 打开 [VxKex NEXT Global Settings] -> Add Program"
        Write-Info "     -> 进入 bin 目录: $binDir"
        Write-Info "     -> Ctrl+A 全选所有 exe 一次性添加, 保存"
        Write-Info "     -> 提示: 漏掉任何一个 exe 都可能导致主程序连锁起不来"
        $n++
    }
    if (-not $launchedOK -and (-not $ifeoProblem) -and ($vxkexInstalled -or -not $isWin7)) {
        Write-Host "  $n. exe 都已接管但仍崩溃 — 试这些:" -ForegroundColor Yellow
        Write-Info "     a) 在 VxKex 里给 SynologyDrive.exe 开启 'Windows 10' 版本伪装"
        Write-Info "        (右键 exe -> Properties -> VxKex 标签 -> Strong version spoofing)"
        Write-Info "     b) 重启电脑后再试 (IFEO 改动对已缓存进程不立即生效)"
        Write-Info "     c) 回退到实测稳妥的版本: 改 安装脚本 的 `$synoVersion = 4.0.2-17889"
        Write-Info "     d) 确认装的是 x86 (32位) 而不是 x64"
        $n++
    }
    Write-Host ""
    Write-Info "改完后再次运行本工具确认。"
}

Write-Host ""
