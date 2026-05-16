# =============================================================
# Synology Drive Client 一键安装脚本 (Win7 兼容版)
# =============================================================
# 设计原则: 透明、可读、无混淆
#   - 不使用 Invoke-Expression / IEX
#   - 不使用 -EncodedCommand
#   - 不使用 Base64 解码
#   - 不写入 HKLM 启动项
#   - 所有下载使用 BITS (系统自带服务)
#   - 所有 URL 均为官方源
# =============================================================

# 控制台编码
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# 启用 TLS 1.2 (访问 GitHub / Synology 必需)
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12 -bor `
        [Net.SecurityProtocolType]::Tls11 -bor `
        [Net.SecurityProtocolType]::Tls
} catch { }

# 工作目录: 安装包所在文件夹
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkDir = Join-Path $ScriptDir "downloads"
if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}

# 日志记录: 出问题时方便排查
$logPath = Join-Path $WorkDir ("install-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
try { Start-Transcript -Path $logPath -Append -ErrorAction Stop | Out-Null } catch { }

# -------------------------------------------------------------
# 工具函数
# -------------------------------------------------------------

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Text)
    Write-Host "[+] $Text" -ForegroundColor Green
}

function Write-Info {
    param([string]$Text)
    Write-Host "    $Text" -ForegroundColor Gray
}

function Write-Warn {
    param([string]$Text)
    Write-Host "[!] $Text" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Text)
    Write-Host "[X] $Text" -ForegroundColor Red
}

function Pause-Continue {
    param([string]$Prompt = "按回车键继续...")
    Read-Host $Prompt | Out-Null
}

function Test-Admin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$SynologyArchiveRoot = "https://archive.synology.com/download/Utility/SynologyDriveClient"
$SynologyDownloadRoot = "https://global.synologydownload.com"

function New-SynologyVersionRecord {
    param(
        [string]$Version,
        [object]$File = $null
    )

    if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)-(\d+)$') {
        return $null
    }

    New-Object PSObject -Property @{
        Version = $Version
        Major   = [int]$Matches[1]
        Minor   = [int]$Matches[2]
        Patch   = [int]$Matches[3]
        Build   = [int]$Matches[4]
        File    = $File
    }
}

function Find-LocalSynologyInstaller {
    param(
        [string]$Directory,
        [string]$Architecture = "x86"
    )

    if (-not (Test-Path $Directory)) {
        return $null
    }

    $pattern = "^Synology Drive Client-(\d+\.\d+\.\d+-\d+)-$([regex]::Escape($Architecture))\.exe$"
    $records = @()

    $files = Get-ChildItem -Path $Directory -Filter "Synology Drive Client-*-$Architecture.exe" -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        if ($file.Length -le 1MB) { continue }
        if ($file.Name -match $pattern) {
            $record = New-SynologyVersionRecord -Version $Matches[1] -File $file
            if ($record) { $records += $record }
        }
    }

    if ($records.Count -eq 0) {
        return $null
    }

    return $records | Sort-Object -Property Major,Minor,Patch,Build -Descending | Select-Object -First 1
}

