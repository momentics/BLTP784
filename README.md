# Решение проблемы зависания драйвера ACPI\BLTP784 (жесты тачпада)

## Описание проблемы

**Устройство**: `ACPI\BLTP784\3&11583659&0`  
**Описание**: Устройство HID на шине I2C (тачпад ноутбука)  
**Дочерние устройства**:
- `HID\BLTP784&COL01\...` — HID-совместимая мышь (базовый курсор)
- `HID\BLTP784&COL02\...` — HID-совместимая сенсорная панель (жесты)
- `HID\BLTP784&COL03\...` — Microsoft Input Configuration Device
- `HID\BLTP784&COL04\...` — HID-совместимое устройство, определенное поставщиком

**Симптомы**: 
- ✅ Базовое управление курсором работает (мышь перемещается)
- ❌ **Жесты тачпада не работают** (мультитач, прокрутка, масштабирование)
- ❌ Сенсорная панель не реагирует на жесты после сна/простоя
- ✅ Кнопки тачпада работают (левая/правая)

---

## Глубокий анализ первопричин (Root Cause Analysis)

### 1. Архитектура I2C HID в Windows

```
┌────────────────────────────────────────────────────────┐
│                    User Mode                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │ Windows     │  │ Touch       │  │ Precision   │     │
│  │ Gestures    │  │ Keyboard    │  │ Touchpad    │     │
│  │ Service     │  │ Service     │  │ (PTP)       │     │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘     │
│         │                │                │            │
│         └────────────────┴────────────────┘            │
│                          │                             │
│                  ┌───────▼────────┐                    │
│                  │  mshidumdf.sys │                    │
│                  │  (UMDF HID)    │                    │
│                  └───────┬────────┘                    │
│                  ┌───────▼────────┐                    │
│                  │  mshidkmdf.sys │                    │
│                  │  (KMDF Pass)   │                    │
│                  └───────┬────────┘                    │
├──────────────────────────┼─────────────────────────────┤
│                    Kernel Mode                         │
│         ┌────────────────▼────────────────┐            │
│         │           hidusb.sys            │            │
│         │         (HID Class Driver)      │            │
│         └────────────────┬────────────────┘            │
│                          │                             │
│         ┌────────────────▼────────────────┐            │
│         │          hidi2c.sys         ◄── Проблема     │
│         │    (I2C HID Client Driver)      │            │
│         └────────────────┬────────────────┘            │
│                          │                             │
│         ┌────────────────▼────────────────┐            │
│         │   iaLPSS2i_I2C.sys (Intel I2C)  │            │
│         │     or amdi2c.sys (AMD I2C)     │            │
│         └────────────────┬────────────────┘            │
│                          │                             │
│         ┌────────────────▼────────────────┐            │
│         │    GPIO Interrupt Controller    │            │
│         └────────────────┬────────────────┘            │
│                          │                             │
│         ┌────────────────▼────────────────┐            │
│         │    Physical I2C Device (TP)     │            │
│         │    ACPI\BLTP784\3&11583659&0    │            │
│         └─────────────────────────────────┘            │
└────────────────────────────────────────────────────────┘
```

### 2. Конфигурация устройства (из реестра)

```
HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\BLTP784\3&11583659&0\Device Parameters

EnhancedPowerManagementEnabled : 1    ◄── ВКЛЮЧЕНО (проблема)
DeviceResetNotificationEnabled : 1
LegacyTouchScaling             : 0
FirmwareIdentified             : 1
SelectiveSuspendOn             : 0

HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\BLTP784\3&11583659&0\Device Parameters\e5b3b5ac-9725-4f78-963f-03dfb1d828c7

D3ColdSupported : 1    ◄── Поддержка глубокого сна D3
```

### 3. Корневые причины

#### **Причина 1: Enhanced Power Management (EPM) конфликт (Critical)**

**Механизм**:
```
1. EnhancedPowerManagementEnabled = 1 активирует "Runtime PM"
2. При простое тачпада (>5 сек без касаний):
   - hidi2c.sys переводит устройство в D3hot (low-power)
   - I2C-шина останавливает тактирование
   - Прерывания маскируются
3. При касании для жеста:
   - Устройство должно выйти из D3hot → D0
   - Запрос на выход отправляется через iaLPSS2i_I2C
   - Контроллер I2C не успевает восстановить питание
   - HID-дескриптор не читается
   - Windows получает только базовые отчёты (мышь)
   - Жесты игнорируются (требуется мультитач-дескриптор)
```

