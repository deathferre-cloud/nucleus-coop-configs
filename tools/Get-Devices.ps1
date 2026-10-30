param([Parameter(Mandatory=$true)][string]$NucleusRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $NucleusRoot 'NAudio.dll')
$enumerator=New-Object NAudio.CoreAudioApi.MMDeviceEnumerator
try {
 $audio=@($enumerator.EnumerateAudioEndPoints([NAudio.CoreAudioApi.DataFlow]::Render,[NAudio.CoreAudioApi.DeviceState]::Active) | ForEach-Object {[pscustomobject]@{name=$_.FriendlyName;endpoint=$_.ID}})
 $screens=@([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {[pscustomobject]@{name=$_.DeviceName;primary=$_.Primary;x=$_.Bounds.X;y=$_.Bounds.Y;width=$_.Bounds.Width;height=$_.Bounds.Height}})
 [pscustomobject]@{screens=$screens;activeAudioOutputs=$audio;controllerIdHelp='In reWASD, right-click each controller and choose Copy device ID.'} | ConvertTo-Json -Depth 5
} finally {$enumerator.Dispose()}
