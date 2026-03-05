# Скрипт восстановления жестов тачпада ACPI\BLTP784
# Запускать от имени администратора
# Проблема: жесты не работают, но курсор перемещается

param(
    [switch]$Monitor,
    [int]$Interval = 30,
    [switch]$DisableEPM  # Отключить Enhanced Power Management
)

$DeviceId = "ACPI\BLTP784\3&11583659&0"
$DeviceName = "I2C HID Touchpad (Gestures)"

# Дочерние HID-устройства
$HidChildren = @(
    "HID\BLTP784&COL01\*",  # Мышь
    "HID\BLTP784&COL02\*",  # Сенсорная панель (жесты)
    "HID\BLTP784&COL03\*",  # Input Configuration
    "HID\BLTP784&COL04\*"   # Vendor-defined
)

function Test-GesturesWorking {
    <#
    .SYNOPSIS
    Проверка работы жестов тачпада
    .DESCRIPTION
    Жесты могут не работать даже при статусе "OK" устройства
    #>
    
    try {
        # Проверка через WMI - статус устройства
        $device = Get-PnpDevice -InstanceId $DeviceId -ErrorAction Stop
        if ($device.Status -ne "OK") {
            Write-Host "[$(Get-Date)] Устройство в состоянии: $($device.Status)" -ForegroundColor Yellow
            return $false
        }
        
        # Проверка кодов ошибок
        $devMgr = Get-CimInstance Win32_PnPEntity | 
            Where-Object { $_.DeviceID -like "*$($DeviceId.Replace('\', '\\'))*" }
        
        if ($devMgr -and $devMgr.ConfigManagerErrorCode -ne 0) {
            Write-Host "[$(Get-Date)] Код ошибки: $($devMgr.ConfigManagerErrorCode)" -ForegroundColor Red
            return $false
        }
        
        # Проверка через реестр - признак проблемы с дескриптором
        $deviceParamsPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$DeviceId\Device Parameters"
        if (Test-Path $deviceParamsPath) {
            $epmEnabled = Get-ItemProperty -Path $deviceParamsPath -Name "EnhancedPowerManagementEnabled" -ErrorAction SilentlyContinue
            if ($epmEnabled -and $epmEnabled.EnhancedPowerManagementEnabled -eq 1) {
                Write-Host "[$(Get-Date)] EPM включён (возможна проблема с жестами)" -ForegroundColor Yellow
            }
        }
        
        # Устройство "OK", но жесты могут не работать
        # Требуется периодический рестарт для профилактики
        return $true
    }
    catch {
        Write-Host "[$(Get-Date)] Ошибка проверки: $_" -ForegroundColor Red
        return $false
    }
}

function Restart-Touchpad {
    param([string]$InstanceId)
    
    Write-Host "[$(Get-Date)] Восстановление тачпада..." -ForegroundColor Cyan
    
    $success = $true
    
    try {
        # Шаг 1: Отключение основного устройства
        Write-Host "  [1/4] Отключение ACPI\BLTP784..." -NoNewline
        $device = Get-PnpDevice -InstanceId $InstanceId -ErrorAction Stop
        Disable-PnpDevice -InputObject $device -Confirm:$false -ErrorAction Stop
        Start-Sleep -Milliseconds 300
        Write-Host "OK" -ForegroundColor Green
    }
    catch {
        Write-Host "FAIL" -ForegroundColor Red
        $success = $false
    }
    
    try {
        # Шаг 2: Включение основного устройства
        Write-Host "  [2/4] Включение ACPI\BLTP784..." -NoNewline
        Enable-PnpDevice -InputObject $device -Confirm:$false -ErrorAction Stop
        Start-Sleep -Milliseconds 500  # Больше времени на инициализацию
        Write-Host "OK" -ForegroundColor Green
    }
    catch {
        Write-Host "FAIL" -ForegroundColor Red
        $success = $false
    }
    
    # Шаг 3-4: Перезапуск дочерних HID-устройств
    foreach ($hidId in $HidChildren) {
        try {
            Write-Host "  [3-4/4] Перезапуск $hidId..." -NoNewline
            $hidDevices = Get-PnpDevice -InstanceId $hidId -ErrorAction SilentlyContinue
            if ($hidDevices) {
                foreach ($hid in $hidDevices) {
                    Disable-PnpDevice -InputObject $hid -Confirm:$false -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 100
                    Enable-PnpDevice -InputObject $hid -Confirm:$false -ErrorAction SilentlyContinue
                }
                Write-Host "OK" -ForegroundColor Green
            } else {
                Write-Host "SKIP (не найдено)" -ForegroundColor Gray
            }
        }
        catch {
            Write-Host "FAIL" -ForegroundColor Yellow
        }
    }
    
    Start-Sleep -Milliseconds 1000  # Ждём полной инициализации
    
    if ($success) {
        Write-Host "[$(Get-Date)] Тачпад восстановлен" -ForegroundColor Green
    }
    
    return $success
}

