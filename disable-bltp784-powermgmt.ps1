# Отключение Enhanced Power Management для I2C HID тачпада
# Устраняет зависание жестов после простоя/сна
# Запускать от имени администратора

Write-Host "Отключение Enhanced Power Management для ACPI\BLTP784..." -ForegroundColor Cyan
Write-Host ""

$DeviceId = "ACPI\BLTP784\3&11583659&0"
$DeviceParamsPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$DeviceId\Device Parameters"

try {
    # Проверка существования ключа
    if (-not (Test-Path $DeviceParamsPath)) {
        throw "Путь не найден. Проверьте InstanceId устройства."
    }
    
    # Чтение текущего значения
    $currentEpm = (Get-ItemProperty -Path $DeviceParamsPath -Name "EnhancedPowerManagementEnabled" -ErrorAction Stop).EnhancedPowerManagementEnabled
    Write-Host "Текущие параметры:" -ForegroundColor Yellow
    Write-Host "  EnhancedPowerManagementEnabled = $currentEpm" -ForegroundColor Gray
    
    if ($currentEpm -eq 0) {
        Write-Host "`nEPM уже отключён" -ForegroundColor Green
    }
    else {
        # Отключение EPM
        Write-Host ""
        Write-Host "Изменение параметров..." -ForegroundColor Cyan
        Set-ItemProperty -Path $DeviceParamsPath -Name "EnhancedPowerManagementEnabled" -Value 0 -Force -ErrorAction Stop
        Write-Host "  EnhancedPowerManagementEnabled = 0" -ForegroundColor Green
        
        # Отключение D3Cold для профилактики
        $guidPath = "$DeviceParamsPath\e5b3b5ac-9725-4f78-963f-03dfb1d828c7"
        if (Test-Path $guidPath) {
            $currentD3Cold = (Get-ItemProperty -Path $guidPath -Name "D3ColdSupported" -ErrorAction SilentlyContinue).D3ColdSupported
            Write-Host "  D3ColdSupported = $currentD3Cold" -ForegroundColor Gray
            
            Set-ItemProperty -Path $guidPath -Name "D3ColdSupported" -Value 0 -Force -ErrorAction SilentlyContinue
            Write-Host "  D3ColdSupported = 0" -ForegroundColor Green
        }
    }
    
    # Глобальное отключение для всех I2C HID (опционально)
    Write-Host ""
    Write-Host "Глобальные параметры (i2c_hid):" -ForegroundColor Yellow
    $I2CHidPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\hidi2c\Parameters"
    
    if (-not (Test-Path $I2CHidPath)) {
        New-Item -Path $I2CHidPath -Force -ErrorAction SilentlyContinue | Out-Null
    }
    
    # Проверка существующих значений
    $existingProps = Get-ItemProperty -Path $I2CHidPath -ErrorAction SilentlyContinue
    if ($existingProps.PSObject.Properties.Match('AllowIdleIrpInD3')) {
        Write-Host "  AllowIdleIrpInD3 = $($existingProps.AllowIdleIrpInD3)" -ForegroundColor Gray
    } else {
        Write-Host "  AllowIdleIrpInD3 = (не задано)" -ForegroundColor Gray
    }
    
    # Установка значения
    Set-ItemProperty -Path $I2CHidPath -Name "AllowIdleIrpInD3" -Value 0 -Force -ErrorAction SilentlyContinue
    Write-Host "  AllowIdleIrpInD3 = 0" -ForegroundColor Green
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Требуется ПЕРЕЗАГРУЗКА для применения изменений" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Для перезагрузки сейчас: shutdown /r /t 0" -ForegroundColor Gray
}
catch {
    Write-Host ""
    Write-Host "Ошибка: $_" -ForegroundColor Red
    Write-Host "Запустите скрипт от имени администратора" -ForegroundColor Yellow
}
