# ============================================================
# USB LTE/3G modem watchdog (v2.1 Hardened & Decoupled)
# Hardware: MikroTik RB2011 / RouterOS v7.24+
# Architecture: RAM-first, 0 Flash Wear, Dual Ping, Decoupled Secrets
# Repository: http://10.10.30.105:3000/home-lab/mikrotik-usb-watchdog
# ============================================================

:global wdFailCount
:global wdQuickAttempts
:global wdBackoffTicks
:global wdWaitTicks
:global wdRebootCycles
:global wdStateLoaded
:global wdLastSavedState
:global synoChatWebhook

# ---------------- Настройки ----------------
:local pingHost1 "77.88.8.8"
:local pingHost2 "1.1.1.1"
:local failThreshold 4
:local usbResetDuration "10s"
:local maxQuickAttempts 2
:local quickRetryTicks 4
:local backoffInitialTicks 240
:local backoffMaxTicks 720
:local backoffMultiplier 3
:local maxRebootCycles 2
:local tickSeconds 30
:local stateFileName "usb-watchdog-state.txt"
# -------------------------------------------

# Инициализация переменных в RAM по умолчанию
:if ([:typeof $wdFailCount] = "nothing") do={ :set wdFailCount 0 }
:if ([:typeof $wdQuickAttempts] = "nothing") do={ :set wdQuickAttempts 0 }
:if ([:typeof $wdBackoffTicks] = "nothing") do={ :set wdBackoffTicks $backoffInitialTicks }
:if ([:typeof $wdWaitTicks] = "nothing") do={ :set wdWaitTicks 0 }
:if ([:typeof $wdRebootCycles] = "nothing") do={ :set wdRebootCycles 0 }
:if ([:typeof $wdLastSavedState] = "nothing") do={ :set wdLastSavedState "" }

# Чтение с диска ТОЛЬКО при первой загрузке (холодный старт / перезагрузка роутера)
:if ([:typeof $wdStateLoaded] = "nothing" or $wdStateLoaded != true) do={
    :do {
        :local fileId [/file find where name=$stateFileName]
        :if ([:len $fileId] > 0) do={
            :local raw [/file get [:pick $fileId 0] contents]
            :set wdLastSavedState $raw
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
                        :log info ("usb-watchdog: состояние успешно загружено из файла: " . $raw)
                    }
                }
            }
        }
    } on-error={
        :log warning "usb-watchdog: файл состояния пуст или не найден, старт с дефолтами"
    }
    :set wdStateLoaded true
}

# Функция записи на Flash: вызывается ИСКЛЮЧИТЕЛЬНО при смене макро-состояния
:local saveMacroState do={
    :global wdLastSavedState
    :local content ($1)
    :local fileName ($2)
    :if ($content != $wdLastSavedState) do={
        :do {
            :local fileId [/file find where name=$fileName]
            :if ([:len $fileId] = 0) do={
                /file print file=[:pick $fileName 0 [:find $fileName "."]]
                :delay 2s
                :set fileId [/file find where name=$fileName]
            }
            :if ([:len $fileId] > 0) do={
                /file set [:pick $fileId 0] contents=$content
                :set wdLastSavedState $content
                :log info ("usb-watchdog: макро-состояние зафиксировано на Flash: " . $content)
            }
        } on-error={
            :log warning "usb-watchdog: сбой записи состояния на Flash"
        }
    }
}

# 1. Отказоустойчивый опрос контрольных узлов (Dual Ping)
:local isUp false
:do {
    :if ([/ping $pingHost1 count=2] > 0) do={
        :set isUp true
    } else={
        :if ([/ping $pingHost2 count=2] > 0) do={
            :set isUp true
        }
    }
} on-error={ :set isUp false }

# 2. Обработка статуса связи
:if ($isUp = true) do={
    :if ($wdFailCount >= $failThreshold) do={
        :log info "usb-watchdog: связь успешно восстановлена"
        :if ($wdQuickAttempts > 0 or $wdRebootCycles > 0) do={
            # Подтягиваем актуальный секрет непосредственно перед отправкой
            :do {
                /system script run usb-watchdog-secrets
            } on-error={
                :log warning "usb-watchdog: не удалось выполнить usb-watchdog-secrets"
            }
            :local webhookUrl $synoChatWebhook
            :if ([:typeof $webhookUrl] = "str" and $webhookUrl != "" and !($webhookUrl ~ "YOUR-NAS-ADDRESS")) do={
                :do {
                    /tool fetch url=$webhookUrl http-method=post \
                        http-header-field="Content-Type: application/x-www-form-urlencoded" \
                        http-data="payload={\"text\":\"USB watchdog: интернет восстановлен после сброса модема\"}" \
                        output=none
                    :log info "usb-watchdog: уведомление в Synology Chat отправлено"
                } on-error={
                    :log warning "usb-watchdog: не удалось отправить вебхук"
                }
            } else={
                :log warning "usb-watchdog: webhookUrl не задан или содержит шаблонное значение"
            }
        }
    }
    :set wdFailCount 0
    :set wdQuickAttempts 0
    :set wdBackoffTicks $backoffInitialTicks
    :set wdWaitTicks 0
    :set wdRebootCycles 0
    # Синхронизируем штатное состояние на Flash только если до этого была авария
    [$saveMacroState ("0;" . $backoffInitialTicks . ";0;0") $stateFileName]
} else={
    :set wdFailCount ($wdFailCount + 1)
    :log info ("usb-watchdog: пинг не прошел, failCount=" . $wdFailCount)

    :if ($wdFailCount >= $failThreshold) do={
        # В режиме ожидания счетчик крутится ТОЛЬКО в RAM, не трогая Flash!
        :if ($wdWaitTicks > 0) do={
            :set wdWaitTicks ($wdWaitTicks - 1)
            :log info ("usb-watchdog: пауза (бэкофф/инициализация), осталось тиков=" . $wdWaitTicks)
        } else={
            :if ($wdQuickAttempts < $maxQuickAttempts) do={
                :log warning ("usb-watchdog: USB power-reset, попытка #" . ($wdQuickAttempts + 1))
                :do {
                    /system routerboard usb power-reset duration=$usbResetDuration
                } on-error={
                    :log warning "usb-watchdog: power-reset занят/не удался, повтор на следующем тике"
                }
                :set wdQuickAttempts ($wdQuickAttempts + 1)
                :set wdWaitTicks $quickRetryTicks
            } else={
                :if ($wdRebootCycles >= $maxRebootCycles) do={
                    :log error "usb-watchdog: бэкофф-циклы исчерпаны, аппаратный ребут роутера!"
                    [$saveMacroState ("0;" . $backoffInitialTicks . ";0;" . ($wdRebootCycles + 1)) $stateFileName]
                    /system reboot
                } else={
                    :set wdWaitTicks $wdBackoffTicks
                    :set wdQuickAttempts 0
                    :set wdRebootCycles ($wdRebootCycles + 1)
                    :log warning ("usb-watchdog: быстрые попытки исчерпаны, вход в бэкофф-цикл #" . $wdRebootCycles . " на " . ($wdBackoffTicks * $tickSeconds) . " сек")
                    [$saveMacroState ($wdQuickAttempts . ";" . $wdBackoffTicks . ";" . $wdWaitTicks . ";" . $wdRebootCycles) $stateFileName]
                    :local newTicks ($wdBackoffTicks * $backoffMultiplier)
                    :if ($newTicks > $backoffMaxTicks) do={ :set newTicks $backoffMaxTicks }
                    :set wdBackoffTicks $newTicks
                }
            }
        }
    }
}
