# USB Watchdog для LTE/3G модема — MikroTik (RouterOS 7.24+)

Скрипт автоматического мониторинга и восстановления интернет-соединения через USB-модем для роутеров MikroTik (**RouterOS 7.24+**, протестировано на **RB2011**).

**Версия: v2.1 Hardened & Decoupled** (RAM-First, 0 Flash Wear, Dual-Ping, Decoupled Secrets).

---

## Возможности и архитектура v2.1

1. **Защита Flash-памяти (RAM-First, 0 Flash Wear):**
   - Все рабочие счетчики тиков, бэкоффа и проверок живут **исключительно в оперативной памяти (ОЗУ)**.
   - Чтение файла состояния с диска происходит **только 1 раз при старте роутера**.
   - Дифференциальная запись на диск (`/file set`) выполняется **только при реальной смене макро-состояния** (переход в бэкофф / восстановление). В штатном режиме нагрузка на Flash-память ровна **0**.
2. **Отказоустойчивый Dual-Ping:**
   - Мониторинг по двум независимым узлам (`77.88.8.8` Яндекс DNS и `1.1.1.1` Cloudflare DNS).
   - Исключает ложные перезагрузки модема при деградации одного из провайдеров DNS.
3. **Быстрые попытки сброса (USB Power-Reset):**
   - До `maxQuickAttempts` (по умолчанию 2) попыток с паузой `quickRetryTicks` (2 мин).
4. **Прогрессивный бэкофф (Exponential Backoff):**
   - 1-й цикл: пауза **2 часа** (240 тиков).
   - 2-й цикл: пауза **6 часов** (720 тиков).
5. **Изоляция секретов (Decoupled Secrets):**
   - Секретный URL вебхука хранится в отдельном изолированном скрипте `usb-watchdog-secrets`. Основной код `usb-watchdog-check.rsc` на 100% обезличен и безопасен для публикации в Git.
6. **Уведомления в Synology Chat:**
   - Оповещение отправляется только при фактическом восстановлении связи после аварии.
7. **Крайняя мера (Reboot Fallback):**
   - Полная перезагрузка роутера (`/system reboot`) при исчерпании всех циклов бэкоффа.

---

## Настраиваемые параметры

В начале файла `usb-watchdog-check.rsc`:

| Параметр | Значение по умолчанию | Описание |
| :--- | :--- | :--- |
| `pingHost1` | `"77.88.8.8"` | Основной контрольный IP-адрес (Яндекс DNS) |
| `pingHost2` | `"1.1.1.1"` | Резервный контрольный IP-адрес (Cloudflare DNS) |
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

## Установка и настройка

### Шаг 1. Создание скрипта секретов `usb-watchdog-secrets` (один раз)

В терминале MikroTik выполните:
```routeros
/system script add name=usb-watchdog-secrets policy=read,test source=":global synoChatWebhook \"https://YOUR-NAS:5001/webapi/entry.cgi?api=SYNO.Chat.External&method=incoming&version=2&token=YOUR_TOKEN\""
```

---

### Шаг 2. Создание основного скрипта `usb-watchdog-check`

**Вариант А (прямая загрузка из локального Gitea «Чай»):**
```routeros
/tool fetch url="http://10.10.30.105:3000/home-lab/mikrotik-usb-watchdog/raw/branch/main/usb-watchdog-check.rsc" dst-path="usb-watchdog-check.rsc"
/system script add name=usb-watchdog-check policy=read,write,test,reboot source=[/file get "usb-watchdog-check.rsc" contents]
/file remove "usb-watchdog-check.rsc"
```

**Вариант Б (через WinBox):**
1. Откройте **System → Scripts → Add (+)**.
2. Имя: `usb-watchdog-check`.
3. Policies: `read`, `write`, `test`, `reboot`.
4. Вставьте код из `usb-watchdog-check.rsc`.

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
3. **Ручной тест сброса USB-порта:**
   ```routeros
   /system routerboard usb power-reset duration=5s
   ```
