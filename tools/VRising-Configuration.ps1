# Shared validation for the portable V Rising installer and selective save links.
function Get-VRisingConfiguration {
 param([Parameter(Mandatory=$true)][string]$Config)
 $c=Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
 $root=[IO.Path]::GetFullPath([string]$c.nucleusRoot).TrimEnd('\')
 $profile=Get-Content -LiteralPath $c.vRisingProfileFile -Raw -Encoding UTF8 | ConvertFrom-Json
 $players=@($profile.Data | Sort-Object PlayerID)
 if($players.Count -ne 2 -or $players[0].PlayerID -ne 0 -or $players[1].PlayerID -ne 1){throw 'Save a two-player V Rising profile in Nucleus first.'}
 if($profile.Options.select -ne 'Default/No!'){throw 'The verified game profile must use Default/No!.'}
 if(-not $profile.AudioSettings.CustomSettings){throw 'Enable separate audio outputs in the saved profile.'}
 $outputs=@([string]$profile.AudioInstances.AudioInstance1,[string]$profile.AudioInstances.AudioInstance2)
 if($outputs[0] -eq $outputs[1] -or @($outputs | Where-Object {-not $_.StartsWith('{0.0.')}).Count){throw 'Assign two different active audio outputs in Nucleus.'}
 $ids=@();$pads=@()
 foreach($player in $players){
  $id=[string]$player.SteamID
  if($id -notmatch '^\d{17}$' -or [Int64]$id -le [Int64]76561197960265728){throw 'Use valid generated Steam IDs from your own Nucleus profile.'}
  foreach($bounds in @($player.EditBounds,$player.Owner.UiBounds,$player.MonitorBounds)){
   if(-not $bounds -or $bounds.Width -le 0 -or $bounds.Height -le 0){throw 'Profile geometry is invalid. Create and save the layout in Nucleus; do not import the reference JSON.'}
  }
  if(-not $player.IsXInput -or -not $player.GamepadGuid){throw 'Assign two independent XInput controllers.'}
  $ids+=$id;$pads += [string]$player.GamepadGuid
 }
 if($ids[0] -eq $ids[1] -or $pads[0] -eq $pads[1]){throw 'Players need different generated IDs and controller assignments.'}
 $login=Join-Path $c.steamRoot 'config\loginusers.vdf'
 if(-not(Test-Path -LiteralPath $login -PathType Leaf)){throw 'Steam account inventory is unavailable; check steamRoot.'}
 $realIds=@([regex]::Matches([IO.File]::ReadAllText($login),'(?m)^\s*"(\d{17})"\s*$') | ForEach-Object {$_.Groups[1].Value})
 if(-not $realIds.Count){throw 'Could not read Steam account IDs; no save directories may be redirected.'}
 foreach($id in $ids){if($realIds -contains $id){throw 'A Nucleus player ID collides with a real Steam account. Correct the profile first.'}}
 $original=Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\LocalLow\Stunlock Studios\VRising'
 # Explicit override is for isolated fixture tests or an independently verified server path.
 if($c.vRisingOriginalDataRoot){$original=[IO.Path]::GetFullPath([string]$c.vRisingOriginalDataRoot)}
 [pscustomobject]@{Config=$c;Root=$root;Profile=$profile;Players=$players;Ids=$ids;OriginalRoot=$original}
}
function Get-VRisingSavePlan {
 param([Parameter(Mandatory=$true)]$Settings)
 $cloud=Join-Path $Settings.OriginalRoot 'CloudSaves'
 for($i=0;$i -lt 2;$i++){
  $link=[IO.Path]::GetFullPath((Join-Path $cloud $Settings.Ids[$i]))
  $target=[IO.Path]::GetFullPath((Join-Path $Settings.Root ('saves\V Rising\Player'+($i+1)+'\CloudSaves\'+$Settings.Ids[$i])))
  if($target.StartsWith($link+'\',[StringComparison]::OrdinalIgnoreCase) -or $target -eq $link){throw 'Save link target overlaps its own source.'}
  $existing=Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
  if($existing){
   $targets=@($existing.Target)
   if($existing.LinkType -ne 'Junction' -or $targets.Count -ne 1 -or [IO.Path]::GetFullPath([string]$targets[0]).TrimEnd('\') -ne $target.TrimEnd('\')){throw "Refusing to replace an existing directory or different link: $link. Preserve the complete tree, including empty/hidden folders, and review migration separately."}
  }
  [pscustomobject]@{Player=$i+1;SteamId=$Settings.Ids[$i];LinkPath=$link;Target=$target;Exists=[bool]$existing;CreatedByTool=$false}
 }
}
