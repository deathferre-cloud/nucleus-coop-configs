param([string]$ReportPath)
$ErrorActionPreference='Stop'
$TestReportPath=$ReportPath
$source=(Resolve-Path (Join-Path $PSScriptRoot '../tools/Repair-Rewasd.ps1')).Path
$tokens=$null;$parseErrors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors|Out-String)}
. $source -LibraryOnly
Add-Type -AssemblyName System.Windows.Forms
$script:checks=New-Object System.Collections.Generic.List[string]
function Assert-True($Value,[string]$Name){if(-not $Value){throw $Name};$script:checks.Add($Name);Write-Output "PASS $Name"}
function Assert-Throws([scriptblock]$Action,[string]$Name){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert-True $failed $Name}
$ready=[pscustomobject]@{Pads=@('pad1','pad2');Slots=@([pscustomobject]@{Slot=0;Connected=$true},[pscustomobject]@{Slot=1;Connected=$true})}
$one=[pscustomobject]@{Pads=@('pad1');Slots=@([pscustomobject]@{Slot=0;Connected=$true},[pscustomobject]@{Slot=1;Connected=$false})}
Assert-True (Test-ControllerReady $ready) 'two PnP and required XInput slots accepted'
Assert-True (-not (Test-ControllerReady $one)) 'one controller never reports success'
$wrong=[pscustomobject]@{Pads=@('a','b');Slots=@([pscustomobject]@{Slot=0;Connected=$true},[pscustomobject]@{Slot=2;Connected=$true})}
Assert-True (-not (Test-ControllerReady $wrong)) 'wrong XInput slots rejected'
$receiver=[pscustomobject]@{Class='USB';InstanceId='USB\VID_28DE&PID_1142\TEST-RECEIVER'}
Assert-True ((Select-SteamReceiver @($receiver))-eq$receiver.InstanceId) 'one exact receiver selected'
Assert-Throws {Select-SteamReceiver @()} 'missing receiver blocked'
Assert-Throws {Select-SteamReceiver @($receiver,$receiver)} 'multiple receivers blocked'
Assert-Throws {Select-SteamReceiver @([pscustomobject]@{Class='USB';InstanceId='USB\ROOT_HUB30\TEST'})} 'USB hub excluded'
Assert-True (Test-LicenseError 'Ошибка проверки лицензии.') 'Russian license error recognized'
Assert-True (-not (Test-LicenseError 'device not found')) 'device error not mislabeled license'

# All device mutations below are replaced with test doubles.
$script:fakeGames=@('VRising');$script:resetCalls=0
function Get-BlockingGames {return $script:fakeGames}
function Get-PnpDevice {return @($receiver)}
function Invoke-PnpRestart([string]$InstanceId){$script:resetCalls++;return [pscustomobject]@{InstanceId=$InstanceId;ExitCode=0}}
Assert-Throws {Invoke-ReceiverReset} 'active game blocks reset'
Assert-True ($script:resetCalls-eq0) 'no reset occurred with active game'
$script:fakeGames=@();$reset=Invoke-ReceiverReset
Assert-True ($script:resetCalls-eq1 -and $reset.InstanceId-eq$receiver.InstanceId) 'offline reset targets only matched receiver'
$script:guardReads=0
function Get-BlockingGames {$script:guardReads++;if($script:guardReads-ge2){return @('VRisingServer')}return @()}
Assert-Throws {Invoke-ReceiverReset} 'game appearing during device selection blocks reset'
Assert-True ($script:resetCalls-eq1) 'race guard prevented mutation'