function Resolve-SynologyDriveClientDownload {
    param(
        [string]$Architecture = "x86",
        [string]$PreferredVersion = $null
    )

    $version = $null

    if (-not [string]::IsNullOrWhiteSpace($PreferredVersion)) {
        $PreferredVersion = $PreferredVersion.Trim()
        $record = New-SynologyVersionRecord -Version $PreferredVersion
        if (-not $record) {
            throw "指定的 Synology Drive 版本格式无效: $PreferredVersion"
        }
        $version = $PreferredVersion
        Write-Warn "使用环境变量指定版本: $version"
    } else {
        Write-Step "查询 Synology 官方归档中的最新 Windows 客户端版本..."
        $index = Invoke-WebRequest -Uri $SynologyArchiveRoot -UseBasicParsing -TimeoutSec 60

        $seen = @{}
        $records = @()
        foreach ($match in [regex]::Matches($index.Content, 'SynologyDriveClient/(\d+\.\d+\.\d+-\d+)')) {
            $candidate = $match.Groups[1].Value
            if ($seen.ContainsKey($candidate)) { continue }
            $seen[$candidate] = $true

            $record = New-SynologyVersionRecord -Version $candidate
            if ($record) { $records += $record }
        }

        if ($records.Count -eq 0) {
            throw "未能从 Synology 官方归档解析版本列表"
        }

        $latest = $records | Sort-Object -Property Major,Minor,Patch,Build -Descending | Select-Object -First 1
        $version = $latest.Version
        Write-Step "解析到最新版本: $version"
    }

    $fileName = "Synology Drive Client-$version-$Architecture.exe"
    $encodedFileName = [System.Uri]::EscapeDataString($fileName)
    $versionUrl = "$SynologyArchiveRoot/$version"

    Write-Step "确认 $Architecture 安装包存在..."
    $versionPage = Invoke-WebRequest -Uri $versionUrl -UseBasicParsing -TimeoutSec 60
    $hasPlainName = $versionPage.Content -match [regex]::Escape($fileName)
    $hasEncodedName = $versionPage.Content -match [regex]::Escape($encodedFileName)
    if (-not ($hasPlainName -or $hasEncodedName)) {
        throw "Synology 版本 $version 未找到 $Architecture exe 安装包"
    }

    $assetUrl = $null
    $assetPattern = 'href="([^"]*(' + [regex]::Escape($encodedFileName) + '|' + [regex]::Escape($fileName) + ')[^"]*)"'
    $assetMatch = [regex]::Match($versionPage.Content, $assetPattern)
    if ($assetMatch.Success) {
        $assetUrl = $assetMatch.Groups[1].Value.Replace('&amp;', '&')
        if ($assetUrl -match '^//') {
            $assetUrl = "https:$assetUrl"
        } elseif ($assetUrl -match '^/') {
            $assetUrl = "https://archive.synology.com$assetUrl"
        } elseif ($assetUrl -notmatch '^https?://') {
            $assetUrl = "$versionUrl/$assetUrl"
        }
    }
    if ([string]::IsNullOrWhiteSpace($assetUrl)) {
        $assetUrl = "$SynologyDownloadRoot/download/Utility/SynologyDriveClient/$version/$encodedFileName"
    }

    New-Object PSObject -Property @{
        Version   = $version
        FileName  = $fileName
        Url       = $assetUrl
        LocalPath = Join-Path $WorkDir $fileName
    }
}

# 下载文件: 优先用 BITS, 失败回退到 WebRequest
function Get-FileSha256Lower {
    param([string]$Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::OpenRead($Path)
        try { $bytes = $sha.ComputeHash($stream) } finally { $stream.Close() }
        return ([BitConverter]::ToString($bytes) -replace '-','').ToLower()
    } catch { return $null }
}

# 确保 BITS 服务可用 (干净的 Win7 上可能被禁用或停止)
function Ensure-BitsService {
    try {
        $svc = Get-Service -Name BITS -ErrorAction Stop
        if ($svc.StartType -eq 'Disabled') {
            try {
                Set-Service -Name BITS -StartupType Manual -ErrorAction Stop
                Write-Info "BITS 启动类型已从 Disabled 改为 Manual"
            } catch {
                Write-Warn "BITS 服务被禁用且无法修改: $($_.Exception.Message)"
                return $false
            }
        }
        if ($svc.Status -ne 'Running') {
            Write-Info "BITS 服务未运行 (当前: $($svc.Status)), 尝试启动..."
            Start-Service -Name BITS -ErrorAction Stop
            Start-Sleep -Seconds 1
            $svc = Get-Service -Name BITS
        }
        if ($svc.Status -eq 'Running') {
            return $true
        }
        Write-Warn "BITS 服务无法启动, 将直接使用 Invoke-WebRequest 下载"
        return $false
    } catch {
        Write-Warn "BITS 服务不可用 ($($_.Exception.Message)), 将直接使用 Invoke-WebRequest 下载"
        return $false
    }
}

# 把 GitHub 直链转成大陆可访问的镜像 (用于直接 GitHub 失败时回退)
function ConvertTo-GitHubMirrorUrl {
    param([string]$Url)
    if ($Url -match '^https?://(github\.com|raw\.githubusercontent\.com|gist\.github\.com|gist\.githubusercontent\.com|codeload\.github\.com|objects\.githubusercontent\.com)/') {
        return "https://gh-proxy.com/$Url"
    }
    return $null
}

