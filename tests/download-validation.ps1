# Offline tests: only synthetic bytes and in-memory fakes. Never dot-source the entry point.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $root 'lib/Installer.Core.psm1') -Force -PassThru
$manifest = @(Get-InstallerManifest (Join-Path $root 'config/installers.psd1'))
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('synology-offline-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:count = 0
$payload = New-Object byte[] (2MB + 4)
$fixture = Join-Path $tmp 'fixture.bin'
[IO.File]::WriteAllBytes($fixture, $payload)
$fixtureHash = Get-FileSha256Lower $fixture

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action)
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    if (-not $thrown) { throw 'Expected a failure, but operation succeeded.' }
}
function New-Signature {
    param([string]$Status, [string]$Publisher = '')
    $cert = [pscustomobject]@{ Name=$Publisher }
    $cert | Add-Member -MemberType ScriptMethod -Name GetNameInfo -Value { param($Kind,$Issuer) return $this.Name }
    return [pscustomobject]@{ Status=$Status; SignerCertificate=$cert }
}
function Reset-Case {
    $script:caseDir = Join-Path $tmp ('Chinese path 空格 ' + [guid]::NewGuid().ToString('N'))
    $script:package = $manifest[1].Clone()
    $script:package.Size = $payload.Length
    $script:package.Sha256 = $fixtureHash
    $script:state = @{
        Methods=@('Bits','Direct'); Calls=@(); Behaviors=@{}; Payload=$payload
        Signature=(New-Signature 'NotSigned'); Starts=0; ExitCode=0
        Probes=0; InstalledBefore=$null; InstalledAfter=$null
    }
    & $module { param($State) $script:TestState = $State } $script:state
}
function Write-Cache {
    param([byte[]]$Bytes)
    New-Item -ItemType Directory -Path $script:caseDir -Force | Out-Null
    $path = Join-Path $script:caseDir $script:package.FileName
    [IO.File]::WriteAllBytes($path, $Bytes)
    return $path
}
function Test-Case {
    param([string]$Name, [scriptblock]$Test)
    Reset-Case
    & $Test
    $script:count++
    Write-Output ('PASS ' + $Name)
}

# Replacements live only in this imported module instance. No real networking or installers.
& $module {
    function script:Get-AvailableDownloadMethods { return $script:TestState.Methods }
    function script:Invoke-PackageTransfer {
        param($Method,$Url,$Destination)
        $script:TestState.Calls += [pscustomobject]@{ Method=$Method; Url=$Url; Path=$Destination }
        $behavior = $script:TestState.Behaviors[$Method]
        if (-not $behavior) { $behavior = 'Good' }
        switch ($behavior) {
            'Throw' { throw 'synthetic transfer failure' }
            'PartialThrow' {
                [IO.File]::WriteAllBytes($Destination, (New-Object byte[] (1MB + 1)))
                throw 'synthetic interruption after a large partial file'
            }
            'NoFile' { return }
            'WrongHash' {
                $bytes = $script:TestState.Payload.Clone(); $bytes[0] = 1
                [IO.File]::WriteAllBytes($Destination, $bytes)
            }
            default {
                if ($behavior -like 'Size:*') {
                    [IO.File]::WriteAllBytes($Destination, (New-Object byte[] ([int]$behavior.Substring(5))))
                } else { [IO.File]::WriteAllBytes($Destination, $script:TestState.Payload) }
            }
        }
    }
    function script:Get-PackageSignatureInfo { param($Path) return $script:TestState.Signature }
    function script:Start-InstallerProcess {
        param($Path)
        $script:TestState.Starts++
        return [pscustomobject]@{ ExitCode=$script:TestState.ExitCode }
    }
    function script:Get-InstalledComponent {
        param($Package)
        $script:TestState.Probes++
        if ($script:TestState.Probes -eq 1) { return $script:TestState.InstalledBefore }
        return $script:TestState.InstalledAfter
    }
}

