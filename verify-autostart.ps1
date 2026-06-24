# =============================================================
# Synology Drive 开机自启动 - 检查 + 修复工具
# =============================================================
# 不需要管理员权限即可运行 (仅操作 HKCU 和用户启动文件夹)
# =============================================================

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

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
# 1. 查找 SynologyDrive.exe
# -------------------------------------------------------------

Write-Section "检查 1/3  定位 Synology Drive"

$synoExe = $null
$candidates = @(
    "$env:USERPROFILE\AppData\Local\SynologyDrive\SynologyDrive.app\SynologyDrive.exe",
    "${env:ProgramFiles(x86)}\Synology\SynologyDrive\SynologyDrive.exe",
    "$env:ProgramFiles\Synology\SynologyDrive\SynologyDrive.exe"
)
foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { $synoExe = $c; break }
}
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

if ($synoExe) {
    Write-OK "已找到: $synoExe"
} else {
    Write-Bad "未找到 SynologyDrive.exe"
    Write-Info "请先运行 [一键安装.cmd] 完成 Synology Drive 安装"
    exit 1
}

# -------------------------------------------------------------
# 2. 检查 HKCU\Run (Synology 官方机制)
# -------------------------------------------------------------

Write-Section "检查 2/3  注册表自启动项 (HKCU\Run)"

$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runEntry = $null
try {
    $runProps = Get-ItemProperty -Path $runKey -ErrorAction Stop
    foreach ($p in $runProps.PSObject.Properties) {
        # -contains 而非 -in (后者是 PS3+, 在 PS2.0 上会解析报错)
        if (@("PSPath","PSParentPath","PSChildName","PSDrive","PSProvider") -contains $p.Name) { continue }
        # 必须匹配 SynologyDrive.exe (区分 Synology Assistant / Photos 等同厂商应用)
        if ($p.Value -is [string] -and $p.Value -match "SynologyDrive\.exe") {
            $runEntry = $p
            break
        }
    }
} catch {
    Write-Warn "读取注册表失败: $($_.Exception.Message)"
}

$runOK = $false
if ($runEntry) {
    Write-OK "已配置注册表自启动"
    Write-Info "项名: $($runEntry.Name)"
    Write-Info "命令: $($runEntry.Value)"

    # 验证路径有效性
    $cmdText = $runEntry.Value
    $cmdPath = $cmdText
    if ($cmdPath -match '^"([^"]+)"') { $cmdPath = $Matches[1] }
    elseif ($cmdPath -match '^(\S+)') { $cmdPath = $Matches[1] }

    if (Test-Path $cmdPath) {
        Write-OK "目标路径有效"
        $runOK = $true
    } else {
        Write-Bad "目标路径不存在: $cmdPath"
        Write-Info "注册表项可能指向已删除的旧版本, 建议清理"
    }
} else {
    Write-Warn "未配置注册表自启动"
}

# -------------------------------------------------------------
# 3. 检查启动文件夹快捷方式 (备用机制)
# -------------------------------------------------------------

Write-Section "检查 3/3  启动文件夹快捷方式"

$startupFolder = [Environment]::GetFolderPath("Startup")
$shortcut = Join-Path $startupFolder "Synology Drive.lnk"
$shortcutOK = $false

if (Test-Path $shortcut) {
    Write-OK "启动文件夹中存在: Synology Drive.lnk"
    Write-Info "路径: $shortcut"

    try {
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($shortcut)
        Write-Info "指向: $($sc.TargetPath)"
        if (Test-Path $sc.TargetPath) {
            Write-OK "快捷方式目标有效"
            $shortcutOK = $true
        } else {
            Write-Bad "快捷方式目标无效"
        }
    } catch { }
} else {
    Write-Warn "启动文件夹中无 Synology Drive 快捷方式"
}

# -------------------------------------------------------------
# 总结 + 修复
# -------------------------------------------------------------

Write-Section "诊断结果"

if ($runOK -or $shortcutOK) {
    Write-OK "Synology Drive 已配置开机自启动"
    if ($runOK -and $shortcutOK) {
        Write-Warn "注册表 和 启动文件夹 都配置了, 建议只保留一个 (会重复启动)"
        $ans = Read-Host "是否移除启动文件夹中的快捷方式? (Y/N, 默认 N)"
        if ($ans -eq 'Y' -or $ans -eq 'y') {
            try {
                Remove-Item $shortcut -Force
                Write-OK "已移除: $shortcut"
            } catch {
                Write-Bad "移除失败: $($_.Exception.Message)"
            }
        }
    }
    Write-Host ""
    Write-Host "  下次开机会自动启动 Synology Drive" -ForegroundColor Green
    Write-Host "  (在 Win7 上 VxKex 通过 IFEO 钩子会自动注入兼容层)" -ForegroundColor Green
} else {
    Write-Bad "Synology Drive 未配置开机自启动"
    Write-Host ""
    Write-Host "  请选择修复方式:" -ForegroundColor Yellow
    Write-Host "    [1] 在启动文件夹创建快捷方式 (推荐, 简单可靠)" -ForegroundColor Yellow
    Write-Host "    [2] 我自己去 Synology Drive 设置里勾选自启动" -ForegroundColor Yellow
    Write-Host "    [3] 不需要自启动, 退出" -ForegroundColor Yellow
    Write-Host ""
    $choice = Read-Host "请输入选择 (1/2/3, 默认 1)"
    # PS2.0/.NET3.5 安全写法 (IsNullOrWhiteSpace 是 .NET4+)
    if (-not $choice -or -not $choice.Trim()) { $choice = "1" }

    switch ($choice) {
        "1" {
            try {
                $wsh = New-Object -ComObject WScript.Shell
                $sc = $wsh.CreateShortcut($shortcut)
                $sc.TargetPath = $synoExe
                $sc.Arguments = "/autorun"
                $sc.WorkingDirectory = Split-Path -Parent $synoExe
                $sc.Description = "Synology Drive Client (随系统启动)"
                $sc.IconLocation = "$synoExe,0"
                $sc.Save()
                Write-OK "已创建启动快捷方式"
                Write-Info "位置: $shortcut"
                Write-Info "下次开机将自动启动 Synology Drive"
                Write-Info "如需取消: 直接删除该 .lnk 文件"
            } catch {
                Write-Bad "创建失败: $($_.Exception.Message)"
            }
        }
        "2" {
            Write-Info "操作步骤:"
            Write-Info "  1. 启动 Synology Drive Client"
            Write-Info "  2. 右上角齿轮 -> [设置 / Preferences]"
            Write-Info "  3. [常规 / General] 选项卡"
            Write-Info "  4. 勾选 [随 Windows 启动时运行 Synology Drive]"
            Write-Info "完成后再次运行本工具应该会显示 [已配置]"
        }
        default {
            Write-Info "已跳过"
        }
    }
}

Write-Host ""
