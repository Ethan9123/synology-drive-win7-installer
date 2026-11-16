[CmdletBinding()]
param(
    [ValidateSet('CheckOnly','DownloadOnly','Install')]
    [string]$Mode = 'CheckOnly',
    [switch]$Offline,
    [switch]$AllowGitHubMirror,
    [string]$CacheDirectory = ''
)

# This gate deliberately precedes module loading, directory creation and all system queries.
if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    [Console]::Error.WriteLine('需要 Windows PowerShell 5.1。PS 2.0 不受支持；未修改系统。请阅读 README。')
    exit 2
}
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop') {
    [Console]::Error.WriteLine('请使用 Windows PowerShell 5.1 (powershell.exe)，不是 pwsh。未修改系统。')
    exit 2
}

$ErrorActionPreference = 'Stop'
$staging = $null
$transcriptStarted = $false
$exitCode = 0
function Write-Ui { param([string]$Text) [Console]::WriteLine($Text) }

try {
    Import-Module (Join-Path $PSScriptRoot 'lib/Installer.Core.psm1') -Force -ErrorAction Stop
    $packages = @(Get-InstallerManifest (Join-Path $PSScriptRoot 'config/installers.psd1'))
    if (-not $CacheDirectory) { $CacheDirectory = Join-Path $PSScriptRoot 'downloads' }
    $CacheDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CacheDirectory)
    if ($Offline -and $AllowGitHubMirror) { throw 'Offline 与 AllowGitHubMirror 不能同时使用。' }

    $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }
    Assert-InstallerEnvironment $Mode $PSVersionTable.PSVersion $PSVersionTable.PSEdition $true $os.Version $os.ServicePackMajorVersion $admin $os.ProductType

    Write-Ui ('模式: ' + $Mode)
    Write-Ui ('系统: ' + $os.Caption + ' / ' + $os.Version + ' / SP' + $os.ServicePackMajorVersion)
    Write-Ui ('PowerShell: ' + $PSVersionTable.PSVersion + '  管理员: ' + $admin)
    Write-Ui ('缓存: ' + $CacheDirectory)
    Write-Ui '本工具不关闭安全防护、不添加排除、不修改 TLS 注册表或 BITS 配置。'
    Write-Ui 'Win7 已停止支持；以下固定版本组合尚未通过实机部署验收。'
    foreach ($package in $packages) {
        $check = Test-InstallerFile (Join-Path $CacheDirectory $package.FileName) $package
        Write-Ui ("{0} {1}: 缓存 {2}" -f $package.Id,$package.Version,$check.Reason)
        Write-Ui ('  SHA256: ' + $package.Sha256)
    }

    if ($Mode -eq 'CheckOnly') {
        Write-Ui ''
        Write-Ui '只读检查结束：没有下载、运行安装器、写日志或修改系统。此结果不等于可以部署。'
        Write-Ui '准备安装包: powershell.exe -NoProfile -File .\Install-SynologyDrive.ps1 -Mode DownloadOnly'
        Write-Ui '测试机安装: 先阅读 docs/ACCEPTANCE.md，再在管理员 PowerShell 中使用 -Mode Install -Offline。'
    } else {
        $consentHash = ''
        if ($Mode -eq 'Install') {
            $kex = $packages | Where-Object { $_.Id -eq 'VxKex' }
            Write-Ui ''
            Write-Ui '仅供已备份的隔离 Win7 SP1 测试机使用，不连接生产 NAS。'
            Write-Ui ('VxKex ' + $kex.Version + ' 未嵌入发布者签名；固定哈希不证明它没有恶意行为。')
            Write-Ui '其安装涉及系统目录 DLL、IFEO、计划任务和 Explorer 注入。'
            Write-Ui '如安全软件报警，请停止并核查，不关闭防护或给整个目录加白名单。'
            Write-Ui '继续表示你已审查这个具体样本并接受上述测试范围；只对本次运行有效。'
            $consentHash = Read-Host '请输入上方 VxKex 的完整 SHA256 确认；其他输入取消'
            if ($consentHash -cne $kex.Sha256) { throw '未确认指定 VxKex 样本，已取消，未运行安装器。' }
            foreach ($package in $packages) {
                $existing = Get-InstalledComponent $package
                if ($existing -and -not $existing.Matches) {
                    throw "$($package.Id) 已有其他版本。为避免影响已有程序，请先单独评估迁移。"
                }
            }
        }

        $cachePaths = @{}
        foreach ($package in $packages) {
            Write-Ui ('验证/准备: ' + $package.FileName)
            $cachePaths[$package.Id] = Get-VerifiedPackage $package $CacheDirectory -Offline:$Offline -AllowGitHubMirror:$AllowGitHubMirror
        }
        if ($Mode -eq 'DownloadOnly') {
            Write-Ui '两个固定安装包均已通过大小与 SHA256 校验，未运行。'
            Write-Ui '下载成功不代表签名、杀软共存或 Win7 功能验收通过；安装时还会复核。'
        } else {
            $staging = New-PrivateStagingDirectory
            try {
                Start-Transcript -Path (Join-Path $CacheDirectory ('install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')) -ErrorAction Stop | Out-Null
                $transcriptStarted = $true
            } catch { Write-Ui ('无法写入安装日志: ' + $_.Exception.Message) }
            $stagedPaths = @{}
            # Validate BOTH packages and signature policies before either installer can run.
            foreach ($package in $packages) {
                $stagedPaths[$package.Id] = Copy-VerifiedPackage $cachePaths[$package.Id] $staging $package
                $sig = Get-PackageSignatureInfo $stagedPaths[$package.Id]
                Write-Ui ("{0} 签名状态: {1}" -f $package.Id,$sig.Status)
                Assert-PackageSignature $package $sig $consentHash
            }
            $installed = @{}
            foreach ($id in @('VxKex','Synology')) {
                $package = $packages | Where-Object { $_.Id -eq $id }
                Write-Ui ('即将处理 ' + $package.FileName + '；安装窗口中的取消会被检查。')
                $result = Install-VerifiedComponent $stagedPaths[$id] $package $consentHash
                if ($result.RequiresReboot) {
                    Write-Ui '安装器要求重启；已停止后续步骤。重启后重新核查，不自动重启。'
                    $exitCode = 3010
                    break
                }
                $installed[$id] = $result.Component
                Write-Ui ($id + ': ' + $result.State + ' / ' + $result.Component.Version)
            }
            if ($exitCode -eq 0) {
                Write-Ui ''
                Write-Ui '已找到两个组件的预期版本。兼容层配置与文件同步验收仍未完成。'
                Write-Ui ('VxKex 设置程序: ' + $installed['VxKex'].Path)
                Write-Ui ('Synology 主程序: ' + $installed['Synology'].Path)
                Write-Ui '请从开始菜单打开 VxKex NEXT Global Settings，为需要的 Synology 程序配置兼容层。'
                Write-Ui '按 docs/ACCEPTANCE.md 验证测试文件同步、重启与卸载回退；不要仅凭登录页判断成功。'
                Write-Ui '自启动由用户在 Synology 设置中启用；本流程不自动创建启动项，也不自动启动同步客户端。'
            }
        }
    }
} catch {
    [Console]::Error.WriteLine('[停止] ' + $_.Exception.Message)
    $exitCode = 1
} finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    if ($staging -and (Test-Path -LiteralPath $staging)) {
        try { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop }
        catch { [Console]::Error.WriteLine('临时目录清理失败，请检查: ' + $staging); if ($exitCode -eq 0) { $exitCode = 1 } }
    }
}
exit $exitCode
