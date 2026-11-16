# No top-level network, registry, service, process or file writes.
# Production entry point requires Windows PowerShell 5.1. Logic tests also run on PS7.
Set-StrictMode -Version 2.0

function Assert-InstallerPackage {
    param([System.Collections.IDictionary]$Package)
    if (-not $Package) { throw 'Missing package identity.' }
    foreach ($key in @('Id','Version','FileName','Url','Size','Sha256','SignaturePolicy','Publisher','Acceptance')) {
        if (-not $Package.Contains($key)) { throw "Missing package field: $key" }
    }
    if (@('Synology','VxKex') -notcontains $Package.Id) { throw 'Unknown package.' }
    if ($Package.Sha256 -notmatch '\A[0-9a-fA-F]{64}\z') { throw 'A fixed SHA256 is required.' }
    if ([string]$Package.Size -notmatch '\A[0-9]+\z' -or ($Package.Size -as [long]) -le 1MB) { throw 'Invalid exact package size.' }
    if ($Package.FileName -match '[\\/:*?"<>|]' -or $Package.FileName -match '\.\.' -or
        [string]::IsNullOrWhiteSpace($Package.FileName)) { throw 'Unsafe package filename.' }
    $uri = $null
    if (-not [Uri]::TryCreate($Package.Url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.UserInfo -or -not $uri.IsDefaultPort -or $uri.Query -or $uri.Fragment) {
        throw 'Expected an official HTTPS asset URL.'
    }
    if ($Package.Id -eq 'Synology') {
        if ($Package.Version -notmatch '\A\d+\.\d+\.\d+-\d+\z' -or
            $Package.FileName -cne "Synology Drive Client-$($Package.Version)-x86.exe" -or
            $Package.SignaturePolicy -ne 'Publisher' -or $Package.Publisher -cne 'Synology Inc.') {
            throw 'Invalid Synology identity or publisher policy.'
        }
        $expected = 'https://global.synologydownload.com/download/Utility/SynologyDriveClient/' +
            $Package.Version + '/Windows/Installer/i686/' + [Uri]::EscapeDataString($Package.FileName)
    } else {
        if ($Package.Version -notmatch '\A\d+\.\d+\.\d+\.\d+\z' -or
            $Package.FileName -cne ('KexSetup_Release_' + $Package.Version.Replace('.','_') + '.exe') -or
            $Package.SignaturePolicy -ne 'UnsignedPinned') { throw 'Only the pinned VxKex Release asset is allowed.' }
        $expected = 'https://github.com/YuZhouRen86/VxKex-NEXT/releases/download/' +
            $Package.Version + '/' + $Package.FileName
    }
    if ($Package.Url -cne $expected) { throw 'Package URL does not match its fixed identity.' }
    if ($Package.Acceptance -ne 'PendingWin7Validation') { throw 'Unknown deployment acceptance policy.' }
}

function Get-InstallerManifest {
    param([string]$Path)
    $data = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    if ($data.SchemaVersion -ne 1 -or @($data.Packages).Count -ne 2) { throw 'Unsupported installer manifest.' }
    $ids = @{}
    foreach ($package in $data.Packages) {
        Assert-InstallerPackage $package
        if ($ids.ContainsKey($package.Id)) { throw 'Duplicate package identity.' }
        $ids[$package.Id] = $true
    }
    return $data.Packages
}

function Get-FileSha256Lower {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
    } finally {
        if ($stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Test-InstallerFile {
    param([string]$Path, [System.Collections.IDictionary]$Package)
    Assert-InstallerPackage $Package
    $valid = $false
    $reason = 'Missing'
    $hash = $null
    try {
        if (Test-Path -LiteralPath $Path) {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $reason = 'NotRegularFile'
            } elseif ($item.Length -ne [long]$Package.Size) {
                $reason = 'SizeMismatch'
            } else {
                $hash = Get-FileSha256Lower $item.FullName
                $valid = ($hash -eq $Package.Sha256)
                $reason = if ($valid) { 'Verified' } else { 'HashMismatch' }
            }
        }
    } catch { $reason = 'Unreadable: ' + $_.Exception.Message }
    return [pscustomobject]@{ Valid=$valid; Reason=$reason; Sha256=$hash; Path=$Path }
}

function Get-AvailableDownloadMethods {
    # Never start, restart or reconfigure BITS. Use it only if already running.
    $methods = @()
    try {
        if ((Get-Service BITS -ErrorAction Stop).Status -eq 'Running') {
            Import-Module BitsTransfer -ErrorAction Stop
            if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) { $methods += 'Bits' }
        }
    } catch { }
    if (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue) { $methods += 'Direct' }
    return $methods
}

function Invoke-PackageTransfer {
    param([string]$Method, [string]$Url, [string]$Destination)
    if ($Method -eq 'Bits') {
        Start-BitsTransfer -Source $Url -Destination $Destination -ErrorAction Stop
    } else {
        $previousTls = [Net.ServicePointManager]::SecurityProtocol
        try {
            # Process-local only; never enable TLS 1.0/1.1 or touch system policy.
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        } finally { [Net.ServicePointManager]::SecurityProtocol = $previousTls }
    }
}

function Get-VerifiedPackage {
    param(
        [System.Collections.IDictionary]$Package,
        [string]$CacheDirectory,
        [switch]$Offline,
        [switch]$AllowGitHubMirror
    )
    Assert-InstallerPackage $Package
    $target = Join-Path $CacheDirectory $Package.FileName
    $cached = Test-InstallerFile $target $Package
    if ($cached.Valid) { return [IO.Path]::GetFullPath($target) }
    if ($Offline) { throw "$($Package.Id) offline cache rejected: $($cached.Reason)" }
    if (-not (Test-Path -LiteralPath $CacheDirectory)) {
        New-Item -ItemType Directory -Path $CacheDirectory -ErrorAction Stop | Out-Null
    }
    $directory = Get-Item -LiteralPath $CacheDirectory -Force -ErrorAction Stop
    if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Cache must be a regular directory.'
    }
    if (Test-Path -LiteralPath $target) {
        $item = Get-Item -LiteralPath $target -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Refusing to replace a directory or linked cache file.'
        }
    }
    $attempts = @()
    foreach ($method in @(Get-AvailableDownloadMethods)) {
        $attempts += [pscustomobject]@{ Method=$method; Url=$Package.Url }
    }
    if ($AllowGitHubMirror -and $Package.Id -eq 'VxKex' -and
        (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue)) {
        $attempts += [pscustomobject]@{ Method='Mirror'; Url=('https://gh-proxy.com/' + $Package.Url) }
    }
    $lastError = 'No supported download method.'
    foreach ($attempt in $attempts) {
        $part = Join-Path $CacheDirectory ('.' + [guid]::NewGuid().ToString('N') + '.part')
        try {
            try {
                Invoke-PackageTransfer $attempt.Method $attempt.Url $part | Out-Null
            } catch {
                $lastError = $_.Exception.Message
                Write-Warning "$($Package.Id) $($attempt.Method) transfer failed: $lastError"
                continue
            }
            $result = Test-InstallerFile $part $Package
            # Integrity failures stop the entire operation, without downgrading to another source.
            if (-not $result.Valid) { throw "$($Package.Id) integrity check failed: $($result.Reason)" }
            if ([IO.File]::Exists($target)) {
                [IO.File]::Replace($part, $target, [NullString]::Value)
            } else {
                [IO.File]::Move($part, $target)
            }
            # Revalidate the committed cache. Installation uses a separate protected staging area.
            if (-not (Test-InstallerFile $target $Package).Valid) { throw 'Cache changed after download.' }
            return [IO.Path]::GetFullPath($target)
        } finally {
            if (Test-Path -LiteralPath $part) {
                Remove-Item -LiteralPath $part -Force -ErrorAction Stop
            }
        }
    }
    throw "$($Package.Id) download failed: $lastError"
}

