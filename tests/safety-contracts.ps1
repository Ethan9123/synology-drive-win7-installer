$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1','.psd1') })
$forbidden = @('Set-ItemProperty','New-ItemProperty','Remove-ItemProperty','Set-Service','Start-Service','Restart-Service','Set-MpPreference','Add-MpPreference','Set-ExecutionPolicy')
foreach ($file in $files) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    if ($file.DirectoryName -eq (Join-Path $root 'tests')) { continue }
    foreach ($command in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] },$true)) {
        if ($forbidden -contains $command.GetCommandName()) { throw "Unexpected system mutation command in $($file.Name): $($command.GetCommandName())" }
    }
}
$main=[IO.File]::ReadAllText((Join-Path $root 'Install-SynologyDrive.ps1'))
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($main,[ref]$tokens,[ref]$errors)
$mode=$ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' }
if ($mode.DefaultValue.Value -ne 'CheckOnly') { throw 'Entry point must default to CheckOnly.' }
$core=[IO.File]::ReadAllText((Join-Path $root 'lib/Installer.Core.psm1'))
$ast=[Management.Automation.Language.Parser]::ParseInput($core,[ref]$tokens,[ref]$errors)
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { continue }
    $calls=@($statement.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] },$true))
    if ($calls.Count -ne 1 -or @('Set-StrictMode','Export-ModuleMember') -notcontains $calls[0].GetCommandName()) {
        throw 'Core module acquired an unexpected top-level action.'
    }
}
Write-Output "$($files.Count) PowerShell files parsed; read-only default and module side-effect contracts passed."
