param([Parameter(Mandatory=$true)][string]$Config,[switch]$Apply,[switch]$Undo)
$ErrorActionPreference='Stop'
if($Apply -and $Undo){throw 'Choose either Apply or Undo.'}
. (Join-Path $PSScriptRoot 'VRising-Configuration.ps1')
$settings=Get-VRisingConfiguration -Config $Config
$plan=@(Get-VRisingSavePlan -Settings $settings)
if(-not $Apply -and -not $Undo){$plan | Select-Object Player,LinkPath,Target,Exists;return}
if(Get-Process -Name NucleusCoop,VRising,VRisingServer -ErrorAction SilentlyContinue){throw 'Save and close V Rising clients/server and Nucleus before changing links.'}
$mapFile=Join-Path $settings.Root 'setup\VRising-save-links.local.json'
$previous=@()
if(Test-Path -LiteralPath $mapFile){$previous=Get-Content -LiteralPath $mapFile -Raw -Encoding UTF8 | ConvertFrom-Json}
foreach($entry in $plan){
 $old=@($previous | Where-Object {$_.LinkPath -eq $entry.LinkPath -and $_.Target -eq $entry.Target})
 if($old.Count -eq 1 -and $entry.Exists){$entry.CreatedByTool=($old[0].CreatedByTool -is [bool] -and $old[0].CreatedByTool)}
}
if($Undo){
 foreach($entry in $plan){
  if($entry.Exists -and $entry.CreatedByTool){
   # Plan verifies the exact account path and junction target. Nonrecursive deletion removes only the link.
   [IO.Directory]::Delete($entry.LinkPath,$false)
   $entry.Exists=$false;$entry.CreatedByTool=$false
  }
 }
 $plan | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $mapFile -Encoding UTF8
 Write-Output 'Removed only links recorded as created by this tool. Target save data was retained.'
 return
}
$created=@()
[void][IO.Directory]::CreateDirectory((Split-Path $mapFile -Parent))
if(Test-Path -LiteralPath $mapFile){Copy-Item -LiteralPath $mapFile -Destination ($mapFile+'.'+(Get-Date -Format yyyyMMdd-HHmmss-fff)+'.bak')}
try {
 foreach($entry in $plan){
  if(-not $entry.Exists){
   [void][IO.Directory]::CreateDirectory($entry.Target)
   [void][IO.Directory]::CreateDirectory((Split-Path $entry.LinkPath -Parent))
   New-Item -ItemType Junction -Path $entry.LinkPath -Target $entry.Target | Out-Null
   $created+=$entry;$entry.Exists=$true;$entry.CreatedByTool=$true
  }
 }
 $plan | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $mapFile -Encoding UTF8
} catch {
 foreach($entry in $created){
  $actual=Get-Item -LiteralPath $entry.LinkPath -Force -ErrorAction SilentlyContinue
  if($actual -and $actual.LinkType -eq 'Junction' -and [IO.Path]::GetFullPath([string]@($actual.Target)[0]).TrimEnd('\') -eq $entry.Target.TrimEnd('\')){[IO.Directory]::Delete($entry.LinkPath,$false)}
 }
 throw
}
Write-Output "Selective links ready. Private rollback map: $mapFile"