function Get-PackageSignatureInfo {
    param([string]$Path)
    return Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
}

function Assert-PackageSignature {
    param(
        [System.Collections.IDictionary]$Package,
        $Signature,
        [string]$UnsignedConsentSha256 = ''
    )
    Assert-InstallerPackage $Package
    if ($Package.SignaturePolicy -eq 'Publisher') {
        if ($Signature.Status.ToString() -ne 'Valid' -or -not $Signature.SignerCertificate -or
            $Signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne $Package.Publisher) {
            throw "$($Package.Id) requires a valid signature from $($Package.Publisher)."
        }
        return
    }
    # Only this exact, pinned, unsigned component may be explicitly acknowledged.
    # HashMismatch, NotTrusted and unknown statuses are never treated as unsigned exceptions.
    if ($Package.Id -ne 'VxKex' -or $Signature.Status.ToString() -ne 'NotSigned' -or
        $UnsignedConsentSha256 -cne $Package.Sha256) {
        throw 'Pinned VxKex requires an explicit acknowledgement of this exact SHA256; signature errors cannot be bypassed.'
    }
}

function New-PrivateStagingDirectory {
    # Direct child of protected Program Files: no predictable user-writable parent.
    $root = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    if (-not $root) { throw 'Program Files is unavailable.' }
    $parent = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked Program Files is not supported.' }
    $path = Join-Path $root ('SynologyDriveWin7-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $path) { throw 'Staging path already exists.' }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    [IO.Directory]::CreateDirectory($path, $acl) | Out-Null
    return $path
}

function Copy-VerifiedPackage {
    param([string]$Source, [string]$StagingDirectory, [System.Collections.IDictionary]$Package)
    Assert-InstallerPackage $Package
    $path = Join-Path $StagingDirectory $Package.FileName
    [IO.File]::Copy($Source, $path, $false)
    if (-not (Test-InstallerFile $path $Package).Valid) { throw 'Staged installer failed identity verification.' }
    return $path
}

function Start-InstallerProcess {
    param([string]$Path)
    return Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path) -Wait -PassThru -ErrorAction Stop
}

