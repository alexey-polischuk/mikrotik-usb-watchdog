# ============================================================
# USB LTE/3G modem watchdog — тело скрипта "usb-watchdog-check"
# Роутер: MikroTik RB2011 (Wireless), RouterOS 7.24
#
# Логика:
#  1) раз в 30 сек (через scheduler) пингуем контрольный адрес;
#  2) после failThreshold подряд неудачных проверок считаем связь
#     "точно упавшей" и делаем USB power-reset;
#  3) быстрых попыток сброса — maxQuickAttempts (по умолчанию 2),
#     между ними пауза quickRetryTicks*30 сек (по умолчанию 2 мин);
#  4) если быстрые попытки не помогли — уходим в бэкофф:
#     1-й цикл: 2 часа ожидания (240 тиков),
#     2-й цикл: 6 часов ожидания (720 тиков),
#     дальше держится потолок в 6 часов;
#  5) если maxRebootCycles бэкофф-циклов подряд не помогли —
#     крайняя мера: полная перезагрузка роутера;
#  6) состояние (попытки, бэкофф, ожидание, циклы) сохраняется в
#     файл usb-watchdog-state.txt на диске роутера и переживает
#     перезапуск скрипта и перезагрузку роутера;
#  7) при восстановлении связи (если до этого реально производился
#     сброс модема или был бэкофф) — отправляется уведомление
#     в Synology Chat по входящему вебхуку.
# ============================================================

:global wdFailCount
:global wdQuickAttempts
:global wdBackoffTicks
:global wdWaitTicks
:global wdRebootCycles

# ---------------- настройки (можно менять) ----------------
:local pingAddress "77.88.8.8"
:local failThreshold 4
:local usbResetDuration "10s"
:local maxQuickAttempts 2
:local quickRetryTicks 4
:local backoffInitialTicks 240
:local backoffMaxTicks 720
:local backoffMultiplier 3
:local maxRebootCycles 2
:local tickSeconds 30
:local webhookUrl "https://YOUR-NAS-ADDRESS:5001/webapi/entry.cgi?api=SYNO.Chat.External&method=incoming&version=2&token=YOUR_TOKEN"
:local stateFileBase "usb-watchdog-state"
:local stateFile "usb-watchdog-state.txt"
# ------------------------------------------------------------

:if ([:typeof $wdFailCount] = "nothing") do={ :set wdFailCount 0 }
:if ([:typeof $wdQuickAttempts] = "nothing") do={ :set wdQuickAttempts 0 }
:if ([:typeof $wdBackoffTicks] = "nothing") do={ :set wdBackoffTicks $backoffInitialTicks }
:if ([:typeof $wdWaitTicks] = "nothing") do={ :set wdWaitTicks 0 }
:if ([:typeof $wdRebootCycles] = "nothing") do={ :set wdRebootCycles 0 }

# ---- подхватываем состояние с диска (переживает перезагрузку) ----
:do {
    :local fileId [/file find where name~"usb-watchdog-state\\.txt"]
    :if ([:len $fileId] > 0) do={
        :local raw [/file get [:pick $fileId 0] contents]
        :local p1 [:find $raw ";"]
        :if ([:typeof $p1] = "num") do={
            :local p2 [:find $raw ";" ($p1 + 1)]
            :if ([:typeof $p2] = "num") do={
                :local p3 [:find $raw ";" ($p2 + 1)]
                :if ([:typeof $p3] = "num") do={
                    :set wdQuickAttempts [:tonum [:pick $raw 0 $p1]]
                    :set wdBackoffTicks [:tonum [:pick $raw ($p1 + 1) $p2]]
                    :set wdWaitTicks [:tonum [:pick $raw ($p2 + 1) $p3]]
                    :set wdRebootCycles [:tonum [:pick $raw ($p3 + 1) [:len $raw]]]
                }
            }
        }
    }
} on-error={
    :log info "usb-watchdog: файл состояния не найден или пуст, используются значения по умолчанию"
}

# ---- проверка доступности интернета ----
:local isUp false
:do {
    :local received [/ping $pingAddress count=2]
    :if ($received > 0) do={ :set isUp true }
} on-error={ :set isUp false }

