param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Repair-Rewasd.private.json'),
    [switch]$CheckOnly,
    [switch]$LiveRepair,
    [switch]$InputCheckOnly,
    [switch]$ReceiverWorker,
    [string]$ReportPath,
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'

function Get-BlockingGames {
    $names = @('VRising','VRisingServer','dontstarve_steam','dontstarve_steam_x64',
        'dontstarve_dedicated_server_nullrenderer','dontstarve_dedicated_server_nullrenderer_x64')
    $found = @(Get-Process -Name $names -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName })
    $found += @(Get-ChildItem 'HKCU:\Software\Valve\Steam\Apps' -ErrorAction SilentlyContinue | ForEach-Object {
        $app = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($app.Running -eq 1) { 'Steam app ' + $_.PSChildName }
    })
    return @($found | Sort-Object -Unique)
}

function Test-ControllerReady($Snapshot) {
    return (@($Snapshot.Pads).Count -ge 2 -and
        @($Snapshot.Slots | Where-Object { $_.Connected -and $_.Slot -eq 0 }).Count -eq 1 -and
        @($Snapshot.Slots | Where-Object { $_.Connected -and $_.Slot -eq 1 }).Count -eq 1)
}

function Get-ControllerSnapshot {
    if (-not ('NucleusRewasdRepair.XInput' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace NucleusRewasdRepair {
    public static class XInput {
        [DllImport("xinput1_4.dll", EntryPoint="XInputGetState")]
        public static extern uint GetState(uint index, IntPtr state);
    }
}
'@
    }
    $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(16)
    try {
        $slots = @(0..3 | ForEach-Object {
            $result = [NucleusRewasdRepair.XInput]::GetState([uint32]$_, $buffer)
            [pscustomobject]@{ Slot = $_; Connected = ($result -eq 0); Result = $result }
        })
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
    $pads = @(Get-PnpDevice -PresentOnly | Where-Object {
        $_.InstanceId -like 'USB\VID_045E&PID_028E\*' -and $_.Status -eq 'OK'
    } | Select-Object Status, InstanceId)
    return [pscustomobject]@{ Time = (Get-Date -Format o); Slots = $slots; Pads = $pads }
}

function Select-SteamReceiver($Devices) {
    $receivers = @($Devices | Where-Object {
        $_.Class -eq 'USB' -and $_.InstanceId -match '^USB\\VID_28DE&PID_1142\\[^\\]+$'
    })
    if ($receivers.Count -ne 1) {
        throw "Ожидался один USB-приёмник Steam Controller; найдено: $($receivers.Count). Подключите приёмник."
    }
    return $receivers[0].InstanceId
}

function Invoke-PnpRestart([string]$InstanceId) {
    $output = @(& "$env:SystemRoot\System32\pnputil.exe" /restart-device $InstanceId 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ('Не удалось перезапустить приёмник: ' + ($output -join ' ')) }
    return [pscustomobject]@{ InstanceId = $InstanceId; ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { "$_" }) }
}

function Invoke-ReceiverReset($Config, [switch]$DuringGame) {
    if ($DuringGame) {
        if (-not (Get-RewasdKeepVirtual $Config)) { throw 'Удержание виртуального геймпада не включено; live reset остановлен.' }
    } elseif (@(Get-BlockingGames).Count -gt 0) { throw 'game_session_active: используйте режим восстановления внутри игры.' }
    $id = Select-SteamReceiver @(Get-PnpDevice -PresentOnly)
    if ($DuringGame) {
        if (-not (Get-RewasdKeepVirtual $Config)) { throw 'Настройка удержания изменилась; live reset остановлен.' }
    } elseif (@(Get-BlockingGames).Count -gt 0) { throw 'game_session_active: игра появилась во время проверки.' }
    return Invoke-PnpRestart $id
}

function Test-LicenseError([string]$Text) {
    return $Text -match '(?i)лиценз|licen[cs]e|активац'
}

function Show-RepairMessage([string]$Text, [switch]$CanCancel) {
    Add-Type -AssemblyName System.Windows.Forms
    $buttons = [System.Windows.Forms.MessageBoxButtons]::OK
    if ($CanCancel) { $buttons = [System.Windows.Forms.MessageBoxButtons]::OKCancel }
    return [System.Windows.Forms.MessageBox]::Show($Text, 'Починка Ревасд', $buttons,
        [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Assert-RepairConfig($Config) {
    $ids = @($Config.ControllerIds | ForEach-Object { [string]$_ })
    if ($ids.Count -ne 2 -or @($ids | Select-Object -Unique).Count -ne 2) {
        throw 'Укажите два разных исходных ID Steam Controller.'
    }
    foreach ($id in $ids) {
        if ($id -notmatch '^\d{12,20}$') { throw 'Некорректный ID контроллера; профили не применялись.' }
    }
    foreach ($key in @('CliPath','ProfilePath','SteamPath')) {
        if (-not $Config.$key -or -not (Test-Path -LiteralPath $Config.$key -PathType Leaf)) {
            throw ('Не найден файл из настройки ' + $key + '. Исправьте Repair-Rewasd.private.json.')
        }
    }
}

function Wait-ReceiverWorker($Worker) {
    if (-not $Worker.WaitForExit(45000)) {
        # Retain the coordinator mutex and keep Steam closed until the worker really exits.
        try {
            [void](Show-RepairMessage 'Переподключение Windows занимает больше времени. Дождитесь его завершения. Повторная починка заблокирована, Steam будет возвращён после завершения операции.')
        } finally { $Worker.WaitForExit() }
    }
}

function Apply-SavedProfiles($Config) {
    Assert-RepairConfig $Config
    if (-not (Test-Path -LiteralPath $Config.CliPath) -or -not (Test-Path -LiteralPath $Config.ProfilePath)) {
        throw 'Не найден reWASD или сохранённый профиль. Конфигурация не заменялась.'
    }
    $results = @()
    foreach ($id in $Config.ControllerIds) {
        if (@(Get-BlockingGames).Count -gt 0) { throw 'Игра запущена; применение профилей остановлено.' }
        if ([string]$id -notmatch '^\d{12,20}$') { throw 'Некорректный сохранённый ID контроллера.' }
        $output = @(& $Config.CliPath apply --id ([string]$id) --path $Config.ProfilePath --slot slot1 2>&1)
        $exitCode = $LASTEXITCODE
        $text = $output -join ' '
        $results += [pscustomobject]@{ Id = [string]$id; ExitCode = $exitCode; Output = $text }
        if ($exitCode -ne 0) {
            if (Test-LicenseError $text) {
                throw 'Ошибка проверки лицензии reWASD. Откройте аккаунт reWASD, обновите статус или активируйте уже имеющийся доступ для этого ПК. Затем повторите запуск ярлыка. Эта ошибка сама по себе не доказывает необходимость новой покупки.'
            }
            throw ('Профиль не применён: ' + $text)
        }
    }
    return $results
}

function Get-RewasdKeepVirtual($Config) {
    $path = $Config.SettingsPath
    if (-not $path) { $path = Join-Path $env:ProgramData ('Disc-Soft\reWASD\Settings\settings_' + $env:USERNAME + '.json') }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        # reWASD has an empty-name root property. PSCustomObject JSON conversion rejects it.
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $settings = $raw | ConvertFrom-Json -AsHashtable
        } else {
            Add-Type -AssemblyName System.Web.Extensions
            $parser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $settings = $parser.DeserializeObject($raw)
        }
        return ([string]$settings['Config']['LeaveVirtualControllerForOfflineController'] -eq '1')
    } catch { return $false }
}

function Get-ProtectedSession {
    return @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(VRising|VRisingServer|dontstarve_steam(_x64)?|dontstarve_dedicated_server_nullrenderer(_x64)?|steam|jlserv|NucleusCoop)\.exe$'
    } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Id = $_.ProcessId; Created = $_.CreationDate.ToString('o') }
    })
}

