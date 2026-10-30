param([Parameter(Mandatory=$true)][string]$Config)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
if(Get-Process -Name NucleusCoop,VRising,VRisingServer,dontstarve_steam_x64 -ErrorAction SilentlyContinue){throw 'Save and close games and Nucleus before installing.'}
. (Join-Path $PSScriptRoot 'VRising-Configuration.ps1')
$settings=Get-VRisingConfiguration -Config $Config
$plan=@(Get-VRisingSavePlan -Settings $settings) # Preflight both links; this does not create or migrate saves.
$root=$settings.Root
$handler=Join-Path $root 'handlers\V Rising.js'
$patch=Join-Path $repo 'games\v-rising\handler.patch'
$git=(Get-Command git -ErrorAction Stop).Source
& $git -C $root apply --check --ignore-space-change --ignore-whitespace $patch
if($LASTEXITCODE -ne 0){throw 'Patch does not match the official V Rising v6 handler. No installed files changed.'}
& (Join-Path $PSScriptRoot 'Build-Tools.ps1') -NucleusRoot $root
& (Join-Path $PSScriptRoot 'Build-VRisingSettings.ps1') -NucleusRoot $root
$backup=Join-Path $root ('setup\backups\VRising-'+(Get-Date -Format yyyyMMdd-HHmmss-fff))
[void][IO.Directory]::CreateDirectory($backup)
$copies=@(
 @{Source=(Join-Path $repo 'build\NucleusDesktopBridge-v5.dll');Target=(Join-Path $root 'setup\NucleusDesktopBridge-v5.dll')},
 @{Source=(Join-Path $repo 'build\NucleusWindows.exe');Target=(Join-Path $root 'setup\NucleusWindows.exe')},
 @{Source=(Join-Path $repo 'build\VRisingSettings.dll');Target=(Join-Path $root 'setup\VRisingSettings.dll')}
)
$record=@()
foreach($target in @($handler)+@($copies | ForEach-Object {$_.Target})){
 $exists=Test-Path -LiteralPath $target;$name=Split-Path $target -Leaf
 if($exists){Copy-Item -LiteralPath $target -Destination (Join-Path $backup $name)}
 $record+=@{target=$target;existed=$exists;backup=$name}
}
$record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backup 'restore-map.json') -Encoding UTF8
try {
 & $git -C $root apply --ignore-space-change --ignore-whitespace $patch
 if($LASTEXITCODE -ne 0){throw 'Patch application failed.'}
 foreach($copy in $copies){Copy-Item -LiteralPath $copy.Source -Destination $copy.Target -Force}
} catch {
 $problem=$_.Exception.Message
 foreach($entry in $record){
  if($entry.existed){Copy-Item -LiteralPath (Join-Path $backup $entry.backup) -Destination $entry.target -Force}
  elseif(Test-Path -LiteralPath $entry.target){Remove-Item -LiteralPath $entry.target -Force}
 }
 throw "Installation interrupted; previous files restored. $problem"
}
Write-Output "V Rising handler/helper installed. Backup: $backup"
Write-Output 'Before creating a private world, run Link-VRisingWorlds.ps1 -Config your-config -Apply. See docs/v-rising.html.'
