#!/bin/bash
#
# wifi-switch.sh — переключение Raspberry Pi между режимами Wi-Fi:
#   ap   — Pi поднимает собственный hotspot (PiPedalus-XXXX)
#   sta  — Pi подключается клиентом к указанной домашней сети
#   status — показать текущий активный профиль
#
# Использует NetworkManager (nmcli), штатный сетевой стек Raspberry Pi OS
# начиная с Bookworm. AP-режим реализован нативно через nmcli, без
# отдельных hostapd/dnsmasq — меньше движущихся частей.
#
# Использование:
#   sudo ./wifi-switch.sh ap
#   sudo ./wifi-switch.sh sta "HomeNetworkSSID" "password123"
#   ./wifi-switch.sh status

set -e

IFACE="wlan0"
AP_CON_NAME="pipedalus-ap"
AP_IP="192.168.4.1/24"

# --- Уникальный суффикс SSID на основе MAC-адреса, чтобы не было коллизий
#     при нескольких устройствах PiPedalus в эфире.
get_mac_suffix() {
    cat /sys/class/net/${IFACE}/address 2>/dev/null \
        | tr -d ':' \
        | tail -c 5 \
        | tr '[:lower:]' '[:upper:]'
}

AP_SSID="PiPedalus-$(get_mac_suffix)"
AP_PASSWORD="pipedalus123"   # TODO: вынести в конфиг / задавать при первом запуске

usage() {
    echo "Использование:"
    echo "  sudo $0 ap                              — поднять hotspot"
    echo "  sudo $0 sta <ssid> <password>            — подключиться к Wi-Fi как клиент"
    echo "  $0 status                                — показать текущий режим"
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Эта команда требует sudo." >&2
        exit 1
    fi
}

mode_ap() {
    require_root
    echo "Переключение в AP-режим (SSID: ${AP_SSID})..."

    # dnsmasq нужен как бинарник, который NetworkManager дёргает
    # внутренне для ipv4.method=shared — сам по себе как сервис не запускаем,
    # чтобы не конфликтовал за порты с NetworkManager.
    if ! command -v dnsmasq >/dev/null 2>&1; then
        echo "dnsmasq не найден, ставлю dnsmasq-base..."
        apt-get install -y dnsmasq-base
    fi
    systemctl disable --now dnsmasq 2>/dev/null || true

    # убираем возможный старый профиль с тем же именем
    nmcli con delete "${AP_CON_NAME}" 2>/dev/null || true

    nmcli con add type wifi ifname "${IFACE}" mode ap \
        con-name "${AP_CON_NAME}" ssid "${AP_SSID}" autoconnect false

    nmcli con modify "${AP_CON_NAME}" 802-11-wireless.band bg
    # ipv4.method shared — встроенный DHCP NetworkManager для AP-клиентов.
    # ipv4.addresses обязателен и при shared: от него считается DHCP-диапазон.
    nmcli con modify "${AP_CON_NAME}" ipv4.method shared ipv4.addresses "${AP_IP}"
    nmcli con modify "${AP_CON_NAME}" ipv6.method disabled
    nmcli con modify "${AP_CON_NAME}" wifi-sec.key-mgmt wpa-psk
    nmcli con modify "${AP_CON_NAME}" wifi-sec.psk "${AP_PASSWORD}"
    # Известный баг NetworkManager/wpa_supplicant на Debian 13 (Trixie):
    # без явного отключения PMF активация падает с
    # "802.1X supplicant took too long to authenticate".
    # https://github.com/raspberrypi/linux/issues/7247
    nmcli con modify "${AP_CON_NAME}" 802-11-wireless-security.pmf 1

    # гасим возможное активное STA-подключение на этом интерфейсе
    nmcli device disconnect "${IFACE}" 2>/dev/null || true

    nmcli con up "${AP_CON_NAME}"

    echo "Hotspot поднят: ${AP_SSID} / ${AP_PASSWORD}"
    echo "Pi доступна по адресу: http://pipedalus.local:3000 (или http://192.168.4.1:3000)"
}

mode_sta() {
    require_root
    local ssid="$1"
    local password="$2"

    if [ -z "$ssid" ] || [ -z "$password" ]; then
        echo "Нужно указать SSID и пароль домашней сети." >&2
        usage
    fi

    echo "Переключение в STA-режим (подключение к: ${ssid})..."

    # деактивируем AP-профиль, если активен
    nmcli con down "${AP_CON_NAME}" 2>/dev/null || true

    # пробуем подключиться как клиент
    if nmcli device wifi connect "${ssid}" password "${password}" ifname "${IFACE}"; then
        echo "Подключено к ${ssid}."
        sleep 2
        local ip
        ip=$(nmcli -t -f IP4.ADDRESS device show "${IFACE}" | head -1 | cut -d'/' -f1 | cut -d':' -f2)
        echo "IP-адрес Pi в новой сети: ${ip:-неизвестен, проверь nmcli device show ${IFACE}}"
        echo "Доступ: http://pipedalus.local:3000 (или http://${ip}:3000)"
    else
        echo "Не удалось подключиться к ${ssid}. Возвращаюсь в AP-режим..." >&2
        mode_ap
        exit 1
    fi
}

mode_status() {
    echo "Активные подключения на ${IFACE}:"
    nmcli -t -f NAME,TYPE,DEVICE con show --active | grep "${IFACE}" || echo "  (нет активного подключения на ${IFACE})"
    echo ""
    echo "IP-адрес:"
    nmcli -t -f IP4.ADDRESS device show "${IFACE}" 2>/dev/null | head -1 || echo "  не назначен"
}

case "$1" in
    ap)
        mode_ap
        ;;
    sta)
        mode_sta "$2" "$3"
        ;;
    status)
        mode_status
        ;;
    *)
        usage
        ;;
esac
