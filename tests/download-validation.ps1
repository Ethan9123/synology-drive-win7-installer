# Offline only: extract the downloader function AST, never execute installer top-level code.
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '../安装Synology Drive Client.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Get-RemoteFile', 'Get-FileSha256Lower', 'ConvertTo-GitHubMirrorUrl')) {
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $fn) { throw "Missing function: $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Write-Step {}
function Write-Info {}
function Write-Warn {}
function Write-Err {}
function Ensure-BitsService { return $script:Via -eq 'bits' }
function Import-Module {}
function Start-BitsTransfer {
    param($Source, $Destination, $DisplayName, $Description, $ErrorAction)
    [IO.File]::WriteAllBytes($Destination, (New-Object byte[] $script:PayloadSize))
}
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec)
    if ($script:Via -eq 'mirror' -and $Uri -notlike 'https://gh-proxy.com/*') { throw 'synthetic direct failure' }
    [IO.File]::WriteAllBytes($OutFile, (New-Object byte[] $script:PayloadSize))
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory $tmp | Out-Null
$count = 0
try {
    foreach ($via in @('bits', 'direct', 'mirror')) {
        $script:Via = $via
        foreach ($size in @(0, 1024, 1048576, 1048577)) {
            $script:PayloadSize = $size
            $out = Join-Path $tmp 'synthetic.exe'
            Remove-Item $out -Force -ErrorAction SilentlyContinue
            $ok = Get-RemoteFile -Url 'https://github.com/example/example/releases/download/test/synthetic.exe' -OutFile $out -Description 'offline fixture'
            if ([bool]$ok -ne ($size -gt 1MB)) { throw "$via size $size returned $ok" }
            if ($size -le 1MB -and (Test-Path $out)) { throw "$via retained incomplete payload" }
            $count++
        }
        # Nonempty responses must still pass the existing fixed digest.
        Remove-Item $out -Force -ErrorAction SilentlyContinue
        $ok = Get-RemoteFile -Url 'https://github.com/example/example/releases/download/test/synthetic.exe' -OutFile $out -Description 'offline hash fixture' -ExpectedSha256 ('0' * 64)
        if ($ok -or (Test-Path $out)) { throw "$via accepted wrong digest" }
        $count++
    }
    Write-Output "$count offline download regressions passed; no installers executed."
} finally {
    Remove-Item $tmp -Recurse -Force
}
