# Windows PowerShell 5.1 only. Never invoke Install mode.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$entry = Join-Path $root 'Install-SynologyDrive.ps1'
$cache = Join-Path ([IO.Path]::GetTempPath()) ('synology-should-not-exist-' + [guid]::NewGuid().ToString('N'))
try {
    & powershell.exe -NoProfile -File $entry -CacheDirectory $cache
    if ($LASTEXITCODE -ne 0) { throw "Default CheckOnly failed: $LASTEXITCODE" }
    if (Test-Path -LiteralPath $cache) { throw 'CheckOnly created its cache/log directory.' }
    # A missing offline cache must fail without creating files or falling back to network.
    # Native stderr on Windows PowerShell can become a terminating NativeCommandError;
    # capture it with Continue and assert the explicit native exit code instead.
    $ErrorActionPreference = 'Continue'
    $output = & powershell.exe -NoProfile -File $entry -Mode DownloadOnly -Offline -CacheDirectory $cache 2>&1
    $offlineExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($offlineExit -eq 0) { throw 'Missing offline cache reported success.' }
    if (Test-Path -LiteralPath $cache) { throw 'Offline preparation created a cache/log directory.' }
    Write-Output 'Default CheckOnly and missing-cache Offline entry-point checks passed; no Install invocation.'
} finally {
    if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Recurse -Force }
}
# GitHub's PowerShell wrapper propagates LASTEXITCODE. The deliberately failing
# offline child was already asserted above; it must not become this suite's exit code.
exit 0
