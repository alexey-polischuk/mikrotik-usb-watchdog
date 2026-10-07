# USB Watchdog для LTE/3G модема — MikroTik (RouterOS v7.24.5 stable)

Скрипт автоматического мониторинга и восстановления интернет-соединения через USB-модем для роутеров MikroTik.  
**Протестировано и находится в эксплуатации на:** RouterOS **v7.24.5 (stable)**, платформа **MikroTik RB2011UiAS-2HnD** (MIPSBE).

**Актуальная версия: v2.1.0** (RAM-First, 0 Flash Wear, Dual-Ping РФ, Decoupled Secrets).

> 📁 **Архив версий:** Исходная версия v1.0 сохранена в каталоге [`archive/v1.0/`](archive/v1.0/).  
> 📝 **История изменений:** Подробный журнал версий доступен в [`CHANGELOG.md`](CHANGELOG.md).

---

## 🖥️ Аппаратное и программное тестовое окружение

Скрипт протестирован и находится в постоянной боевой эксплуатации в следующем сетевом контуре:

* **Модель роутера:** MikroTik `RB2011UiAS-2HnD`
* **Архитектура платформы:** `MIPSBE` (SoC Atheros AR9344 600 MHz, 128 MB RAM, 128 MB NAND Flash)
* **Версия операционной системы:** RouterOS `v7.24.5 (stable)`
* **Версия RouterBOOT (Firmware):** `7.24.5` (firmware-type: `ar9344`)
* **Тип USB-модема:** USB LTE/4G модем в режиме NCM/RNDIS/CDC-Ethernet (интерфейс `lte1`, внутренний шлюз модема `192.168.1.1`, сеть Yota / Мегафон)
* **Управление питанием:** Аппаратный USB Power-Reset (`/system routerboard usb power-reset`)

---

## Структура репозитория

```text
mikrotik-usb-watchdog/
├── usb-watchdog-check.rsc            # Основной скрипт мониторинга (v2.1)
├── usb-watchdog-secrets.rsc.template # Шаблон скрипта секретов (Synology Chat Webhook)
├── CHANGELOG.md                      # Журнал изменений версий
├── README.md                         # Документация и руководство по установке
└── archive/
    └── v1.0/
        └── usb-watchdog-check-v1.0.rsc # Архивная рабочая версия v1.0
```

---

## Возможности и архитектура v2.1

1. **Защита Flash-памяти (RAM-First, 0 Flash Wear):**
   - Все рабочие счетчики тиков, бэкоффа и проверок живут **исключительно в оперативной памяти (ОЗУ)**.
   - Чтение файла состояния с диска происходит **только 1 раз при старте роутера**.
   - Дифференциальная запись на диск (`/file set`) выполняется **только при реальной смене макро-состояния** (переход в бэкофф / восстановление). В штатном режиме нагрузка на Flash-память равна **0 записей в сутки**.
2. **Отказоустойчивый Dual-Ping для РФ:**
   - Мониторинг по двум независимым узлам:
     - `pingHost1` = `77.88.8.8` (Яндекс DNS)
     - `pingHost2` = `195.208.4.1` (НСДИ РФ / НИИ «Восход», RTT ~25–40 ms)
   - Полная независимость от блокировок зарубежных DNS (`8.8.8.8`, `1.1.1.1`) на российских сотовых операторах.
3. **Быстрые попытки сброса (USB Power-Reset):**
   - До `maxQuickAttempts` (по умолчанию 2) попыток с паузой `quickRetryTicks` (2 мин).
4. **Прогрессивный бэкофф (Exponential Backoff):**
   - 1-й цикл: пауза **2 часа** (240 тиков).
   - 2-й цикл: пауза **6 часов** (720 тиков).
5. **Изоляция секретов (Decoupled Secrets):**
   - Секретный URL вебхука хранится в отдельном изолированном скрипте `usb-watchdog-secrets` с минимальными правами `read,test`. Основной код `usb-watchdog-check.rsc` на 100% обезличен и безопасен для публикации в Git.