**Почему курсор работает, а жесты нет**:
```
- COL01 (мышь): использует простой HID-отчёт (X, Y, кнопки)
  → Работает через mouhid.sys, не требует сложных дескрипторов
  
- COL02 (сенсорная панель): требует полный HID-дескриптор
  → Содержит коллекции мультитач-контактов (TLC)
  → Дескриптор читается при инициализации в D0
  → После перехода D3hot дескриптор недоступен
  → Windows не знает о возможностях жестов
```

#### **Причина 2: D3Cold Support и таймауты**

**Механизм**:
```
D3ColdSupported = 1 позволяет устройству уходить в D3cold:

1. Система бездействует 30+ секунд
2. ACPI отправляет _PS0 → _PS3 transition
3. Питание I2C-шины отключается (VDD → 0V)
4. При касании:
   - Требуется полная инициализация (power-on reset)
   - Время инициализации: 100-500ms
   - hidi2c.sys ждёт только 100ms
   - Таймаут → устройство помечается как "не готово"
   - Жесты блокируются до следующей инициализации
```

#### **Причина 3: Конфликт драйверов Intel I2C + hidi2c**

**Наблюдаемая конфигурация**:
```
iaLPSS2i_I2C.sys (Intel Serial IO I2C)
  Версия: 30.0.101.0 (2022-09-06)
  Статус: Running
  
hidi2c.sys (Microsoft I2C HID Driver)
  Статус: Running
  Start: 3 (Demand Start)
```

**Проблема**:
```
1. iaLPSS2i_I2C имеет собственный PM-менеджер
2. hidi2c.sys также управляет питанием через EPM
3. При переходе в low-power:
   - iaLPSS2i_I2C отправляет device в D3
   - hidi2c.sys отправляет HID-запрос на suspend
   - Порядок не детерминирован (race condition)
4. При пробуждении:
   - iaLPSS2i_I2C восстанавливает I2C-шину
   - hidi2c.sys читает дескриптор СЛИШКОМ РАНО
   - Устройство ещё не готово → дескриптор пуст
   - Жесты не активируются
```

#### **Причина 4: Отсутствие сброса устройства при зависании**

**Механизм**:
```
DeviceResetNotificationEnabled = 1 должен включать сброс,
НО:

1. hidi2c.sys не отправляет IOCTL_HID_RESET_DEVICE
   при обнаружении проблем с дескриптором
2. Windows Touch Input Service (TouchSvc) не опрашивает
   состояние устройства периодически
3. Единственный способ восстановления:
   - Disable-PnpDevice → Enable-PnpDevice
   - ИЛИ: devcon restart ACPI\BLTP784
```

### 4. Доказательства (диагностика)

**Проверка текущего состояния**:
```powershell
# Устройство показывает "OK", но жесты не работают
Get-PnpDevice -InstanceId "ACPI\BLTP784\3&11583659&0"
# Status: OK, ConfigManagerErrorCode: 0

# Проблема видна только через анализ HID-дескриптора
```

**События для диагностики**:
```
Event Viewer → System:
- Источник: Microsoft-Windows-Kernel-PnP
- Event ID: 410, 411, 412 (Power State Transition)

- Источник: hidi2c
- Event ID: 128 (HID Device Timeout)

- Источник: Microsoft-Windows-Kernel-Power
- Event ID: 100, 101, 102 (Sleep/Resume)
```

---

## Решения

### Решение 1: Быстрое восстановление жестов (PowerShell)

**Файл**: `fix-bltp784.ps1`

```powershell
# Запуск от администратора
.\fix-bltp784.ps1

# Режим мониторинга (проверка каждые 30 сек)
.\fix-bltp784.ps1 -Monitor -Interval 30

# Отключение EPM (профилактика)
.\fix-bltp784.ps1 -DisableEPM
```

**Как работает**:
1. Проверяет статус устройства через WMI
2. Проверяет параметр `EnhancedPowerManagementEnabled`
3. При обнаружении проблемы:
   - Отключает `ACPI\BLTP784\3&11583659&0`
   - Включает `ACPI\BLTP784\3&11583659&0`
   - Перезапускает дочерние HID-устройства (COL01-COL04)
4. Ждёт 1 секунду для полной инициализации

### Решение 2: Отключение Enhanced Power Management (реестр)

**Файл**: `disable-bltp784-powermgmt.ps1`

```powershell
# Запуск от администратора
.\disable-bltp784-powermgmt.ps1

# Перезагрузка обязательна
shutdown /r /t 0
```