function Invoke-VerifiedInstaller {
    param([string]$Path, [System.Collections.IDictionary]$Package, [string]$UnsignedConsentSha256 = '')
    # Keep a non-write/non-delete-shared handle through verification and process exit.
    $guard = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if (-not (Test-InstallerFile $Path $Package).Valid) { throw 'Installer changed before execution.' }
        Assert-PackageSignature $Package (Get-PackageSignatureInfo $Path) $UnsignedConsentSha256
        $process = Start-InstallerProcess $Path
        if ($process.ExitCode -eq 3010 -or $process.ExitCode -eq 1641) {
            return [pscustomobject]@{ ExitCode=$process.ExitCode; RequiresReboot=$true }
        }
        if ($process.ExitCode -ne 0) { throw "Installer failed or was cancelled (exit $($process.ExitCode))." }
        return [pscustomobject]@{ ExitCode=0; RequiresReboot=$false }
    } finally { $guard.Dispose() }
}

function Get-InstalledComponent {
    param([System.Collections.IDictionary]$Package)
    Assert-InstallerPackage $Package
    $paths = @()
    if ($Package.Id -eq 'VxKex') {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
            $base = $null; $key = $null
            try {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
                $key = $base.OpenSubKey('SOFTWARE\VXsoft\VxKex')
                if ($key) {
                    $dir = [string]$key.GetValue('KexDir')
                    if ($dir -and [IO.Path]::IsPathRooted($dir)) { $paths += Join-Path $dir 'KexCfg.exe' }
                }
            } finally {
                if ($key) { $key.Dispose() }; if ($base) { $base.Dispose() }
            }
        }
        $paths += "$env:ProgramFiles\VxKex\KexCfg.exe"
        if (${env:ProgramFiles(x86)}) { $paths += "${env:ProgramFiles(x86)}\VxKex\KexCfg.exe" }
    } else {
        $paths += "$env:LOCALAPPDATA\SynologyDrive\SynologyDrive.app\SynologyDrive.exe"
        $paths += "$env:ProgramFiles\Synology\SynologyDrive\SynologyDrive.exe"
        if (${env:ProgramFiles(x86)}) { $paths += "${env:ProgramFiles(x86)}\Synology\SynologyDrive\SynologyDrive.exe" }
    }
    $found = @()
    foreach ($path in @($paths | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installed component is a linked file.' }
            $vi = $file.VersionInfo
            $version = '{0}.{1}.{2}.{3}' -f $vi.FileMajorPart,$vi.FileMinorPart,$vi.FileBuildPart,$vi.FilePrivatePart
            $found += [pscustomobject]@{ Path=$file.FullName; Version=$version; Matches=($version -eq $Package.Version.Replace('-','.')) }
        }
    }
    if ($found.Count -gt 1) { throw "Multiple $($Package.Id) installations found; resolve them manually." }
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}

function Assert-InstallerEnvironment {
    param([string]$Mode, [version]$PowerShellVersion, [string]$Edition, [bool]$Windows, [string]$OsVersion, [int]$ServicePack, [bool]$Administrator, [int]$ProductType = 1)
    if (-not $Windows -or $PowerShellVersion -lt [version]'5.1' -or $Edition -ne 'Desktop') {
        throw 'Use Windows PowerShell 5.1 (powershell.exe). PS2 and PowerShell Core are not installation hosts.'
    }
    if (@('CheckOnly','DownloadOnly','Install') -notcontains $Mode) { throw 'Unknown mode.' }
    if ($Mode -eq 'Install') {
        if ($OsVersion -notlike '6.1.*' -or $ServicePack -lt 1 -or $ProductType -ne 1) { throw 'Experimental installation is limited to Windows 7 SP1.' }
        if (-not $Administrator) { throw 'Install mode requires an elevated Windows PowerShell session.' }
    }
}

function Install-VerifiedComponent {
    param([string]$Path, [System.Collections.IDictionary]$Package, [string]$UnsignedConsentSha256 = '')
    $existing = Get-InstalledComponent $Package
    if ($existing) {
        if (-not $existing.Matches) { throw "$($Package.Id) has another installed version; review migration before proceeding." }
        return [pscustomobject]@{ State='AlreadyPresent'; Component=$existing; RequiresReboot=$false }
    }
    $result = Invoke-VerifiedInstaller $Path $Package $UnsignedConsentSha256
    if ($result.RequiresReboot) {
        return [pscustomobject]@{ State='PendingReboot'; Component=$null; RequiresReboot=$true }
    }
    $installed = Get-InstalledComponent $Package
    if (-not $installed -or -not $installed.Matches) {
        throw "$($Package.Id) exited with 0 but the expected installed version was not found (cancelled or incomplete installation)."
    }
    return [pscustomobject]@{ State='Installed'; Component=$installed; RequiresReboot=$false }
}

Export-ModuleMember -Function Get-InstallerManifest,Assert-InstallerPackage,Get-FileSha256Lower,Test-InstallerFile,Get-VerifiedPackage,Get-PackageSignatureInfo,Assert-PackageSignature,New-PrivateStagingDirectory,Copy-VerifiedPackage,Invoke-VerifiedInstaller,Install-VerifiedComponent,Get-InstalledComponent,Assert-InstallerEnvironment