function Assert-SessionPreserved($Before, $After) {
    foreach ($old in $Before) {
        if (@($After | Where-Object { $_.Id -eq $old.Id -and $_.Created -eq $old.Created -and $_.Name -eq $old.Name }).Count -ne 1) {
            throw ('Процесс ' + $old.Name + ' завершился или изменился во время проверки. Сохранение сеанса не подтверждено; автоматического перезапуска не будет.')
        }
    }
}

function Invoke-RemapOn($Config) {
    Assert-RepairConfig $Config
    $results = @()
    foreach ($id in $Config.ControllerIds) {
        # No remap-off, clear-slot or profile apply in the live path.
        $output = @(& $Config.CliPath remap --id ([string]$id) --state on 2>&1)
        $code = $LASTEXITCODE
        $message = $output -join ' '
        $results += [pscustomobject]@{ Id = [string]$id; ExitCode = $code; Output = $message }
        if ($code -ne 0) {
            if (Test-LicenseError $message) { throw 'Ошибка проверки лицензии reWASD. Обновите существующую активацию в reWASD. Игра и служба не перезапускались.' }
            throw ('Не удалось включить существующее переназначение: ' + $message)
        }
    }
    return $results
}

function Get-ButtonSamples {
    # The snapshot call initializes the XInput interop type before this function is used.
    $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(16)
    try {
        return @(0..1 | ForEach-Object {
            $result = [NucleusRewasdRepair.XInput]::GetState([uint32]$_, $buffer)
            $down = $false
            if ($result -eq 0) { $down = (([Runtime.InteropServices.Marshal]::ReadInt16($buffer, 4) -band 0x1000) -ne 0) }
            [pscustomobject]@{ Slot = $_; Connected = ($result -eq 0); ADown = $down }
        })
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
}

function Update-InputProof($Stages, $Samples) {
    foreach ($sample in $Samples) {
        $slot = [int]$sample.Slot
        if ($slot -lt 0 -or $slot -gt 1) { continue }
        if (-not $sample.Connected) { $Stages[$slot] = 0; continue }
        # Release, press, release. A held button or an idle retained Xbox cannot pass.
        if ($Stages[$slot] -eq 0 -and -not $sample.ADown) { $Stages[$slot] = 1 }
        elseif ($Stages[$slot] -eq 1 -and $sample.ADown) { $Stages[$slot] = 2 }
        elseif ($Stages[$slot] -eq 2 -and -not $sample.ADown) { $Stages[$slot] = 3 }
    }
}

function Show-InputProof {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Починка Ревасд: проверка двух геймпадов'
    $form.ClientSize = New-Object System.Drawing.Size(570, 210)
    $form.StartPosition = 'CenterScreen'; $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(18, 18)
    $label.Size = New-Object System.Drawing.Size(535, 120)
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Отмена'; $cancel.Location = New-Object System.Drawing.Point(435, 160)
    $cancel.Size = New-Object System.Drawing.Size(115, 32)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $cancel; $form.Controls.Add($label); $form.Controls.Add($cancel)
    $stages = @(0, 0); $cancelled = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    try {
        $form.Show()
        while ([DateTime]::UtcNow -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
            if (-not $form.Visible -or $form.DialogResult -eq [System.Windows.Forms.DialogResult]::Cancel) { $cancelled = $true; break }
            Update-InputProof $stages @(Get-ButtonSamples)
            $left = [Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalSeconds)
            $one = 'ждём кнопку A'; if ($stages[0] -eq 3) { $one = 'ответ получен' }
            $two = 'ждём кнопку A'; if ($stages[1] -eq 3) { $two = 'ответ получен' }
            $label.Text = "По очереди нажмите и отпустите A на каждом геймпаде.`r`nУдерживайте кнопку примерно полсекунды.`r`n`r`nXbox 1: $one. Xbox 2: $two.`r`nОсталось: $left сек."
            if ($stages[0] -eq 3 -and $stages[1] -eq 3) { break }
            Start-Sleep -Milliseconds 40
        }
        return [pscustomobject]@{ Passed = ($stages[0] -eq 3 -and $stages[1] -eq 3); Cancelled = $cancelled; Stages = $stages }
    } finally { $form.Close(); $form.Dispose() }
}

function Start-ReceiverWorker($ConfigPath, $WorkerReport, [switch]$DuringGame) {
    $powershell = (Get-Process -Id $PID).Path
    $workerArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),
        '-ReceiverWorker','-ReportPath',('"{0}"' -f $WorkerReport),'-ConfigPath',('"{0}"' -f $ConfigPath))
    if ($DuringGame) { $workerArgs += '-LiveRepair' }
    $worker = Start-Process -FilePath $powershell -Verb RunAs -WindowStyle Hidden -ArgumentList $workerArgs -PassThru
    Wait-ReceiverWorker $worker
    if (-not (Test-Path -LiteralPath $WorkerReport)) { throw 'Нет отчёта переподключения. Возможно, запрос Windows был отменён.' }
    $result = Get-Content -LiteralPath $WorkerReport -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $result.Success -or $worker.ExitCode -ne 0) { throw ('Переподключение не завершено: ' + $result.Error) }
    return $result
}