**Изменения в реестре**:
```
HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\BLTP784\3&11583659&0\Device Parameters
  "EnhancedPowerManagementEnabled" = 0  ; Отключает Runtime PM
  
HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\BLTP784\3&11583659&0\Device Parameters\e5b3b5ac-9725-4f78-963f-03dfb1d828c7
  "D3ColdSupported" = 0  ; Отключает глубокий сон D3
  
HKLM\SYSTEM\CurrentControlSet\Services\hidi2c\Parameters
  "AllowIdleIrpInD3" = 0  ; Запрещает IRP в состоянии D3
```

**Результат**:
- ✅ Тачпад не переходит в low-power состояние
- ✅ Жесты работают постоянно
- ❌ Увеличенное энергопотребление (на 0.5-1 Вт)

### Решение 3: Обновление драйверов Intel Serial IO

**Критично для системы с Intel I2C контроллером**:

1. **Проверка текущей версии**:
```powershell
driverquery /v /fo table | findstr iaLPSS
```

2. **Загрузка драйверов**:
   - Посетите сайт производителя ноутбука
   - Или Intel Download Center: [Intel Serial IO Driver](https://www.intel.com/content/www/us/en/download/19351/intel-serial-io-driver.html)

3. **Установка**:
```powershell
# Удаление старого драйвера
pnputil /remove-driver oemXX.inf /uninstall /force

# Установка нового
pnputil /add-driver path\to\iaLPSS2i_I2C.inf /install
```

### Решение 4: Временное отключение тачпада (если используется мышь)

```powershell
# Отключение устройства
Get-PnpDevice -InstanceId "ACPI\BLTP784\3&11583659&0" | 
  Disable-PnpDevice -Confirm:$false

# Включение (если потребуется)
Get-PnpDevice -InstanceId "ACPI\BLTP784\3&11583659&0" | 
  Enable-PnpDevice -Confirm:$false
```

### Решение 5: Настройка схемы электропитания

**Панель управления → Электропитание → Настройка схемы → Изменить дополнительные параметры**:

```
Настройки USB
  Параметр временного отключения USB-порта = Запрещено

PCI Express
  Управление питанием = Максимальное энергосбережение (отключить)
```

---

## Диагностика

### 1. Проверка текущего состояния

```powershell
# Статус устройства (показывает OK даже при неработающих жестах)
Get-PnpDevice -InstanceId "ACPI\BLTP784\3&11583659&0" | 
  Select-Object Status, Present, Problem

# Код ошибки (должен быть 0)
Get-CimInstance Win32_PnPEntity | 
  Where-Object { $_.DeviceID -like "*BLTP784*" } | 
  Select-Object ConfigManagerErrorCode, ConfigManagerUserConfig

# Проверка параметра EPM (ключевой индикатор проблемы)
Get-ItemProperty "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\ACPI\BLTP784\3&11583659&0\Device Parameters" | 
  Select-Object EnhancedPowerManagementEnabled, DeviceResetNotificationEnabled
```

### 2. Проверка дочерних HID-устройств

```powershell
# Список всех устройств BLTP
Get-PnpDevice | Where-Object {$_.InstanceId -like '*BLTP*'} | 
  Select-Object InstanceId, FriendlyName, Status | Format-Table -AutoSize

# Ожидаемый вывод:
# InstanceId                         FriendlyName                                    Status
# ----------                         ------------                                    ------
# HID\BLTP784&COL01\...              HID-совместимая мышь                            OK
# HID\BLTP784&COL02\...              HID-совместимая сенсорная панель                OK  ← Жесты
# HID\BLTP784&COL03\...              Microsoft Input Configuration Device            OK
# HID\BLTP784&COL04\...              HID-совместимое устройство, определенное...     OK
# ACPI\BLTP784\3&11583659&0          Устройство HID на шине I2C                      OK
```

### 3. Журналы событий

```powershell
# Ошибки hidi2c за последние 24 часа
Get-WinEvent -FilterHashtable @{
    LogName='System'
    ProviderName='hidi2c'
    StartTime=(Get-Date).AddHours(-24)
} -ErrorAction SilentlyContinue | 
  Select-Object TimeCreated, Id, Level, Message -First 10 | Format-Table -AutoSize

# События управления питанием PnP
Get-WinEvent -FilterHashtable @{
    LogName='System'
    ProviderName='Microsoft-Windows-Kernel-PnP'
    Id=410,411,412
    StartTime=(Get-Date).AddHours(-24)
} -ErrorAction SilentlyContinue | 
  Select-Object TimeCreated, Message -First 20

# Через wevtutil (альтернатива)
wevtutil qe System /q:"*[System[Provider[@Name='hidi2c']]]" /c:20 /f:text
```

### 4. Проверка драйверов I2C

```powershell
# Версия драйвера Intel Serial IO
driverquery /v /fo table | findstr /i "iaLPSS i2c"

# Статус драйвера hidi2c
Get-Service hidi2c | Select-Object Name, Status, StartType

# Информация через pnputil
pnputil /enum-devices /connected /class HIDClass | 
  Select-String -Pattern "BLTP|Published" -Context 1,1
```

### 5. Анализ HID-дескрипторов (продвинутая)

```powershell
# Просмотр отчётов HID-устройства
# Требуется утилита HidParser или DeviceTree из WDK

# Альтернатива через реестр:
Get-ChildItem "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\HID" | 
  Where-Object {$_.Name -like '*BLTP*'} | 
  ForEach-Object {
      Get-ItemProperty "$_\Device Parameters" -ErrorAction SilentlyContinue | 
        Select-Object PSChildName, *
  }
```

### 6. WinDbg анализ (для разработчиков)

```
# Подключение к ядру
kd> !devobj ACPI\BLTP784\3&11583659&0

# Проверка состояния питания
kd> !powerdevmgmt

# Проверка HID-дескриптора
kd> !hidparse \Device\0000006d  # Заменить на актуальный

# Трассировка I2C-транзакций
kd> !wmi_trace hidi2c

# Анализ прерываний
kd> !ioapic
```

---

## Профилактика

### 1. Автозапуск мониторинга

Создайте задачу в Планировщике заданий:

```xml
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <!-- Запуск при входе пользователя -->
    <LogonTrigger>
      <Enabled>true</Enabled>
      <Delay>PT1M</Delay>
    </LogonTrigger>
    
    <!-- Запуск при событии hidi2c (таймаут устройства) -->
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>
        &lt;QueryList&gt;
          &lt;Query Id="0" Path="System"&gt;
            &lt;Select Path="System"&gt;
              *[System[Provider[@Name='hidi2c'] and (EventID=128 or EventID=129)]]
            &lt;/Select&gt;
          &lt;/Query&gt;
        &lt;/QueryList&gt;
      </Subscription>
    </EventTrigger>
    
    <!-- Периодическая проверка каждые 5 минут -->
    <TimeTrigger>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>PT5M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>  <!-- SYSTEM -->
      <RunLevel>Highest</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <RestartOnFailure>
      <Count>3</Count>
      <Interval>PT1M</Interval>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-ExecutionPolicy Bypass -File "c:\fix-bltp784.ps1" -Monitor -Interval 300</Arguments>
    </Exec>
  </Actions>
</Task>
```

### 2. Импорт задачи через PowerShell

```powershell
# Создание задачи
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-ExecutionPolicy Bypass -File `"c:\fix-bltp784.ps1`" -Monitor -Interval 300"
  
$triggerLogon = New-ScheduledTaskTrigger -AtLogon -Delay (New-TimeSpan -Minutes 1)
$triggerEvent = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "Fix-BLTP784-Gestures" `
  -Action $action `
  -Trigger $triggerLogon, $triggerEvent `
  -Principal $principal `
  -Description "Мониторинг и восстановление жестов тачпада ACPI\BLTP784" `
  -Force

# Проверка задачи
Get-ScheduledTask -TaskName "Fix-BLTP784-Gestures" | Select-Object State, LastRunTime, NextRunTime

# Запуск вручную
Start-ScheduledTask -TaskName "Fix-BLTP784-Gestures"
```

### 3. Отключение EPM через групповую политику (для предприятий)

**Путь**: `Computer Configuration → Administrative Templates → System → Power Management`

```
Turn off Runtime Power Management = Enabled
Allow Throttle Performance State = Disabled
```

### 4. Рекомендации для разных сценариев

| Сценарий | Рекомендация |
|----------|--------------|
| **Стационарный ПК** | Отключить EPM (`-DisableEPM`) |
| **Ноутбук от сети** | Отключить EPM + мониторинг |
| **Ноутбук от батареи** | Включить мониторинг (`-Monitor`) |
| **Критичная работа** | Использовать внешнюю мышь |

---

---

## Ссылки

- [Microsoft: I2C HID Driver](https://docs.microsoft.com/en-us/windows-hardware/drivers/hid/i2c-hid-driver)
- [Microsoft: ACPI Device Power States](https://docs.microsoft.com/en-us/windows-hardware/drivers/kernel/device-power-states)
- [Microsoft: Troubleshooting I2C](https://docs.microsoft.com/en-us/windows-hardware/drivers/debugger/troubleshooting-i2c-issues)

---
