param([Parameter(Mandatory=$true)][string]$NucleusRoot,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
if(-not $OutputDirectory){$OutputDirectory=Join-Path $repo 'build'}
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
foreach($file in @($csc,(Join-Path $NucleusRoot 'Nucleus.Gaming.dll'),(Join-Path $NucleusRoot 'WindowScrape.dll'))){if(-not(Test-Path -LiteralPath $file)){throw "Missing required file: $file"}}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
& $csc /nologo /target:library /platform:anycpu "/out:$OutputDirectory\NucleusDesktopBridge-v5.dll" "/reference:$NucleusRoot\Nucleus.Gaming.dll" "/reference:$NucleusRoot\WindowScrape.dll" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll (Join-Path $repo 'common\src\NucleusDesktopBridge.cs')
if($LASTEXITCODE -ne 0){throw 'Bridge compilation failed'}
& $csc /nologo /target:winexe "/out:$OutputDirectory\NucleusWindows.exe" /reference:System.Windows.Forms.dll (Join-Path $repo 'common\src\NucleusDesktopCommand.cs')
if($LASTEXITCODE -ne 0){throw 'Desktop dispatcher compilation failed'}
& $csc /nologo /target:exe "/out:$OutputDirectory\AudioCheck.exe" "/reference:$NucleusRoot\NAudio.dll" (Join-Path $repo 'common\src\AudioCheck.cs')
if($LASTEXITCODE -ne 0){throw 'Audio diagnostic compilation failed'}
Write-Output "Build ready: $OutputDirectory"
