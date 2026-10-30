#Requires -Version 5.0
$ErrorActionPreference = 'Stop'
Import-Module ps2exe
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$in = Join-Path $here 'CreateShortcuts.ps1'
$out = Join-Path $here 'CreateShortcuts.exe'
if (-not (Test-Path -LiteralPath $in)) { throw "missing CreateShortcuts.ps1 at $in" }
Invoke-ps2exe -inputFile $in -outputFile $out -noConsole -title 'MultiAccount' -description 'Multi account shortcuts' -company 'local' -product 'MultiAccount' -version '1.0.1.0'
$item = Get-Item -LiteralPath $out
Write-Output ("BUILT|" + $item.FullName + "|" + $item.Length)