:if ($isUp = true) do={
    :if ($wdFailCount >= $failThreshold) do={
        :log info "usb-watchdog: связь восстановлена"
        :if ($wdQuickAttempts > 0 or $wdRebootCycles > 0) do={
            :if ($webhookUrl != "" and !($webhookUrl ~ "YOUR-NAS-ADDRESS")) do={
                :do {
                    /tool fetch url=$webhookUrl http-method=post \
                        http-header-field="Content-Type: application/x-www-form-urlencoded" \
                        http-data="payload={\"text\":\"USB watchdog: интернет восстановлен после сброса модема\"}" \
                        output=none
                } on-error={
                    :log warning "usb-watchdog: не удалось отправить вебхук о восстановлении"
                }
            }
        }
    }
    :set wdFailCount 0
    :set wdQuickAttempts 0
    :set wdBackoffTicks $backoffInitialTicks
    :set wdWaitTicks 0
    :set wdRebootCycles 0
} else={
    :set wdFailCount ($wdFailCount + 1)
    :log info ("usb-watchdog: пинг не прошел, failCount=" . $wdFailCount)

    :if ($wdFailCount >= $failThreshold) do={
        :if ($wdWaitTicks > 0) do={
            :set wdWaitTicks ($wdWaitTicks - 1)
            :log info ("usb-watchdog: ожидание (бэкофф/пауза), осталось тиков=" . $wdWaitTicks)
        } else={
            :if ($wdQuickAttempts < $maxQuickAttempts) do={
                :log warning ("usb-watchdog: USB power-reset, попытка #" . ($wdQuickAttempts + 1))
                :do {
                    /system routerboard usb power-reset duration=$usbResetDuration
                } on-error={
                    :log warning "usb-watchdog: вызов power-reset не удался (возможно reset уже идет), повтор на следующем тике"
                }
                :set wdQuickAttempts ($wdQuickAttempts + 1)
                :set wdWaitTicks $quickRetryTicks
            } else={
                :if ($wdRebootCycles >= $maxRebootCycles) do={
                    :log error "usb-watchdog: бэкофф-циклы исчерпаны, перезагружаю роутер (крайняя мера)"
                    :local resetContent ("0;" . $backoffInitialTicks . ";0;0")
                    :do {
                        :local fileId [/file find where name~"usb-watchdog-state\\.txt"]
                        :if ([:len $fileId] = 0) do={
                            /file print file=$stateFileBase
                            :delay 2s
                            :set fileId [/file find where name~"usb-watchdog-state\\.txt"]
                        }
                        :if ([:len $fileId] > 0) do={
                            /file set [:pick $fileId 0] contents=$resetContent
                        }
                    } on-error={}
                    /system reboot
                } else={
                    :set wdWaitTicks $wdBackoffTicks
                    :set wdQuickAttempts 0
                    :set wdRebootCycles ($wdRebootCycles + 1)
                    :log warning ("usb-watchdog: быстрые попытки исчерпаны, вхожу в бэкофф-цикл #" . $wdRebootCycles . " на " . ($wdBackoffTicks * $tickSeconds) . " сек")
                    :local newTicks ($wdBackoffTicks * $backoffMultiplier)
                    :if ($newTicks > $backoffMaxTicks) do={ :set newTicks $backoffMaxTicks }
                    :set wdBackoffTicks $newTicks
                }
            }
        }
    }
}

# ---- сохраняем состояние на диск (если роутер не ушел в перезагрузку) ----
:local content ($wdQuickAttempts . ";" . $wdBackoffTicks . ";" . $wdWaitTicks . ";" . $wdRebootCycles)
:do {
    :local fileId [/file find where name~"usb-watchdog-state\\.txt"]
    :if ([:len $fileId] = 0) do={
        /file print file=$stateFileBase
        :delay 2s
        :set fileId [/file find where name~"usb-watchdog-state\\.txt"]
    }
    :if ([:len $fileId] > 0) do={
        /file set [:pick $fileId 0] contents=$content
    }
} on-error={
    :log warning "usb-watchdog: не удалось сохранить файл состояния на диск"
}
