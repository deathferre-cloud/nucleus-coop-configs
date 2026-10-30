param([Parameter(Mandatory=$true)][string]$Config)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$c=Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
if(Get-Process -Name NucleusCoop,dontstarve_steam_x64 -ErrorAction SilentlyContinue){throw 'Save and close both games and Nucleus before installing.'}
$root=[IO.Path]::GetFullPath($c.nucleusRoot)
$handler=Join-Path $root "handlers\Don't Starve Together.js"
foreach($path in @($handler,$c.dstProfileFile,(Join-Path $c.workshopRoot '1240565842\modinfo.lua'),(Join-Path $c.workshopRoot '1834274509\modinfo.lua'))){if(-not(Test-Path -LiteralPath $path)){throw "Required file missing: $path"}}
$profile=Get-Content -LiteralPath $c.dstProfileFile -Raw -Encoding UTF8 | ConvertFrom-Json
$players=@($profile.Data | Sort-Object PlayerID)
if($players.Count -ne 2){throw 'Save a two-player profile in Nucleus first.'}
if(-not $profile.AudioSettings.CustomSettings){throw 'Enable custom audio outputs in the saved game profile.'}
$first=[string]$profile.AudioInstances.AudioInstance1;$second=[string]$profile.AudioInstances.AudioInstance2
if(-not $first.StartsWith('{0.0.') -or -not $second.StartsWith('{0.0.') -or $first -eq $second){throw 'Select two different render endpoints in the Nucleus game profile.'}
$accounts=@($players | ForEach-Object {
 $steam=[Int64]$_.SteamID;$account=$steam-[Int64]76561197960265728
 if($account -lt 1 -or $account -gt [UInt32]::MaxValue){throw 'Invalid local Steam ID in the Nucleus profile.'}
 $account.ToString()
})
$git=(Get-Command git -ErrorAction Stop).Source
$patch=Join-Path $repo 'games\dst\handler.patch'
# Validate the exact upstream handler before any installed file is changed.
& $git -C $root apply --check --ignore-space-change --ignore-whitespace $patch
if($LASTEXITCODE -ne 0){throw 'Patch does not match. Use the official DST handler v15, or review the differences manually; no files changed.'}
& (Join-Path $PSScriptRoot 'Build-Tools.ps1') -NucleusRoot $root
$stamp=Get-Date -Format yyyyMMdd-HHmmss
$backup=Join-Path $root "setup\backups\$stamp"
New-Item -ItemType Directory -Path $backup -Force | Out-Null
$targets=@($handler,(Join-Path $root 'setup\NucleusDesktopBridge-v5.dll'),(Join-Path $root 'setup\NucleusWindows.exe'),(Join-Path $root 'setup\CoopSetup.local.json'),(Join-Path $root 'AudioCheck.exe'))
$record=@()
foreach($target in $targets){$exists=Test-Path -LiteralPath $target;$name=Split-Path $target -Leaf;if($exists){Copy-Item -LiteralPath $target -Destination (Join-Path $backup $name)};$record+=@{target=$target;existed=$exists;backup=$name}}
$record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backup 'restore-map.json') -Encoding UTF8
try {
 & $git -C $root apply --ignore-space-change --ignore-whitespace $patch
 if($LASTEXITCODE -ne 0){throw 'Patch application failed.'}
 Copy-Item -LiteralPath (Join-Path $repo 'build\NucleusDesktopBridge-v5.dll') -Destination (Join-Path $root 'setup\NucleusDesktopBridge-v5.dll') -Force
 Copy-Item -LiteralPath (Join-Path $repo 'build\NucleusWindows.exe') -Destination (Join-Path $root 'setup\NucleusWindows.exe') -Force
 Copy-Item -LiteralPath (Join-Path $repo 'build\AudioCheck.exe') -Destination (Join-Path $root 'AudioCheck.exe') -Force
 @{workshopRoot=$c.workshopRoot;dstAccountIds=$accounts} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'setup\CoopSetup.local.json') -Encoding UTF8
} catch {
 $installError=$_.Exception.Message
 foreach($entry in $record){
  if($entry.existed){Copy-Item -LiteralPath (Join-Path $backup $entry.backup) -Destination $entry.target -Force}
  elseif(Test-Path -LiteralPath $entry.target){Remove-Item -LiteralPath $entry.target -Force}
 }
 throw "Install interrupted. Previous files restored. Backup: $backup. $installError"
}
Write-Output "Installed v1.0.0 / bridge v5. Backup: $backup"
Write-Output 'Enable both local Russian client mods in each game, apply and restart. See docs/dst.html.'
