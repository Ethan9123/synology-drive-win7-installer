[CmdletBinding()]
param(
    [ValidateSet('CheckOnly','DownloadOnly','Install')][string]$Mode = 'CheckOnly',
    [switch]$Offline,
    [switch]$AllowGitHubMirror,
    [string]$CacheDirectory = ''
)
# Legacy filename kept for existing shortcuts. Default is read-only.
$entry = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Install-SynologyDrive.ps1'
& $entry @PSBoundParameters
exit $LASTEXITCODE
