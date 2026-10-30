param([Parameter(Mandatory=$true)][string]$NucleusRoot,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
if(-not $OutputDirectory){$OutputDirectory=Join-Path $repo 'build'}
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$json=Join-Path $NucleusRoot 'Newtonsoft.Json.dll'
foreach($file in @($csc,$json)){if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Required file missing: $file"}}
[void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory))
& $csc /nologo /target:library /platform:anycpu "/out:$OutputDirectory\VRisingSettings.dll" "/reference:$json" (Join-Path $repo 'games\v-rising\src\VRisingSettings.cs')
if($LASTEXITCODE -ne 0){throw 'V Rising settings helper compilation failed'}
Write-Output "Built VRisingSettings.dll in $OutputDirectory"