function Invoke-LiveRepair($Config, [string]$ConfigPath, [string]$WorkerReport, $Run) {
    $Run.Action = 'live_repair'; $Run.SessionBefore = @(Get-ProtectedSession)
    try {
        if (-not (Get-RewasdKeepVirtual $Config)) {
            throw 'В reWASD включите Настройки > Общее > Оставлять виртуальный контроллер в системе после отключения физического устройства и нажмите Применить. Переподключение не выполнялось.'
        }
        $Run.RemapBefore = @(Invoke-RemapOn $Config)
        $Run.ProofBefore = Show-InputProof
        if ($Run.ProofBefore.Cancelled) { throw 'Проверка отменена. Приёмник не переподключался.' }
        if (-not $Run.ProofBefore.Passed) {
            $answer = Show-RepairMessage 'Нет ответа от двух физических геймпадов. ОК переподключит их общий USB-приёмник. Оба геймпада могут выключиться; затем включите их кнопкой Steam. Мир продолжает работать, поэтому сначала оставьте персонажей в безопасном месте. Steam, игра и служба reWASD останутся запущенными. Отмена завершит починку без сброса.' -CanCancel
            if ([string]$answer -ne 'OK') { throw 'Переподключение отменено пользователем.' }
            Assert-SessionPreserved $Run.SessionBefore @(Get-ProtectedSession)
            $Run.Worker = Start-ReceiverWorker $ConfigPath $WorkerReport -DuringGame
            $Run.ReceiverReset = $true
            [void](Show-RepairMessage 'Приёмник переподключён. Включите оба геймпада кнопкой Steam. Дождитесь постоянного свечения и нажмите ОК, затем нажмите и отпустите A на каждом геймпаде в окне проверки.')
            $Run.RemapAfter = @(Invoke-RemapOn $Config)
            $Run.ProofAfter = Show-InputProof
            if (-not $Run.ProofAfter.Passed) { throw 'Ответ от двух физических геймпадов не подтверждён. Игра остаётся запущенной. Служба не перезапускалась; сохранён журнал.' }
        }
        $Run.After = Get-ControllerSnapshot
        if (-not (Test-ControllerReady $Run.After)) { throw 'Не восстановлены оба XInput-слота 0/1. Игра не перезапускалась.' }
        $Run.SessionAfter = @(Get-ProtectedSession)
        Assert-SessionPreserved $Run.SessionBefore $Run.SessionAfter
        $Run.SessionPreserved = $true; $Run.Success = $true
        [void](Show-RepairMessage 'Оба геймпада передают ввод, XInput 0/1 доступны. Запущенные игровые процессы, Steam и служба сохранились. Верните игровые окна через Ctrl+F9 и нажмите End один раз, если захват был освобождён. Проверьте, что каждый управляет своим персонажем; эта проверка не заменяется наличием двух Xbox.')
    } finally {
        $Run.SessionAfter = @(Get-ProtectedSession)
        try { Assert-SessionPreserved $Run.SessionBefore $Run.SessionAfter; $Run.SessionPreserved = $true }
        catch { $Run.SessionPreserved = $false; $Run.Success = $false; $Run.SessionError = $_.Exception.Message; throw }
    }
}


