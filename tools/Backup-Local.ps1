param([Parameter(Mandatory=$true)][string]$NucleusRoot,[Parameter(Mandatory=$true)][string]$Destination,[string]$RewasdProfile)
$ErrorActionPreference='Stop'
if(Get-Process -Name NucleusCoop,VRising,VRisingServer,dontstarve_steam_x64,dontstarve_dedicated_server_nullrenderer_x64 -ErrorAction SilentlyContinue){throw 'Close the games and Nucleus before taking a consistent configuration backup.'}
$folder=Join-Path $Destination ('nucleus-config-'+(Get-Date -Format yyyyMMdd-HHmmss))
New-Item -ItemType Directory -Path $folder -Force | Out-Null
# Deliberate allowlist: no game content, saves, account caches or activation data.
foreach($name in @('Settings.ini','UserProfile.json','game profiles','handlers','setup','content\userprofile.json','Start-DST-Coop.cmd','Start-VRising-Coop.cmd')){
 $source=Join-Path $NucleusRoot $name
 if(Test-Path -LiteralPath $source){
  $target=Join-Path $folder $name
  New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
  Copy-Item -LiteralPath $source -Destination $target -Recurse
 }
}
if($RewasdProfile){Copy-Item -LiteralPath $RewasdProfile -Destination (Join-Path $folder 'controller.rewasd')}
'PRIVATE LOCAL BACKUP. Contains machine paths and device/account identifiers. Do not publish this folder. Saves are separate; back up saves after exiting the world.' | Set-Content -LiteralPath (Join-Path $folder 'PRIVATE.txt')
Write-Output $folder
