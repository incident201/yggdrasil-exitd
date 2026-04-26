#!/usr/bin/env bash
set -Eeuo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SERVICE_NAME="ygg-exitd"
BIN_PATH="/usr/local/bin/ygg-exitd"
RUNNER_PATH="/usr/local/sbin/ygg-exitd-run"
HELPER_APPLY_NFT="/usr/local/sbin/ygg-exitd-nft-apply"
HELPER_REMOVE_NFT="/usr/local/sbin/ygg-exitd-nft-remove"
HELPER_APPLY_ROUTING="/usr/local/sbin/ygg-exitd-routing-apply"
HELPER_REMOVE_ROUTING="/usr/local/sbin/ygg-exitd-routing-remove"
HELPER_DOCKER_FW="/usr/local/sbin/ygg-exitd-docker-fw"
CONFIG_DIR="/etc/ygg-exitd"
ENV_FILE="/etc/ygg-exitd/ygg-exitd.env"
STATE_FILE="/etc/ygg-exitd/install.state"
WHITELIST_FILE="/etc/ygg-exitd.conf"
SYSTEMD_UNIT="/etc/systemd/system/ygg-exitd.service"
DOCKER_FW_UNIT="/etc/systemd/system/ygg-exitd-docker-fw.service"
SYSCTL_FILE="/etc/sysctl.d/99-ygg-exitd.conf"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
    [[ "${EUID}" -eq 0 ]] || die "Запусти от root: sudo ./uninstall.sh"
}

yesno() {
    local prompt="$1"
    local default="${2:-y}"
    local answer suffix

    if [[ "$default" == "y" ]]; then
        suffix="Y/n"
    else
        suffix="y/N"
    fi

    while true; do
        read -r -p "$prompt [$suffix]: " answer
        answer="${answer:-$default}"
        case "$answer" in
            y|Y|yes|YES|д|Д|да|ДА) return 0 ;;
            n|N|no|NO|н|Н|нет|НЕТ) return 1 ;;
            *) echo "Ответь y или n." ;;
        esac
    done
}

read_env_value() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || return 0
    grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2-
}

remove_nft_table() {
    if command -v nft >/dev/null 2>&1; then
        if nft list table inet ygg_exitd >/dev/null 2>&1; then
            nft delete table inet ygg_exitd
            log "Удалена nftables table inet ygg_exitd."
        fi
    fi
}

remove_policy_routing() {
    local tun_net policy_table policy_priority

    tun_net="$(read_env_value TUN_NET "$ENV_FILE")"
    policy_table="$(read_env_value POLICY_TABLE "$ENV_FILE")"
    policy_priority="$(read_env_value POLICY_PRIORITY "$ENV_FILE")"

    [[ -n "$tun_net" ]] || tun_net="10.66.0.0/24"
    [[ -n "$policy_table" ]] || policy_table="42066"
    [[ -n "$policy_priority" ]] || policy_priority="10066"

    if command -v ip >/dev/null 2>&1; then
        while ip rule show | grep -q "from ${tun_net} lookup ${policy_table}"; do
            ip rule del from "$tun_net" table "$policy_table" priority "$policy_priority" 2>/dev/null || \
            ip rule del from "$tun_net" table "$policy_table" 2>/dev/null || \
            break
        done
        ip route flush table "$policy_table" 2>/dev/null || true
        log "Policy routing ygg-exitd удалён, если был активен."
    fi
}

