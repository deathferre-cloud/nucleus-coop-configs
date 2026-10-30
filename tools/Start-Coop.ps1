param([Parameter(Mandatory=$true)][string]$Config,[switch]$ControllersOnly)
$ErrorActionPreference='Stop'
$c=Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not(Test-Path -LiteralPath (Join-Path $c.nucleusRoot 'NucleusCoop.exe'))){throw 'Check nucleusRoot in your local config.'}
if(Get-Process -Name NucleusCoop,VRising,VRisingServer,dontstarve_steam_x64 -ErrorAction SilentlyContinue){throw 'Nucleus or a game session is already open. Save and close it before reapplying controller mappings.'}
if(@($c.controllerIds).Count -gt 0){
 if(-not(Test-Path -LiteralPath $c.rewasdCli) -or -not(Test-Path -LiteralPath $c.rewasdProfile)){throw 'Check reWASD paths.'}
 if(@($c.controllerIds).Count -ne 2 -or $c.controllerIds[0] -eq $c.controllerIds[1]){throw 'Enter two different physical controller IDs, or [] for native XInput controllers.'}
 foreach($deviceId in $c.controllerIds){
  if($deviceId -notmatch '^\d+$'){throw 'Replace example controller IDs with your own reWASD IDs.'}
  & $c.rewasdCli apply --id $deviceId --path $c.rewasdProfile --slot slot1
  if($LASTEXITCODE -ne 0){throw "reWASD failed for controller $deviceId. Check power and connection."}
 }
 Start-Sleep -Seconds 2
 $pads=@(Get-PnpDevice -PresentOnly | Where-Object {$_.InstanceId -like 'USB\VID_045E&PID_028E\*' -and $_.Status -eq 'OK'})
 if($pads.Count -lt 2){throw 'Two Xbox 360 virtual controllers are not present yet. Check both devices in reWASD.'}
}
if(-not $ControllersOnly){Start-Process -FilePath (Join-Path $c.nucleusRoot 'NucleusCoop.exe') -WorkingDirectory $c.nucleusRoot}