try {
    foreach ($method in @('Bits','Direct','Mirror')) {
        foreach ($size in @(0,1024,1048576,1048577)) {
            Test-Case "$method rejects size $size" {
                if ($method -eq 'Mirror') {
                    $state.Methods=@('Direct'); $state.Behaviors.Direct='Throw'
                } else { $state.Methods=@($method) }
                $state.Behaviors[$method] = 'Size:' + $size
                Assert-Throws { Get-VerifiedPackage $package $caseDir -AllowGitHubMirror:($method -eq 'Mirror') }
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $caseDir $package.FileName))) 'Bad download became cache.'
                Assert-True (@(Get-ChildItem -LiteralPath $caseDir -Force).Count -eq 0) 'Partial file survived.'
            }
        }
        Test-Case "$method rejects same-size wrong hash" {
            if ($method -eq 'Mirror') { $state.Methods=@('Direct'); $state.Behaviors.Direct='Throw' }
            else { $state.Methods=@($method) }
            $state.Behaviors[$method]='WrongHash'
            Assert-Throws { Get-VerifiedPackage $package $caseDir -AllowGitHubMirror:($method -eq 'Mirror') }
            Assert-True (@(Get-ChildItem -LiteralPath $caseDir -Force).Count -eq 0) 'Rejected payload survived.'
        }
        Test-Case "$method accepts exact synthetic identity" {
            if ($method -eq 'Mirror') { $state.Methods=@('Direct'); $state.Behaviors.Direct='Throw' }
            else { $state.Methods=@($method) }
            $path = Get-VerifiedPackage $package $caseDir -AllowGitHubMirror:($method -eq 'Mirror')
            Assert-True ((Test-InstallerFile $path $package).Valid) 'Valid data rejected.'
            Assert-True ($state.Starts -eq 0) 'Downloader executed an installer.'
        }
        Test-Case "$method interrupted large payload is cleaned" {
            if ($method -eq 'Mirror') { $state.Methods=@('Direct'); $state.Behaviors.Direct='Throw' }
            else { $state.Methods=@($method) }
            $state.Behaviors[$method]='PartialThrow'
            Assert-Throws { Get-VerifiedPackage $package $caseDir -AllowGitHubMirror:($method -eq 'Mirror') }
            Assert-True (@(Get-ChildItem -LiteralPath $caseDir -Force).Count -eq 0) 'Large partial retained.'
            Assert-Throws { Get-VerifiedPackage $package $caseDir -Offline }
        }
    }
    Test-Case 'wrong hash stops fallback, even when mirror is enabled' {
        $state.Behaviors.Bits='WrongHash'
        Assert-Throws { Get-VerifiedPackage $package $caseDir -AllowGitHubMirror }
        Assert-True ($state.Calls.Count -eq 1) 'Integrity failure downgraded to another transport.'
    }
    Test-Case 'BITS exception falls back to direct and clears partial' {
        $state.Behaviors.Bits='PartialThrow'
        $path = Get-VerifiedPackage $package $caseDir
        Assert-True ((Test-InstallerFile $path $package).Valid) 'Fallback did not produce verified bytes.'
        Assert-True ($state.Calls.Count -eq 2) 'Unexpected fallback count.'
        Assert-True (@(Get-ChildItem -LiteralPath $caseDir -Force).Count -eq 1) 'Partial survived successful fallback.'
    }
    Test-Case 'mirror is off by default' {
        $state.Methods=@('Direct'); $state.Behaviors.Direct='Throw'
        Assert-Throws { Get-VerifiedPackage $package $caseDir }
        Assert-True ($state.Calls.Count -eq 1 -and $state.Calls[0].Method -eq 'Direct') 'Mirror used without opt-in.'
    }
    Test-Case 'Synology never uses GitHub mirror' {
        $package = $manifest[0].Clone(); $package.Size=$payload.Length; $package.Sha256=$fixtureHash
        $state.Methods=@('Direct'); $state.Behaviors.Direct='Throw'
        Assert-Throws { Get-VerifiedPackage $package $caseDir -AllowGitHubMirror }
        Assert-True ($state.Calls.Count -eq 1) 'Synology unexpectedly used a mirror.'
    }
    Test-Case 'missing digest fails before file writes or network' {
        $package.Sha256=''
        Assert-Throws { Get-VerifiedPackage $package $caseDir }
        Assert-True ($state.Calls.Count -eq 0 -and -not (Test-Path -LiteralPath $caseDir)) 'Missing digest had side effects.'
    }
    foreach ($mutation in @('Debug','Traversal','Http','OtherHost','WrongVersion','UnknownPolicy','BadSize')) {
        Test-Case "invalid manifest $mutation" {
            switch ($mutation) {
                'Debug' { $package.FileName=$package.FileName.Replace('Release','Debug') }
                'Traversal' { $package.FileName='..\other.exe' }
                'Http' { $package.Url=$package.Url.Replace('https:','http:') }
                'OtherHost' { $package.Url=$package.Url.Replace('github.com','example.invalid') }
                'WrongVersion' { $package.Version='9.9.9.9' }
                'UnknownPolicy' { $package.SignaturePolicy='Ignore' }
                'BadSize' { $package.Size='2097156.1' }
            }
            Assert-Throws { Get-VerifiedPackage $package $caseDir }
            Assert-True ($state.Calls.Count -eq 0) 'Malformed manifest reached network.'
        }
    }
    Test-Case 'verified cache works offline without network' {
        $cached=Write-Cache $payload
        $path=Get-VerifiedPackage $package $caseDir -Offline
        Assert-True ($path -eq $cached -and $state.Calls.Count -eq 0) 'Verified offline cache not reused.'
    }
    Test-Case 'corrupt cache refuses offline use' {
        $bytes=$payload.Clone();$bytes[2]=1;Write-Cache $bytes | Out-Null
        Assert-Throws { Get-VerifiedPackage $package $caseDir -Offline }
        Assert-True ($state.Calls.Count -eq 0) 'Offline rejection tried network.'
    }
    Test-Case 'online download atomically replaces corrupt cache' {
        Write-Cache (New-Object byte[] (1MB + 1)) | Out-Null
        $path=Get-VerifiedPackage $package $caseDir
        Assert-True ((Test-InstallerFile $path $package).Valid) 'Bad cache not replaced.'
    }
    Test-Case 'offline missing cache creates no directory' {
        Assert-Throws { Get-VerifiedPackage $package $caseDir -Offline }
        Assert-True (-not (Test-Path -LiteralPath $caseDir)) 'Offline attempt created directory.'
    }
    Test-Case 'unrelated Debug and older cache are not selected' {
        New-Item -ItemType Directory -Path $caseDir | Out-Null
        foreach ($name in @('KexSetup_Debug_1_2_3_2466.exe','KexSetup_Release_1_2_0_2226.exe')) {
            [IO.File]::WriteAllBytes((Join-Path $caseDir $name),$payload)
        }
        Assert-Throws { Get-VerifiedPackage $package $caseDir -Offline }
    }
    Test-Case 'directory with expected filename is rejected' {
        New-Item -ItemType Directory -Path (Join-Path $caseDir $package.FileName) -Force | Out-Null
        Assert-Throws { Get-VerifiedPackage $package $caseDir }
        Assert-True ($state.Calls.Count -eq 0) 'Directory target reached download.'
    }
    Test-Case 'regular read-only check creates no files' {
        $r=Test-InstallerFile (Join-Path $caseDir $package.FileName) $package
        Assert-True (-not $r.Valid -and -not (Test-Path -LiteralPath $caseDir)) 'Read-only identity check wrote files.'
    }
    Test-Case 'valid Synology publisher accepted' {
        Assert-PackageSignature $manifest[0] (New-Signature 'Valid' 'Synology Inc.')
    }
    Test-Case 'valid signature from wrong publisher refused' {
        Assert-Throws { Assert-PackageSignature $manifest[0] (New-Signature 'Valid' 'Someone else') }
    }
    foreach ($status in @('NotSigned','HashMismatch','NotTrusted','UnknownError')) {
        Test-Case "Synology signature $status refused" {
            Assert-Throws { Assert-PackageSignature $manifest[0] (New-Signature $status 'Synology Inc.') }
        }
    }
    Test-Case 'unsigned VxKex requires exact per-run acknowledgement' {
        Assert-Throws { Assert-PackageSignature $package (New-Signature 'NotSigned') }
        Assert-Throws { Assert-PackageSignature $package (New-Signature 'NotSigned') ('a'*64) }
        Assert-PackageSignature $package (New-Signature 'NotSigned') $package.Sha256
    }
    foreach ($status in @('HashMismatch','NotTrusted','UnknownError','Valid')) {
        Test-Case "VxKex signature $status cannot be bypassed by acknowledgement" {
            Assert-Throws { Assert-PackageSignature $package (New-Signature $status) $package.Sha256 }
        }
    }
    Test-Case 'changed installer blocked before process start' {
        $path=Write-Cache $payload
        $bytes=$payload.Clone();$bytes[0]=2;[IO.File]::WriteAllBytes($path,$bytes)
        Assert-Throws { Invoke-VerifiedInstaller $path $package $package.Sha256 }
        Assert-True ($state.Starts -eq 0) 'Changed bytes executed.'
    }
    Test-Case 'no acknowledgement blocks process start' {
        $path=Write-Cache $payload
        Assert-Throws { Invoke-VerifiedInstaller $path $package }
        Assert-True ($state.Starts -eq 0) 'Unsigned bytes executed without acknowledgement.'
    }
    Test-Case 'installer nonzero exit fails' {
        $path=Write-Cache $payload;$state.ExitCode=1602
        Assert-Throws { Invoke-VerifiedInstaller $path $package $package.Sha256 }
        Assert-True ($state.Starts -eq 1) 'Expected exactly one fake launch.'
    }
    Test-Case 'zero exit with missing component is not success' {
        $path=Write-Cache $payload
        Assert-Throws { Install-VerifiedComponent $path $package $package.Sha256 }
        Assert-True ($state.Starts -eq 1) 'Unexpected fake launch count.'
    }
    Test-Case 'installed version must match after zero exit' {
        $path=Write-Cache $payload
        $state.InstalledAfter=[pscustomobject]@{ Matches=$false; Version='0.0.0.0'; Path='synthetic' }
        Assert-Throws { Install-VerifiedComponent $path $package $package.Sha256 }
    }
    Test-Case 'successful fake install requires postcondition' {
        $path=Write-Cache $payload
        $state.InstalledAfter=[pscustomobject]@{ Matches=$true; Version=$package.Version; Path='synthetic' }
        $r=Install-VerifiedComponent $path $package $package.Sha256
        Assert-True ($r.State -eq 'Installed' -and $state.Starts -eq 1) 'Verified postcondition not accepted.'
    }
    Test-Case 'existing other version blocks execution' {
        $state.InstalledBefore=[pscustomobject]@{ Matches=$false }
        Assert-Throws { Install-VerifiedComponent 'unused' $package $package.Sha256 }
        Assert-True ($state.Starts -eq 0) 'Existing version overwritten.'
    }
    Test-Case 'existing exact version is explicitly already present' {
        $state.InstalledBefore=[pscustomobject]@{ Matches=$true }
        $r=Install-VerifiedComponent 'unused' $package $package.Sha256
        Assert-True ($r.State -eq 'AlreadyPresent' -and $state.Starts -eq 0) 'Existing version reinstalled.'
    }
    foreach ($code in @(3010,1641)) {
        Test-Case "reboot exit $code stops at pending state" {
            $path=Write-Cache $payload;$state.ExitCode=$code
            $r=Install-VerifiedComponent $path $package $package.Sha256
            Assert-True ($r.RequiresReboot -and $r.State -eq 'PendingReboot') 'Reboot reported as completed install.'
        }
    }
    Test-Case 'staging copy revalidates source bytes' {
        $source=Write-Cache $payload
        $stage=Join-Path $tmp ([guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $stage | Out-Null
        $copy=Copy-VerifiedPackage $source $stage $package
        Assert-True ((Test-InstallerFile $copy $package).Valid) 'Staging copy mismatch.'
        [IO.File]::WriteAllBytes($source,(New-Object byte[] 10))
        $secondStage=Join-Path $tmp ([guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $secondStage | Out-Null
        Assert-Throws { Copy-VerifiedPackage $source $secondStage $package }
        Assert-True (Test-Path -LiteralPath (Join-Path $secondStage $package.FileName)) 'Copy was not reached; expected identity validation to reject copied bytes.'
    }
    Test-Case 'PS2 is explicitly unsupported' {
        Assert-Throws { Assert-InstallerEnvironment CheckOnly ([version]'2.0') Desktop $true '6.1.7601' 1 $false }
    }
    Test-Case 'PowerShell Core is not a Windows installation host' {
        Assert-Throws { Assert-InstallerEnvironment Install ([version]'7.7') Core $true '6.1.7601' 1 $true }
    }
    Test-Case 'non-Windows is rejected' {
        Assert-Throws { Assert-InstallerEnvironment Install ([version]'5.1') Desktop $false '6.1.7601' 1 $true }
    }
    Test-Case 'Windows 7 without SP1 is rejected' {
        Assert-Throws { Assert-InstallerEnvironment Install ([version]'5.1') Desktop $true '6.1.7600' 0 $true }
    }
    Test-Case 'Windows Server is rejected despite version 6.1' {
        Assert-Throws { Assert-InstallerEnvironment Install ([version]'5.1') Desktop $true '6.1.7601' 1 $true 3 }
    }
    Test-Case 'non-administrator can check and download but not install' {
        Assert-InstallerEnvironment CheckOnly ([version]'5.1') Desktop $true '10.0.0' 0 $false
        Assert-InstallerEnvironment DownloadOnly ([version]'5.1') Desktop $true '10.0.0' 0 $false
        Assert-Throws { Assert-InstallerEnvironment Install ([version]'5.1') Desktop $true '6.1.7601' 1 $false }
    }
    Test-Case 'Windows 10 install is rejected' {
        Assert-Throws { Assert-InstallerEnvironment Install ([version]'5.1') Desktop $true '10.0.0' 0 $true }
    }
    Test-Case 'Win7 SP1 Windows PowerShell 5.1 administrator passes environment gate only' {
        Assert-InstallerEnvironment Install ([version]'5.1') Desktop $true '6.1.7601' 1 $true
    }
    Write-Output "$script:count offline regressions passed; synthetic data only; no installers or real network executed."
} finally {
    Remove-Module $module -Force
    Remove-Item -LiteralPath $tmp -Recurse -Force
}