6. **Уведомления в Synology Chat:**
   - Оповещение отправляется только при фактическом восстановлении связи после аварии.
7. **Крайняя мера (Reboot Fallback):**
   - Полная системная перезагрузка роутера (`/system reboot`) при исчерпании лимита бэкофф-циклов.

---

## Настраиваемые параметры

В начале файла `usb-watchdog-check.rsc`:

| Параметр | Значение по умолчанию | Описание |
| :--- | :--- | :--- |
| `pingHost1` | `"77.88.8.8"` | Основной контрольный IP-адрес (Яндекс DNS) |
| `pingHost2` | `"195.208.4.1"` | Резервный контрольный IP-адрес (НСДИ РФ) |
| `failThreshold` | `4` | Количество подряд неудачных проверок для фиксации аварии (4 * 30с = 2 мин) |
| `usbResetDuration` | `"10s"` | Длительность отключения питания USB-порта при сбросе |
| `maxQuickAttempts` | `2` | Количество подряд идущих быстрых попыток USB power-reset |
| `quickRetryTicks` | `4` | Пауза между быстрыми попытками (4 * 30с = 2 мин) для инициализации модема |
| `backoffInitialTicks` | `240` | Длительность первого бэкоффа (240 * 30с = 2 часа) |
| `backoffMaxTicks` | `720` | Максимальный потолок бэкоффа (720 * 30с = 6 часов) |
| `backoffMultiplier` | `3` | Множитель времени ожидания между циклами бэкоффа (2ч -> 6ч) |
| `maxRebootCycles` | `2` | Количество бэкофф-циклов до выполнения системной перезагрузки роутера |
| `tickSeconds` | `30` | Интервал вызова скрипта планировщиком (в секундах) |
| `stateFileName` | `"usb-watchdog-state.txt"` | Имя файла состояния на накопителе роутера |

---

## Установка и настройка на MikroTik

### Шаг 1. Создание скрипта секретов `usb-watchdog-secrets` (один раз)

В терминале MikroTik выполните:
```routeros
/system script add name=usb-watchdog-secrets policy=read,test source=":global synoChatWebhook \"https://YOUR-NAS:5001/webapi/entry.cgi?api=SYNO.Chat.External&method=incoming&version=2&token=YOUR_TOKEN\""
```

---

### Шаг 2. Создание или обновление основного скрипта `usb-watchdog-check`

#### Вариант А. Через WinBox (Рекомендуется)
1. Откройте **System → Scripts**.
2. Создайте новый или откройте существующий скрипт **`usb-watchdog-check`**.
3. Установите флаги Policies: `read`, `write`, `test`, `reboot`.
4. Вставьте код из файла [`usb-watchdog-check.rsc`](usb-watchdog-check.rsc).
5. Нажмите **Apply** → **OK**.

#### Вариант Б. Через терминал MikroTik (CLI)
```routeros
/system script add name=usb-watchdog-check policy=read,write,test,reboot
/system script edit usb-watchdog-check source
```
*(Вставьте код скрипта, сохраните комбинацией `Ctrl+O` и выйдите `Ctrl+X`).*

---

### Шаг 3. Создание задачи в планировщике (Scheduler)

```routeros
/system scheduler add name=usb-watchdog-scheduler interval=30s start-time=startup on-event="/system script run usb-watchdog-check" policy=read,write,test,reboot
```

---

## Диагностика и проверка

1. **Просмотр логов:**
   ```routeros
   /log print where message~"usb-watchdog"
   ```
2. **Проверка файла состояния на Flash:**
   ```routeros
   /file print where name~"usb-watchdog-state"
   /file get [find where name~"usb-watchdog-state"] contents
   ```
3. **Ручной тест сброса питания USB-порта:**
   ```routeros
   /system routerboard usb power-reset duration=5s
   ```