function Get-RemoteFile {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$Description,
        [string]$ExpectedSha256 = $null
    )

    Write-Step "下载: $Description"
    Write-Info "URL : $Url"
    Write-Info "保存: $OutFile"

    if (Test-Path $OutFile) {
        $size = (Get-Item $OutFile).Length
        if ($size -gt 1MB) {
            Write-Step "本地已存在 ($([math]::Round($size/1MB, 2)) MB), 跳过下载"
            return $true
        } else {
            Remove-Item $OutFile -Force
        }
    }

    # 尝试 BITS 传输 (前提是 BITS 服务可用)
    if (Ensure-BitsService) {
        try {
            Import-Module BitsTransfer -ErrorAction Stop
            Start-BitsTransfer -Source $Url -Destination $OutFile `
                -DisplayName $Description -Description "Synology Drive 安装工具下载"
            if (Test-Path $OutFile) {
                $size = (Get-Item $OutFile).Length
                Write-Step "BITS 下载完成: $([math]::Round($size/1MB, 2)) MB"
                if (-not [string]::IsNullOrEmpty($ExpectedSha256)) {
                    $actualSha256 = Get-FileSha256Lower -Path $OutFile
                    if ([string]::IsNullOrEmpty($actualSha256) -or ($actualSha256.ToLower() -ne $ExpectedSha256.ToLower())) {
                        try { Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue } catch { }
                        Write-Err "SHA256 校验失败: $OutFile"
                        return $false
                    }
                    Write-Step "SHA256 校验通过: $OutFile"
                }
                return $true
            }
        } catch {
            Write-Warn "BITS 下载失败: $($_.Exception.Message)"
            Write-Info "尝试备用方式..."
        }
    }

    # 回退 1: Invoke-WebRequest 直连
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
        if (Test-Path $OutFile) {
            $size = (Get-Item $OutFile).Length
            Write-Step "下载完成: $([math]::Round($size/1MB, 2)) MB"
            if (-not [string]::IsNullOrEmpty($ExpectedSha256)) {
                $actualSha256 = Get-FileSha256Lower -Path $OutFile
                if ([string]::IsNullOrEmpty($actualSha256) -or ($actualSha256.ToLower() -ne $ExpectedSha256.ToLower())) {
                    try { Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue } catch { }
                    Write-Err "SHA256 校验失败: $OutFile"
                    return $false
                }
                Write-Step "SHA256 校验通过: $OutFile"
            }
            return $true
        }
    } catch {
        Write-Warn "直连下载失败: $($_.Exception.Message)"
    }

    # 回退 2: 如果是 GitHub 链接, 通过国内镜像再试 (gh-proxy.com)
    $mirrorUrl = ConvertTo-GitHubMirrorUrl -Url $Url
    if ($mirrorUrl) {
        Write-Info "尝试 GitHub 镜像: $mirrorUrl"
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $mirrorUrl -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
            if (Test-Path $OutFile) {
                $size = (Get-Item $OutFile).Length
                Write-Step "镜像下载完成: $([math]::Round($size/1MB, 2)) MB"
                if (-not [string]::IsNullOrEmpty($ExpectedSha256)) {
                    $actualSha256 = Get-FileSha256Lower -Path $OutFile
                    if ([string]::IsNullOrEmpty($actualSha256) -or ($actualSha256.ToLower() -ne $ExpectedSha256.ToLower())) {
                        try { Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue } catch { }
                        Write-Err "SHA256 校验失败: $OutFile"
                        return $false
                    }
                    Write-Step "SHA256 校验通过: $OutFile"
                }
                return $true
            }
        } catch {
            Write-Err "镜像下载失败: $($_.Exception.Message)"
        }
    } else {
        Write-Err "下载失败 (非 GitHub 链接, 无镜像可用)"
    }

    return $false
}

# -------------------------------------------------------------
# 第 1 步: 环境检查
# -------------------------------------------------------------

Write-Section "Step 1/7  环境检查"

# 管理员权限
if (-not (Test-Admin)) {
    Write-Err "当前未以管理员身份运行"
    Write-Warn "请关闭此窗口, 右键单击 一键安装.cmd, 选择 [以管理员身份运行]"
    Pause-Continue "按回车键退出"
    try { Stop-Transcript } catch { }
    exit 1
}
Write-Step "管理员权限: 已确认"

# Win7 默认 .NET 不启用 TLS 1.2, 写入注册表让后续 .NET 进程能访问 GitHub / 群晖
$tlsPaths = @(
    "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319",
    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"
)
foreach ($p in $tlsPaths) {
    if (Test-Path $p) {
        try {
            New-ItemProperty -Path $p -Name "SchUseStrongCrypto" -Value 1 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $p -Name "SystemDefaultTlsVersions" -Value 1 -PropertyType DWord -Force | Out-Null
            Write-Step "TLS 1.2 注册表已启用 ($p)"
        } catch {
            Write-Warn "TLS 注册表写入失败: $($_.Exception.Message)"
        }
    }
}

# PowerShell 版本
$psVer = $PSVersionTable.PSVersion
Write-Step "PowerShell 版本: $($psVer.ToString())"
if ($psVer.Major -lt 3) {
    Write-Warn "PowerShell 版本过低, 建议先安装 WMF 5.1"
    Write-Info "下载: https://www.microsoft.com/en-us/download/details.aspx?id=54616"
}

# 操作系统
$os = Get-WmiObject -Class Win32_OperatingSystem
$osCaption = $os.Caption
$osVersion = $os.Version
Write-Step "操作系统: $osCaption"
Write-Info "内部版本号: $osVersion"

$isWin7 = ($osVersion -like "6.1*")
if ($isWin7) {
    Write-Step "已识别为 Windows 7, 需要 VxKex-NEXT 兼容层"
    Write-Info "提示: 干净的 Win7 SP1 需要先装 KB4474419 (SHA-2 签名支持),"
    Write-Info "      否则新版安装包的数字签名无法验证。"
    Write-Info "下载: https://www.catalog.update.microsoft.com/Search.aspx?q=KB4474419"
} else {
    Write-Warn "当前系统不是 Win7, 可能不需要安装 VxKex-NEXT"
    $ans = Read-Host "是否仍要继续完整流程? (Y=继续 / N=只装 Synology Drive)"
    if ($ans -eq 'N' -or $ans -eq 'n') {
        $script:SkipVxKex = $true
    }
}

# 工作目录信息
Write-Step "工作目录: $WorkDir"

# -------------------------------------------------------------
# 第 2 步: 下载 Synology Drive Client
# -------------------------------------------------------------

Write-Section "Step 2/7  下载 Synology Drive Client (x86)"

$synoArchitecture = "x86"
$synoVersionOverride = $env:SYNOLOGY_DRIVE_VERSION
$synoVersionPinned = -not [string]::IsNullOrWhiteSpace($synoVersionOverride)
$synoCacheOnly = $false

try {
    $synoDownload = Resolve-SynologyDriveClientDownload -Architecture $synoArchitecture -PreferredVersion $synoVersionOverride
} catch {
    Write-Warn "自动解析 Synology 官方下载地址失败: $($_.Exception.Message)"

    if ($synoVersionPinned) {
        Write-Err "已指定 SYNOLOGY_DRIVE_VERSION, 无法确认该版本时不会自动改用其他安装包"
        Write-Info "请检查版本号和网络连接, 或取消 SYNOLOGY_DRIVE_VERSION 后重新运行"
        Pause-Continue "按回车键退出"
        exit 1
    }

    $cachedSyno = Find-LocalSynologyInstaller -Directory $WorkDir -Architecture $synoArchitecture
    if ($cachedSyno) {
        $synoDownload = New-Object PSObject -Property @{
            Version   = $cachedSyno.Version
            FileName  = $cachedSyno.File.Name
            Url       = $null
            LocalPath = $cachedSyno.File.FullName
        }
        $synoCacheOnly = $true
        Write-Step "使用本地缓存安装包: $($cachedSyno.File.Name)"
    } else {
        # 官方归档结构变化或临时不可达时的兜底版本。
        $fallbackVersion = "4.0.2-17889"
        $fallbackFileName = "Synology Drive Client-$fallbackVersion-$synoArchitecture.exe"
        $synoDownload = New-Object PSObject -Property @{
            Version   = $fallbackVersion
            FileName  = $fallbackFileName
            Url       = "$SynologyDownloadRoot/download/Utility/SynologyDriveClient/$fallbackVersion/$([System.Uri]::EscapeDataString($fallbackFileName))"
            LocalPath = Join-Path $WorkDir $fallbackFileName
        }
        Write-Warn "改用已知官方兜底版本: $fallbackVersion"
    }
}

$synoVersion = $synoDownload.Version
$synoFileName = $synoDownload.FileName
$synoUrl = $synoDownload.Url
$synoLocalPath = $synoDownload.LocalPath

if ($synoCacheOnly) {
    $ok = Test-Path $synoLocalPath
} else {
    $ok = Get-RemoteFile -Url $synoUrl -OutFile $synoLocalPath -Description "Synology Drive Client $synoVersion"
    if ((-not $ok) -and (-not $synoVersionPinned)) {
        $cachedSyno = Find-LocalSynologyInstaller -Directory $WorkDir -Architecture $synoArchitecture
        if ($cachedSyno) {
            $synoVersion = $cachedSyno.Version
            $synoFileName = $cachedSyno.File.Name
            $synoLocalPath = $cachedSyno.File.FullName
            $ok = $true
            Write-Warn "下载失败, 改用本地缓存安装包: $synoFileName"
        }
    }
}

if (-not $ok) {
    Write-Err "Synology Drive 下载失败"
    Write-Info "请手动下载后放入 $WorkDir 目录, 然后重新运行本脚本"
    Write-Info "官方地址: https://www.synology.cn/zh-cn/support/download"
    Pause-Continue "按回车键退出"
    try { Stop-Transcript } catch { }
    exit 1
}

# -------------------------------------------------------------
# 第 3 步: 下载 VxKex-NEXT (仅 Win7 需要)
# -------------------------------------------------------------

$kexLocalPath = $null

if (-not $script:SkipVxKex) {
    Write-Section "Step 3/7  下载 VxKex-NEXT (Win7 兼容层)"

    # 优先从 GitHub Releases API 获取最新版本
    $kexUrl = $null
    $kexFileName = $null

    try {
        Write-Step "查询 GitHub 最新发布版本..."
        $apiUrl = "https://api.github.com/repos/YuZhouRen86/VxKex-NEXT/releases/latest"
        $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -TimeoutSec 30
        Write-Info "最新版本: $($release.tag_name)"

        # 优先选择 KexSetup_Release_*.exe
        $asset = $release.assets | Where-Object { $_.name -match "KexSetup.*\.exe$" } | Select-Object -First 1
        if (-not $asset) {
            $asset = $release.assets | Where-Object { $_.name -like "*.exe" } | Select-Object -First 1
        }
        if ($asset) {
            $kexUrl = $asset.browser_download_url
            $kexFileName = $asset.name
            Write-Step "找到资源: $kexFileName"
        }
    } catch {
        Write-Warn "无法访问 GitHub API ($($_.Exception.Message))"
    }

    # 备用地址
    if (-not $kexUrl) {
        # Latest as of 2026-05-12
        $kexFileName = "KexSetup_Release_1_1_4_2085.exe"
        $kexUrl = "https://github.com/YuZhouRen86/VxKex-NEXT/releases/download/1.1.4.2085/$kexFileName"
        Write-Warn "使用备用版本: $kexFileName"
    }

    $kexLocalPath = Join-Path $WorkDir $kexFileName
    $ok = Get-RemoteFile -Url $kexUrl -OutFile $kexLocalPath -Description "VxKex-NEXT"
    if (-not $ok) {
        Write-Err "VxKex-NEXT 下载失败"
        Write-Info "请手动下载后放入 $WorkDir 目录:"
        Write-Info "https://github.com/YuZhouRen86/VxKex-NEXT/releases"
        Pause-Continue "按回车键退出"
        try { Stop-Transcript } catch { }
        exit 1
    }
} else {
    Write-Section "Step 3/7  跳过 VxKex-NEXT (非 Win7 系统)"
}

# -------------------------------------------------------------
# 第 4 步: 安装 VxKex-NEXT (先装兼容层)
# -------------------------------------------------------------

if (-not $script:SkipVxKex) {
    Write-Section "Step 4/7  安装 VxKex-NEXT"

    $vxkexInstalled = $false
    $vxkexProbes = @(
        "$env:SystemRoot\System32\VxlBuild.dll",
        "$env:SystemRoot\System32\KexLdr.dll",
        "$env:ProgramFiles\VxKex",
        "${env:ProgramFiles(x86)}\VxKex"
    )
    foreach ($p in $vxkexProbes) {
        if ($p -and (Test-Path $p)) {
            $vxkexInstalled = $true
            break
        }
    }

    if ($vxkexInstalled) {
        Write-Step "检测到 VxKex-NEXT 已安装, 跳过此步"
    } else {
        Write-Step "启动 VxKex-NEXT 安装程序..."
        Write-Warn "请在弹出窗口中:"
        Write-Info "  1. 一路点击 Next / 下一步"
        Write-Info "  2. 安装完成后点 Finish 关闭窗口"
        Write-Info "  3. 若提示重启请选择 [稍后重启]"
        Pause-Continue "准备好后按回车启动安装程序"

        Start-Process -FilePath $kexLocalPath -Wait
        Write-Step "VxKex-NEXT 安装程序已退出"
    }
} else {
    Write-Section "Step 4/7  跳过 VxKex-NEXT 安装"
}

# -------------------------------------------------------------
# 第 5 步: 安装 Synology Drive Client
# -------------------------------------------------------------

Write-Section "Step 5/7  安装 Synology Drive Client"

$synoBinPath = "$env:USERPROFILE\AppData\Local\SynologyDrive\SynologyDrive.app\bin"
$alreadyInstalled = Test-Path $synoBinPath

if ($alreadyInstalled) {
    Write-Step "检测到 Synology Drive 已安装"
    $ans = Read-Host "是否重新安装/升级? (Y/N, 默认 N)"
    if ($ans -eq 'Y' -or $ans -eq 'y') {
        $alreadyInstalled = $false
    }
}

if (-not $alreadyInstalled) {
    Write-Step "启动 Synology Drive 安装程序..."
    Write-Warn "请在弹出窗口中完成安装 (一路下一步即可)"
    Pause-Continue "准备好后按回车启动安装程序"

    Start-Process -FilePath $synoLocalPath -Wait
    Write-Step "Synology Drive 安装程序已退出"
}

# 首次运行让其生成目录结构 (会报错, 这是正常的)
if (-not (Test-Path $synoBinPath)) {
    Write-Warn "尚未检测到 Synology Drive 的 bin 目录, 尝试运行一次让其生成..."
    $synoExe = Get-ChildItem -Path "$env:USERPROFILE\AppData\Local\SynologyDrive" `
        -Filter "SynologyDrive.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $synoExe) {
        $synoExe = Get-ChildItem -Path "${env:ProgramFiles(x86)}" `
            -Filter "SynologyDrive.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($synoExe) {
        Write-Info "运行: $($synoExe.FullName)"
        Write-Warn "如果弹出 DLL 缺失错误对话框, 请点 [确定] 关闭它 (这是预期行为)"
        Start-Process -FilePath $synoExe.FullName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
}

# -------------------------------------------------------------
# 第 6 步: 配置 VxKex 兼容层
# -------------------------------------------------------------

Write-Section "Step 6/7  配置 VxKex 兼容层"

if ($script:SkipVxKex) {
    Write-Step "非 Win7 系统, 跳过兼容层配置"
} elseif (-not (Test-Path $synoBinPath)) {
    Write-Err "未找到 Synology Drive 的 bin 目录: $synoBinPath"
    Write-Warn "请手动运行一次 Synology Drive 让其生成此目录, 然后重新执行本脚本"
} else {
    Write-Step "Synology Drive bin 目录: $synoBinPath"

    $exes = @(Get-ChildItem -Path $synoBinPath -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue)
    Write-Step "发现 $($exes.Count) 个 exe 文件需要添加到 VxKex:"
    foreach ($exe in $exes) {
        Write-Info "  - $($exe.Name)"
    }

    Write-Host ""
    Write-Warn "===== 接下来需要您手动操作 (无法完全自动化) ====="
    Write-Host ""
    Write-Host "  原因: VxKex-NEXT 的配置 GUI 不提供命令行接口" -ForegroundColor Yellow
    Write-Host "        自动写注册表会被 360 等杀毒软件拦截" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  操作步骤:" -ForegroundColor Yellow
    Write-Host "  1. 待会儿会自动弹出两个窗口:" -ForegroundColor Yellow
    Write-Host "     - VxKex NEXT Global Settings (配置面板)" -ForegroundColor Yellow
    Write-Host "     - Synology Drive bin 目录 (源文件)" -ForegroundColor Yellow
    Write-Host "  2. 在 VxKex 面板中点击 [Add Program] / [添加程序]" -ForegroundColor Yellow
    Write-Host "  3. 在文件选择对话框的路径栏粘贴 (已自动复制到剪贴板):" -ForegroundColor Yellow
    Write-Host "     $synoBinPath" -ForegroundColor White
    Write-Host "  4. 按 Ctrl+A 选中该目录下所有 exe, 点击 [Open] / [打开]" -ForegroundColor Yellow
    Write-Host "  5. 保存设置后关闭 VxKex 面板" -ForegroundColor Yellow
    Write-Host ""

    # 复制路径到剪贴板
    try {
        if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
            Set-Clipboard -Value $synoBinPath
        } else {
            $synoBinPath | clip.exe
        }
        Write-Step "bin 路径已复制到剪贴板, 在文件选择对话框中按 Ctrl+V 粘贴即可"
    } catch {
        Write-Warn "复制剪贴板失败, 请手动复制上面的路径"
    }

    Pause-Continue "准备好后按回车打开 VxKex 配置面板"

    # 打开资源管理器到 bin 目录 (方便用户直接拖拽)
    Start-Process explorer.exe -ArgumentList "`"$synoBinPath`""

    # 查找并启动 VxKex GUI
    $vxkexCandidates = @(
        "$env:SystemRoot\System32\VxKex.exe",
        "$env:ProgramFiles\VxKex\VxKex.exe",
        "${env:ProgramFiles(x86)}\VxKex\VxKex.exe",
        "$env:ProgramFiles\VxKex\VxKexUi.exe",
        "${env:ProgramFiles(x86)}\VxKex\VxKexUi.exe"
    )
    $vxkexGui = $null
    foreach ($p in $vxkexCandidates) {
        if ($p -and (Test-Path $p)) {
            $vxkexGui = $p
            break
        }
    }
    if (-not $vxkexGui) {
        $found = Get-ChildItem -Path "$env:ProgramFiles","${env:ProgramFiles(x86)}","$env:SystemRoot" `
            -Filter "VxKex*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $vxkexGui = $found.FullName }
    }

    if ($vxkexGui) {
        Write-Step "启动 VxKex GUI: $vxkexGui"
        Start-Process -FilePath $vxkexGui
    } else {
        Write-Warn "未找到 VxKex GUI, 请从开始菜单手动启动 [VxKex NEXT Global Settings]"
    }
}

# -------------------------------------------------------------
# 第 7 步: 验证 / 启用开机自启动
# -------------------------------------------------------------

Write-Section "Step 7/7  验证开机自启动"

# 定位 SynologyDrive.exe (优先用户级安装路径)
$synoExe = $null
$exeCandidates = @(
    "$env:USERPROFILE\AppData\Local\SynologyDrive\SynologyDrive.app\SynologyDrive.exe",
    "${env:ProgramFiles(x86)}\Synology\SynologyDrive\SynologyDrive.exe",
    "$env:ProgramFiles\Synology\SynologyDrive\SynologyDrive.exe"
)
foreach ($c in $exeCandidates) {
    if ($c -and (Test-Path $c)) { $synoExe = $c; break }
}
if (-not $synoExe) {
    $searchRoots = @(
        "$env:USERPROFILE\AppData\Local\SynologyDrive",
        "${env:ProgramFiles(x86)}\Synology",
        "$env:ProgramFiles\Synology"
    ) | Where-Object { $_ -and (Test-Path $_) }
    if ($searchRoots) {
        $found = Get-ChildItem -Path $searchRoots -Filter "SynologyDrive.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $synoExe = $found.FullName }
    }
}

if (-not $synoExe) {
    Write-Warn "未找到 SynologyDrive.exe, 跳过自启动验证"
    Write-Info "请确认 Synology Drive 已正确安装"
} else {
    Write-Step "可执行文件: $synoExe"

    # === 检查方式 1: HKCU\Run (Synology 自己的标准机制) ===
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $synoRunEntry = $null
    try {
        $runEntries = Get-ItemProperty -Path $runKey -ErrorAction Stop
        foreach ($prop in $runEntries.PSObject.Properties) {
            if ($prop.Name -eq "PSPath" -or $prop.Name -eq "PSParentPath" -or $prop.Name -eq "PSChildName" -or $prop.Name -eq "PSDrive" -or $prop.Name -eq "PSProvider") { continue }
            # 必须匹配 SynologyDrive.exe (区分 Synology Assistant / Photos 等同厂商应用)
            if ($prop.Value -is [string] -and $prop.Value -match "SynologyDrive\.exe") {
                $synoRunEntry = $prop
                break
            }
        }
    } catch { }

    # === 检查方式 2: 启动文件夹 (备用机制) ===
    $startupFolder = [Environment]::GetFolderPath("Startup")
    $startupShortcut = Join-Path $startupFolder "Synology Drive.lnk"
    $hasStartupShortcut = Test-Path $startupShortcut

    if ($synoRunEntry) {
        Write-Step "[OK] 开机自启动已配置 (Synology 标准机制)"
        Write-Info "注册表项: HKCU\...\Run\$($synoRunEntry.Name)"
        Write-Info "启动命令: $($synoRunEntry.Value)"
        Write-Info "下次开机会自动启动, VxKex 会通过 IFEO 钩子注入兼容层"
    } elseif ($hasStartupShortcut) {
        Write-Step "[OK] 启动文件夹中已有 Synology Drive 快捷方式"
        Write-Info "位置: $startupShortcut"
    } else {
        Write-Warn "未检测到开机自启动配置"
        Write-Host ""
        Write-Host "  请选择如何启用开机自启动:" -ForegroundColor Yellow
        Write-Host "    [1] 由本脚本创建启动文件夹快捷方式 (推荐, 一步到位)" -ForegroundColor Yellow
        Write-Host "    [2] 我自己去 Synology Drive 设置里勾选 (官方机制)" -ForegroundColor Yellow
        Write-Host "    [3] 跳过, 我不需要自启动" -ForegroundColor Yellow
        Write-Host ""
        $choice = Read-Host "请输入选择 (1/2/3, 默认 1)"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

        switch ($choice) {
            "1" {
                try {
                    $wsh = New-Object -ComObject WScript.Shell
                    $sc = $wsh.CreateShortcut($startupShortcut)
                    $sc.TargetPath = $synoExe
                    $sc.Arguments = "/autorun"
                    $sc.WorkingDirectory = Split-Path -Parent $synoExe
                    $sc.Description = "Synology Drive Client (随系统启动)"
                    $sc.IconLocation = "$synoExe,0"
                    $sc.Save()
                    Write-Step "[OK] 已创建启动快捷方式"
                    Write-Info "位置: $startupShortcut"
                    Write-Info "下次开机将自动启动 Synology Drive"
                    Write-Info "如需取消, 直接删除该 .lnk 文件即可"
                } catch {
                    Write-Err "创建快捷方式失败: $($_.Exception.Message)"
                    Write-Info "请改用方式 [2] 在 Synology Drive 设置中勾选自启动"
                }
            }
            "2" {
                Write-Info "请打开 Synology Drive Client, 然后:"
                Write-Info "  1. 点击右上角齿轮图标 -> [设置 / Preferences]"
                Write-Info "  2. 在 [常规 / General] 选项卡"
                Write-Info "  3. 勾选 [随 Windows 启动时运行 Synology Drive]"
                Write-Info "     (Run Synology Drive when Windows starts up)"
            }
            default {
                Write-Info "已跳过自启动配置"
            }
        }
    }

    # === 额外保险: 测试当前是否能通过 VxKex 正常启动 ===
    Write-Host ""
    $testLaunch = Read-Host "是否现在测试启动一次 Synology Drive? (Y/N, 默认 Y)"
    if ([string]::IsNullOrWhiteSpace($testLaunch) -or $testLaunch -eq 'Y' -or $testLaunch -eq 'y') {
        Write-Step "启动 Synology Drive 进行测试..."
        try {
            Start-Process -FilePath $synoExe -ErrorAction Stop
            Start-Sleep -Seconds 5
            $proc = Get-Process -Name "SynologyDrive" -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Step "[OK] Synology Drive 进程已运行, PID: $($proc.Id -join ',')"
                Write-Info "如果托盘出现 Synology 图标, 说明 VxKex 兼容层工作正常"
                Write-Info "如果托盘没有图标但进程在, 说明启动成功但还在初始化"
            } else {
                Write-Warn "未检测到 Synology Drive 进程"
                Write-Info "可能原因:"
                Write-Info "  - VxKex 未配置好 bin 目录下所有 exe"
                Write-Info "  - 程序启动失败 (重启电脑后再试)"
            }
        } catch {
            Write-Err "启动失败: $($_.Exception.Message)"
        }
    }
}

# -------------------------------------------------------------
# 完成
# -------------------------------------------------------------

Write-Section "全部步骤已完成"

Write-Host ""
Write-Host "  完成 VxKex 配置后:" -ForegroundColor Green
Write-Host "  1. 关闭 VxKex 配置面板" -ForegroundColor Green
Write-Host "  2. 从开始菜单启动 Synology Drive Client" -ForegroundColor Green
Write-Host "  3. 如能正常打开登录界面 => 安装成功" -ForegroundColor Green
Write-Host ""
Write-Host "  如仍无法启动:" -ForegroundColor Yellow
Write-Host "  - 重启电脑后再试" -ForegroundColor Yellow
Write-Host "  - 临时关闭 360 后再试" -ForegroundColor Yellow
Write-Host "  - 确认 bin 目录下所有 exe 都已添加到 VxKex" -ForegroundColor Yellow
Write-Host ""
Write-Host "  下载的安装包保留在:" -ForegroundColor Gray
Write-Host "    $WorkDir" -ForegroundColor Gray
Write-Host "  可用于其他电脑离线部署 (无需重新下载)" -ForegroundColor Gray
Write-Host ""

try { Stop-Transcript } catch { }
exit 0