$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('NucleusRewasdTests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$dummy=Join-Path $testRoot 'dummy.txt';Set-Content -LiteralPath $dummy -Value 'fixture'
$config=[pscustomobject]@{ControllerIds=@('1111111111111111','2222222222222222');CliPath=$dummy;ProfilePath=$dummy;SteamPath=$dummy}
Assert-RepairConfig $config
Assert-True $true 'valid distinct IDs and file paths accepted'
$config.ControllerIds=@('1111111111111111','1111111111111111');Assert-Throws {Assert-RepairConfig $config} 'duplicate controller IDs rejected before apply'
$config.ControllerIds=@('1111111111111111','REPLACE_DEVICE_2');Assert-Throws {Assert-RepairConfig $config} 'invalid second ID rejected before apply'
$config.ControllerIds=@('1111111111111111','2222222222222222');$config.SteamPath=Join-Path $testRoot 'missing.exe';Assert-Throws {Assert-RepairConfig $config} 'missing Steam path rejected before apply'

$script:waitEvents=@();$script:slowWorker=$false;$script:throwNotice=$false
function Show-RepairMessage([string]$Text,[switch]$CanCancel){$script:waitEvents+='notice';if($script:throwNotice){throw 'UI unavailable'};return [System.Windows.Forms.DialogResult]::OK}
$fakeWorker=New-Object psobject
$fakeWorker|Add-Member ScriptMethod WaitForExit {
 if($args.Count){$script:waitEvents+='timed-wait';return (-not $script:slowWorker)}
 $script:waitEvents+='completion-wait'
}
Wait-ReceiverWorker $fakeWorker
Assert-True (($script:waitEvents-join ',')-eq'timed-wait') 'completed worker does not trigger extra wait'
$script:waitEvents=@();$script:slowWorker=$true
Wait-ReceiverWorker $fakeWorker
Assert-True (($script:waitEvents-join ',')-eq'timed-wait,notice,completion-wait') 'timeout waits for actual completion'
$script:waitEvents=@();$script:throwNotice=$true
Assert-Throws {Wait-ReceiverWorker $fakeWorker} 'notice failure propagates after completion wait'
Assert-True ($script:waitEvents[-1]-eq'completion-wait') 'notice failure cannot leave worker running after mutex release'

# Execute the real coordinator with simulated snapshots, Steam, UAC worker and UI.
# Only the final process-exit statement is intercepted, so this test process survives.
$text=Get-Content -Raw -LiteralPath $source
$body=$text.Substring($text.IndexOf('$mutex =')).Replace('$PSScriptRoot','$fixture')
$body=$body.Replace('Local\NucleusCoopRepairRewasd',('Local\NucleusRepairTest-'+$PID))
$body=$body.Replace('if (-not $run.Success) { exit 1 }','if (-not $run.Success) { $script:capturedExit = 1 }')
$main=[scriptblock]::Create($body)
function Get-BlockingGames {return $script:fakeGames}
function Get-ControllerSnapshot {
 if($script:snapshots.Count-eq0){throw 'Unexpected extra snapshot'}
 $result=$script:snapshots[0];$script:snapshots.RemoveAt(0);return $result
}
function Apply-SavedProfiles($Config){$script:events.Add('apply');if($script:failApply){throw 'Ошибка проверки лицензии.'};return @([pscustomobject]@{ExitCode=0})}
function Show-RepairMessage([string]$Text,[switch]$CanCancel){
 $script:shown.Add($Text)
 if($CanCancel -and $script:cancelAfterReset){return [System.Windows.Forms.DialogResult]::Cancel}
 return [System.Windows.Forms.DialogResult]::OK
}
function Get-Process {
 param([string[]]$Name,[int]$Id,$ErrorAction)
 if($Id){return [pscustomobject]@{Path='test-powershell.exe'}}
 if($Name-contains'steam' -and $global:MockSteamRunning){return [pscustomobject]@{ProcessName='steam'}}
}
function Start-Sleep {param($Seconds,$Milliseconds)}
function Start-Process {
 param($FilePath,$ArgumentList,$Verb,$WindowStyle,[switch]$PassThru)
 if($Verb-eq'RunAs') {
  $script:events.Add('receiver-worker')
  $report=$ArgumentList[-1].Trim('"')
  @{Success=(-not $script:failWorker);Error='mock receiver failure'}|ConvertTo-Json|Set-Content -LiteralPath $report -Encoding UTF8
  $worker=New-Object psobject
  $worker|Add-Member ScriptMethod WaitForExit {
   if($args.Count){$script:events.Add('worker-timed-wait');return (-not $script:slowWorker)}
   $script:events.Add('worker-complete-wait')
  }
  return $worker
 }
 $script:events.Add('steam-start');$global:MockSteamRunning=$true
}
function Invoke-Fixture([string]$Name,$Snapshots,[bool]$Steam=$false,[switch]$Live,[switch]$License,[switch]$WorkerFailure,[switch]$Cancel,[switch]$Slow) {
 $fixture=Join-Path $testRoot $Name;New-Item -ItemType Directory -Path $fixture|Out-Null
 $ConfigPath=Join-Path $fixture 'config.json'
 $steamStub=Join-Path $fixture 'steam-stub.ps1'
 Set-Content -LiteralPath $steamStub -Value '$global:MockSteamRunning=$false; $global:MockSteamShutdownCount++' -Encoding UTF8
 $configJson=@{ControllerIds=@('1111111111111111','2222222222222222');CliPath=$dummy;ProfilePath=$dummy;SteamPath=$steamStub}|ConvertTo-Json
 [IO.File]::WriteAllText($ConfigPath,$configJson,[Text.UTF8Encoding]::new($false))
 $script:snapshots=New-Object System.Collections.ArrayList
 foreach($snapshot in $Snapshots){[void]$script:snapshots.Add($snapshot)}
 $script:events=New-Object System.Collections.Generic.List[string];$script:shown=New-Object System.Collections.Generic.List[string]
 $script:fakeGames=@();if($Live){$script:fakeGames=@('VRising')}
 $script:failApply=[bool]$License;$script:failWorker=[bool]$WorkerFailure;$script:cancelAfterReset=[bool]$Cancel;$script:slowWorker=[bool]$Slow
 $global:MockSteamRunning=$Steam;$global:MockSteamShutdownCount=0;$script:capturedExit=0;$CheckOnly=$false
 & $main
 $log=Get-ChildItem -LiteralPath (Join-Path $fixture 'Repair-Rewasd-logs') -Filter '*.json' | Where-Object {$_.Name-notlike'*-receiver.json'} | Select-Object -First 1
 return (Get-Content -LiteralPath $log.FullName -Raw|ConvertFrom-Json)
}
$result=Invoke-Fixture 'ready' @($ready)
Assert-True ($result.Success -and $result.Action-eq'already_ready_no_changes') 'ready coordinator is no-op'
Assert-True ($script:events.Count-eq0) 'ready coordinator performs no apply or device/Steam action'
$result=Invoke-Fixture 'unicode-конфиг' @($ready)
Assert-True ($result.Success -and $result.Action-eq'already_ready_no_changes') 'UTF8 config without BOM preserves Cyrillic paths in both shells'
$result=Invoke-Fixture 'live' @($one) -Live
Assert-True (-not $result.Success -and $result.Action-eq'live_session_preserved') 'live game is preserved'
Assert-True ($script:events.Count-eq0) 'live branch does not apply or reset'
$result=Invoke-Fixture 'apply-only' @($one,$ready)
Assert-True ($result.Success -and ($script:events-join ',')-eq'apply') 'apply-only success avoids receiver reset'
$result=Invoke-Fixture 'license' @($one) -Steam $true -License
Assert-True (-not $result.Success -and $script:capturedExit-eq1) 'license failure is a failing outcome'
Assert-True ($global:MockSteamShutdownCount-eq0 -and $global:MockSteamRunning) 'license failure leaves existing Steam alone'
$result=Invoke-Fixture 'offline' @($one,$one,$ready,$ready) -Steam $true
Assert-True $result.Success 'full simulated offline recovery succeeds'
Assert-True ($global:MockSteamShutdownCount-eq1 -and $global:MockSteamRunning) 'Steam closed and restored once'
Assert-True (($script:events-join ',')-eq'apply,receiver-worker,worker-timed-wait,apply,steam-start') 'offline ordering preserved'
$result=Invoke-Fixture 'worker-fails' @($one,$one) -Steam $true -WorkerFailure
Assert-True (-not $result.Success -and $script:capturedExit-eq1) 'worker failure cannot report success'
Assert-True $global:MockSteamRunning 'Steam restored after worker failure'
$result=Invoke-Fixture 'cancelled' @($one,$one) -Steam $true -Cancel
Assert-True (-not $result.Success -and $result.ReceiverReset -and $script:capturedExit-eq1) 'cancel after reset accurately reports partial action'
Assert-True $global:MockSteamRunning 'Steam restored on cancel'
$result=Invoke-Fixture 'post-steam-loss' @($one,$one,$ready,$one) -Steam $true
Assert-True (-not $result.Success -and $script:capturedExit-eq1) 'loss after returning Steam rejects success'
$result=Invoke-Fixture 'slow-worker' @($one,$one,$ready,$ready) -Steam $true -Slow
Assert-True $result.Success 'slow worker completes before continuing'
Assert-True ($script:events.IndexOf('worker-complete-wait')-lt$script:events.IndexOf('steam-start')) 'Steam restore follows actual worker completion'
Assert-True (-not ($text -match '(?m)^\s*(Restart-Service|Stop-Process)\b')) 'no service restart or forced process termination in helper'
$childFixture=Join-Path $testRoot 'exit-code';New-Item -ItemType Directory -Path $childFixture|Out-Null
$childScript=Join-Path $childFixture 'check-exit.ps1'
$childText=@'
param([string]$Source,[string]$Fixture)
. $Source -LibraryOnly
function Get-ControllerSnapshot {throw 'Synthetic read failure for exit-code test'}
function Show-RepairMessage {param([string]$Text,[switch]$CanCancel);return 0}
$CheckOnly=$false
$text=Get-Content -LiteralPath $Source -Raw
$body=$text.Substring($text.IndexOf('$mutex =')).Replace('$PSScriptRoot','$Fixture').Replace('Local\NucleusCoopRepairRewasd',('Local\NucleusRepairExitTest-'+$PID))
& ([scriptblock]::Create($body))
'@
[IO.File]::WriteAllText($childScript,$childText,[Text.UTF8Encoding]::new($true))
$hostExe=(Microsoft.PowerShell.Management\Get-Process -Id $PID).Path
$child=Microsoft.PowerShell.Management\Start-Process -FilePath $hostExe -WindowStyle Hidden -Wait -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"'-f$childScript),'-Source',('"{0}"'-f$source),'-Fixture',('"{0}"'-f$childFixture))
Assert-True ($child.ExitCode-eq1) 'real child process returns exit code 1 on coordinator failure'
$report=[pscustomobject]@{Passed=$script:checks.Count;Checks=$script:checks;PowerShell=$PSVersionTable.PSVersion.ToString();NativeDeviceMutations=$false;FixtureRoot=$testRoot}
if($TestReportPath){$report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $TestReportPath -Encoding UTF8}
"All $($script:checks.Count) checks passed. No native device reset or real Steam shutdown executed."