remove_docker_forwarding_rules() {
    local tun_name out_iface tun_net

    if [[ -x "$HELPER_DOCKER_FW" ]]; then
        "$HELPER_DOCKER_FW" remove >/dev/null 2>&1 || true
    fi

    command -v iptables >/dev/null 2>&1 || return 0
    iptables -S DOCKER-USER >/dev/null 2>&1 || return 0

    tun_name="$(read_env_value TUN_NAME "$ENV_FILE")"
    out_iface="$(read_env_value OUT_IFACE "$ENV_FILE")"
    tun_net="$(read_env_value TUN_NET "$ENV_FILE")"

    [[ -n "$tun_name" ]] || tun_name="yggexit0"
    [[ -n "$out_iface" ]] || out_iface="none"
    [[ -n "$tun_net" ]] || tun_net="10.66.0.0/24"
    [[ "$out_iface" != "none" ]] || return 0

    while iptables -C DOCKER-USER \
        -i "$tun_name" -o "$out_iface" \
        -s "$tun_net" \
        -j ACCEPT 2>/dev/null; do
        iptables -D DOCKER-USER \
            -i "$tun_name" -o "$out_iface" \
            -s "$tun_net" \
            -j ACCEPT 2>/dev/null || break
    done

    while iptables -C DOCKER-USER \
        -i "$out_iface" -o "$tun_name" \
        -d "$tun_net" \
        -m conntrack --ctstate RELATED,ESTABLISHED \
        -j ACCEPT 2>/dev/null; do
        iptables -D DOCKER-USER \
            -i "$out_iface" -o "$tun_name" \
            -d "$tun_net" \
            -m conntrack --ctstate RELATED,ESTABLISHED \
            -j ACCEPT 2>/dev/null || break
    done

    log "Правила ygg-exitd из DOCKER-USER удалены, если были активны."
}

remove_leftover_tun() {
    local tun_name
    tun_name="$(read_env_value TUN_NAME "$ENV_FILE")"
    [[ -n "$tun_name" ]] || tun_name="yggexit0"

    if command -v ip >/dev/null 2>&1 && ip link show "$tun_name" >/dev/null 2>&1; then
        ip link delete "$tun_name" 2>/dev/null || true
        log "Удалён оставшийся интерфейс $tun_name, если он был создан."
    fi
}

restore_ip_forward_if_safe() {
    local prev current

    [[ -f "$STATE_FILE" ]] || return 0
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    prev="${PREV_IPV4_FORWARD:-unknown}"
    current="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"

    if [[ "$prev" == "0" && "$current" == "1" ]]; then
        warn "До установки ygg-exitd net.ipv4.ip_forward был 0, сейчас он 1."
        warn "Если на сервере есть другие VPN/роутинг-сервисы, отключать forwarding может быть нельзя."
        if yesno "Вернуть net.ipv4.ip_forward=0 сейчас?" "n"; then
            sysctl -w net.ipv4.ip_forward=0 >/dev/null || warn "Не удалось вернуть net.ipv4.ip_forward=0."
            log "net.ipv4.ip_forward возвращён в 0."
        fi
    fi
}

main() {
    need_root

    warn "Это удалит ygg-exitd, systemd units, helper scripts, nftables table inet ygg_exitd и /etc/ygg-exitd."
    warn "Также будут удалены только правила ygg-exitd из DOCKER-USER, если install.sh их добавлял. Остальные правила Docker не трогаются."
    warn "Yggdrasil не будет удалён и его конфиг не будет изменён."
    yesno "Продолжить удаление?" "n" || die "Отменено."

    systemctl disable --now ygg-exitd-docker-fw.service >/dev/null 2>&1 || true
    remove_docker_forwarding_rules

    systemctl disable --now "$SERVICE_NAME.service" >/dev/null 2>&1 || true
    log "Сервис остановлен и отключён, если существовал."

    remove_nft_table
    remove_policy_routing
    remove_leftover_tun

    rm -f "$SYSTEMD_UNIT" "$DOCKER_FW_UNIT"
    rm -f "$RUNNER_PATH"
    rm -f "$HELPER_APPLY_NFT" "$HELPER_REMOVE_NFT"
    rm -f "$HELPER_APPLY_ROUTING" "$HELPER_REMOVE_ROUTING"
    rm -f "$HELPER_DOCKER_FW"
    rm -f "$SYSCTL_FILE"
    rm -f "$BIN_PATH"

    restore_ip_forward_if_safe

    rm -rf "$CONFIG_DIR"

    if [[ -f "$WHITELIST_FILE" ]]; then
        if yesno "Удалить whitelist $WHITELIST_FILE?" "y"; then
            rm -f "$WHITELIST_FILE"
        else
            log "Whitelist оставлен: $WHITELIST_FILE"
        fi
    fi

    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed "$SERVICE_NAME.service" 2>/dev/null || true
    systemctl reset-failed ygg-exitd-docker-fw.service 2>/dev/null || true

    log "Удаление завершено."
}

main "$@"