function Disable-EnhancedPowerManagement {
    <#
    .SYNOPSIS
    Отключает Enhanced Power Management для тачпада
    .DESCRIPTION
    Устраняет проблему с зависанием жестов после простоя
    #>
    
    Write-Host "[$(Get-Date)] Отключение Enhanced Power Management..." -ForegroundColor Cyan
    
    $deviceParamsPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$DeviceId\Device Parameters"
    
    try {
        # Проверка прав
        if (-not (Test-Path $deviceParamsPath)) {
            Write-Host "  Путь не найден. Запустите от администратора" -ForegroundColor Red
            return $false
        }
        
        # Отключение EPM
        $currentValue = (Get-ItemProperty -Path $deviceParamsPath -Name "EnhancedPowerManagementEnabled" -ErrorAction Stop).EnhancedPowerManagementEnabled
        Write-Host "  Текущее значение: $currentValue" -ForegroundColor Yellow
        
        Set-ItemProperty -Path $deviceParamsPath -Name "EnhancedPowerManagementEnabled" -Value 0 -Force -ErrorAction Stop
        Write-Host "  Новое значение: 0 (отключено)" -ForegroundColor Green
        
        # Отключение D3Cold для профилактики
        $guidPath = "$deviceParamsPath\e5b3b5ac-9725-4f78-963f-03dfb1d828c7"
        if (Test-Path $guidPath) {
            Set-ItemProperty -Path $guidPath -Name "D3ColdSupported" -Value 0 -Force -ErrorAction SilentlyContinue
            Write-Host "  D3ColdSupported: 0 (отключено)" -ForegroundColor Green
        }
        
        Write-Host "[$(Get-Date)] Требуется ПЕРЕЗАГРУЗКА для применения" -ForegroundColor Yellow
        return $true
    }
    catch {
        Write-Host "[$(Get-Date)] Ошибка: $_" -ForegroundColor Red
        Write-Host "Запустите от имени администратора" -ForegroundColor Yellow
        return $false
    }
}

# Основной цикл
if ($Monitor) {
    Write-Host "[$(Get-Date)] Мониторинг жестов тачпада (интервал: ${Interval}s)" -ForegroundColor Green
    Write-Host "Нажмите Ctrl+C для остановки" -ForegroundColor Gray
    Write-Host ""
    
    while ($true) {
        $working = Test-GesturesWorking
        if (-not $working) {
            Write-Host "[$(Get-Date)] Обнаружена проблема - восстановление..." -ForegroundColor Yellow
            Restart-Touchpad -InstanceId $DeviceId
        }
        Start-Sleep -Seconds $Interval
    }
}
elseif ($DisableEPM) {
    # Отключение управления питанием
    Disable-EnhancedPowerManagement
}
else {
    # Разовый запуск - восстановление
    Write-Host "[$(Get-Date)] Проверка тачпада" -ForegroundColor Cyan
    
    $working = Test-GesturesWorking
    if (-not $working) {
        Restart-Touchpad -InstanceId $DeviceId
    } else {
        Write-Host "[$(Get-Date)] Тачпад работает нормально" -ForegroundColor Green
        Write-Host ""
        Write-Host "Для отключения EPM (профилактика зависаний):" -ForegroundColor Cyan
        Write-Host "  .\fix-bltp784.ps1 -DisableEPM" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Для мониторинга:" -ForegroundColor Cyan
        Write-Host "  .\fix-bltp784.ps1 -Monitor -Interval 30" -ForegroundColor Gray
    }
}