if ($LibraryOnly) { return }

if ($ReceiverWorker) {
    # The elevated worker can only reset the one specifically matched Steam receiver.
    $logRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Repair-Rewasd-logs')) + [IO.Path]::DirectorySeparatorChar
    $report = [IO.Path]::GetFullPath($ReportPath)
    if (-not $report.StartsWith($logRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected worker report path' }
    try {
        $workerConfig = $null
        if ($LiveRepair) { $workerConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        $reset = Invoke-ReceiverReset $workerConfig -DuringGame:$LiveRepair
        [pscustomobject]@{ Success = $true; Time = (Get-Date -Format o); Reset = $reset } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $report -Encoding UTF8
        exit 0
    } catch {
        [pscustomobject]@{ Success = $false; Time = (Get-Date -Format o); Error = $_.Exception.Message } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $report -Encoding UTF8
        exit 1
    }
}

$mutex = New-Object Threading.Mutex($false, 'Local\NucleusCoopRepairRewasd')
$ownsMutex = $false
$steamWasClosed = $false
$config = $null
$run = [ordered]@{ Started = (Get-Date -Format o); Success = $false; ReceiverReset = $false; ServiceRestarted = $false }
$logFile = $null
try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Починка уже запущена. Завершите первое окно.' }
    $before = Get-ControllerSnapshot
    if ($CheckOnly) {
        [pscustomobject]@{ Ready = (Test-ControllerReady $before); PhysicalInputVerified = $false; Snapshot = $before; BlockingGames = @(Get-BlockingGames) } | ConvertTo-Json -Depth 7
        return
    }
    if ($InputCheckOnly) {
        $proof = Show-InputProof
        $proof | ConvertTo-Json -Depth 5
        if (-not $proof.Passed) { exit 1 }
        return
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-RepairConfig $config
    $logRoot = Join-Path $PSScriptRoot 'Repair-Rewasd-logs'
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $logFile = Join-Path $logRoot ($stamp + '.json')
    $run.Before = $before
    if ($LiveRepair -or @(Get-BlockingGames).Count -gt 0 -or (Get-RewasdKeepVirtual $config)) {
        Invoke-LiveRepair $config $ConfigPath (Join-Path $logRoot ($stamp + '-receiver.json')) $run
        return
    }
    if (Test-ControllerReady $before) {
        $run.Success = $true; $run.Action = 'already_ready_no_changes'
        [void](Show-RepairMessage 'Оба виртуальных Xbox доступны. Если физический геймпад не отвечает, включите в reWASD сохранение виртуального контроллера при отключении и повторите проверку.')
        return
    }
    # Preserve the existing mapping; repair enumeration, not the profile contents.
    $run.ApplyBefore = @(Apply-SavedProfiles $config)
    $status = Get-ControllerSnapshot
    if (-not (Test-ControllerReady $status)) {
        if (Get-Process steam -ErrorAction SilentlyContinue) {
            if (@(Get-BlockingGames).Count -gt 0) { throw 'Игра запущена; Steam оставлен работающим.' }
            & $config.SteamPath -shutdown
            $deadline = (Get-Date).AddSeconds(25)
            while ((Get-Process steam -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
            if (Get-Process steam -ErrorAction SilentlyContinue) { throw 'Steam ещё не завершился. Дождитесь выхода и повторите ярлык.' }
            $steamWasClosed = $true
        }
        $workerReport = Join-Path $logRoot ($stamp + '-receiver.json')
        $powershell = (Get-Process -Id $PID).Path
        $workerArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),
            '-ReceiverWorker','-ReportPath',('"{0}"' -f $workerReport))
        $worker = Start-Process -FilePath $powershell -Verb RunAs -WindowStyle Hidden -ArgumentList $workerArgs -PassThru
        Wait-ReceiverWorker $worker
        if (-not (Test-Path -LiteralPath $workerReport)) { throw 'Нет отчёта переподключения. Возможно, запрос Windows был отменён.' }
        $workerResult = Get-Content -LiteralPath $workerReport -Raw -Encoding UTF8 | ConvertFrom-Json
        $run.Worker = $workerResult
        if (-not $workerResult.Success) { throw $workerResult.Error }
        $run.ReceiverReset = $true
        $answer = Show-RepairMessage "USB-приёмник переподключён. Геймпады могли выключиться: нажмите кнопку Steam на каждом, чтобы включить оба. Дождитесь постоянного свечения логотипов и нажмите ОК. Служба reWASD и лицензия не перезапускались." -CanCancel
        if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { throw 'Проверка отменена. Приёмник уже переподключён; игры не закрывались.' }
        $run.ApplyAfter = @(Apply-SavedProfiles $config)
        Start-Sleep -Seconds 2
        $status = Get-ControllerSnapshot
    }
    if (-not (Test-ControllerReady $status)) { throw 'После восстановления по-прежнему нет двух Xbox и XInput-слотов 0/1. Успех не подтверждён. Служба не перезапускалась; сохранён диагностический журнал.' }
    if ($steamWasClosed) {
        Start-Process -FilePath $config.SteamPath -ArgumentList '-silent' -WindowStyle Hidden | Out-Null
        $steamWasClosed = $false
        Start-Sleep -Seconds 3
        $status = Get-ControllerSnapshot
        if (-not (Test-ControllerReady $status)) { throw 'После возвращения Steam один геймпад снова пропал. Результат не подтверждён; сохранён журнал.' }
    }
    $run.After = $status; $run.Success = $true
    [void](Show-RepairMessage 'Готово: Windows видит два Xbox 360, XInput-слоты 0 и 1 доступны. Проверьте каждый геймпад в своём окне. Для V Rising после возврата окон нажмите End один раз.')
} catch {
    $run.Success = $false
    $run.Error = $_.Exception.Message
    if ($CheckOnly -or $InputCheckOnly) { throw }
    [void](Show-RepairMessage ($_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine + 'Журнал: ' + $logFile))
} finally {
    if ($steamWasClosed -and $config -and -not (Get-Process steam -ErrorAction SilentlyContinue)) {
        try { Start-Process -FilePath $config.SteamPath -ArgumentList '-silent' -WindowStyle Hidden | Out-Null; $run.SteamRestored = $true } catch { $run.SteamRestoreError = $_.Exception.Message }
    }
    if ($logFile) { $run.Completed = Get-Date -Format o; $run | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $logFile -Encoding UTF8 }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

# GUI errors also produce a failing exit status for command-line callers.
if (-not $run.Success) { exit 1 }
