#!/usr/bin/env bash
set -Eeuo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

REPO_URL="https://github.com/incident201/yggdrasil-exitd.git"
REPO_TARBALL="https://github.com/incident201/yggdrasil-exitd/archive/refs/heads/main.tar.gz"

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
NFT_FILE="/etc/ygg-exitd/nftables.nft"
STATE_FILE="/etc/ygg-exitd/install.state"
WHITELIST_FILE="/etc/ygg-exitd.conf"
SYSTEMD_UNIT="/etc/systemd/system/ygg-exitd.service"
DOCKER_FW_UNIT="/etc/systemd/system/ygg-exitd-docker-fw.service"
SYSCTL_FILE="/etc/sysctl.d/99-ygg-exitd.conf"

LISTEN_PORT_DEFAULT="40001"
TUN_NAME_DEFAULT="yggexit0"
TUN_CIDR_DEFAULT="10.66.0.1/24"
TUN_NET_DEFAULT="10.66.0.0/24"
TUN_MTU_DEFAULT="1280"
POLICY_TABLE_DEFAULT="42066"
POLICY_PRIORITY_DEFAULT="10066"

DOCKER_FW_CONFIGURED="0"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
    [[ "${EUID}" -eq 0 ]] || die "Запусти от root: sudo ./install.sh"
}

cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_cmd() {
    cmd_exists "$1" || die "Не найдена команда '$1'. Установи её и повтори запуск."
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

ask() {
    local prompt="$1"
    local default="${2:-}"
    local answer

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " answer
        printf '%s' "${answer:-$default}"
    else
        read -r -p "$prompt: " answer
        printf '%s' "$answer"
    fi
}

validate_iface_name() {
    local iface="$1"
    [[ "$iface" =~ ^[a-zA-Z0-9_.:-]+$ ]]
}

iface_exists() {
    ip link show "$1" >/dev/null 2>&1
}

first_default_iface() {
    ip -4 route show default 2>/dev/null \
        | awk '{ for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }' \
        | head -n1
}

list_ifaces() {
    ip -o link show 2>/dev/null \
        | awk -F': ' '{print $2}' \
        | cut -d'@' -f1 \
        | grep -v '^lo$' \
        | sed 's/^/  - /'
}

is_ygg_ipv6() {
    local ip="$1"
    local first
    first="${ip%%:*}"
    first="${first,,}"

    [[ "$first" =~ ^[0-9a-f]{3}$ ]] || return 1
    (( 16#$first >= 16#200 && 16#$first <= 16#3ff ))
}

detect_ygg_ipv6_and_iface() {
    local line ifname addr ip best_if best_ip fallback_if fallback_ip

    while read -r line; do
        [[ -n "$line" ]] || continue
        ifname="$(awk '{print $2}' <<< "$line" | cut -d'@' -f1)"
        addr="$(awk '{print $4}' <<< "$line")"
        ip="${addr%/*}"

        if is_ygg_ipv6 "$ip"; then
            if [[ -z "${fallback_ip:-}" ]]; then
                fallback_if="$ifname"
                fallback_ip="$ip"
            fi
            if [[ "$ifname" =~ [Yy][Gg][Gg] ]]; then
                best_if="$ifname"
                best_ip="$ip"
                break
            fi
        fi
    done < <(ip -o -6 addr show scope global 2>/dev/null || true)

    if [[ -n "${best_ip:-}" ]]; then
        printf '%s %s\n' "$best_if" "$best_ip"
    elif [[ -n "${fallback_ip:-}" ]]; then
        printf '%s %s\n' "$fallback_if" "$fallback_ip"
    else
        return 1
    fi
}

show_detected_ygg_candidates() {
    local line ifname addr ip found=0
    while read -r line; do
        [[ -n "$line" ]] || continue
        ifname="$(awk '{print $2}' <<< "$line" | cut -d'@' -f1)"
        addr="$(awk '{print $4}' <<< "$line")"
        ip="${addr%/*}"
        if is_ygg_ipv6 "$ip"; then
            found=1
            printf '  - %s  %s\n' "$ifname" "$ip"
        fi
    done < <(ip -o -6 addr show scope global 2>/dev/null || true)

    (( found == 1 )) || true
}

check_yggdrasil() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^yggdrasil\.service'; then
        if systemctl is-active --quiet yggdrasil.service; then
            log "yggdrasil.service активен."
        else
            warn "yggdrasil.service найден, но сейчас не активен. Адрес Yggdrasil может не определиться."
        fi
    else
        warn "Не нашёл systemd unit yggdrasil.service. Это не ошибка: в разных дистрибутивах unit может называться иначе."
    fi
}

check_existing_install() {
    local found=0
    for p in \
        "$BIN_PATH" "$RUNNER_PATH" "$ENV_FILE" "$NFT_FILE" "$SYSTEMD_UNIT" \
        "$HELPER_APPLY_NFT" "$HELPER_REMOVE_NFT" \
        "$HELPER_APPLY_ROUTING" "$HELPER_REMOVE_ROUTING" \
        "$HELPER_DOCKER_FW" "$DOCKER_FW_UNIT" "$SYSCTL_FILE"; do
        [[ -e "$p" ]] && found=1
    done

    if (( found == 1 )); then
        warn "Похоже, ygg-exitd уже устанавливался на эту систему."
        yesno "Перезаписать файлы установки?" "n" || die "Отменено."
        systemctl disable --now "$SERVICE_NAME.service" >/dev/null 2>&1 || true
        systemctl disable --now ygg-exitd-docker-fw.service >/dev/null 2>&1 || true
        "$HELPER_DOCKER_FW" remove >/dev/null 2>&1 || true
    fi
}

install_binary() {
    local script_dir src_dir tmp build_out

    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P || true)"
    tmp=""

    require_cmd go

    if [[ -n "$script_dir" && -f "$script_dir/go.mod" && -f "$script_dir/main.go" ]]; then
        src_dir="$script_dir"
        log "Собираю ygg-exitd из текущего каталога: $src_dir"
    else
        require_cmd tar
        tmp="$(mktemp -d)"

        if cmd_exists git; then
            log "Клонирую репозиторий: $REPO_URL"
            git clone --depth 1 "$REPO_URL" "$tmp/src" >/dev/null
            src_dir="$tmp/src"
        elif cmd_exists curl; then
            log "Скачиваю архив репозитория."
            curl -fsSL "$REPO_TARBALL" | tar -xz -C "$tmp"
            src_dir="$tmp/yggdrasil-exitd-main"
        elif cmd_exists wget; then
            log "Скачиваю архив репозитория."
            wget -qO- "$REPO_TARBALL" | tar -xz -C "$tmp"
            src_dir="$tmp/yggdrasil-exitd-main"
        else
            die "Нужен git, curl или wget, чтобы скачать исходники."
        fi
    fi

    build_out="$(mktemp)"
    rm -f "$build_out"

    (cd "$src_dir" && go build -trimpath -ldflags='-s -w' -o "$build_out" .)
    install -m 0755 "$build_out" "$BIN_PATH"
    rm -f "$build_out"

    [[ -z "$tmp" ]] || rm -rf "$tmp"
    log "Бинарник установлен: $BIN_PATH"
}

write_whitelist_if_missing() {
    if [[ -f "$WHITELIST_FILE" ]]; then
        log "Whitelist уже существует, не перезаписываю: $WHITELIST_FILE"
        return 0
    fi

    cat > "$WHITELIST_FILE" <<'EOF_WHITELIST'
# ygg-exitd whitelist
#
# По умолчанию список пустой, поэтому ни один клиент не будет принят.
# Формат: <client-yggdrasil-ipv6> <client-inner-ipv4>
#
# Пример:
# 200:1111:2222:3333:4444:5555:6666:7777 10.66.0.10
EOF_WHITELIST
    chmod 0644 "$WHITELIST_FILE"
    log "Создан пустой whitelist: $WHITELIST_FILE"
}

write_state_file() {
    mkdir -p "$CONFIG_DIR"
    cat > "$STATE_FILE" <<EOF_STATE
PREV_IPV4_FORWARD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
INSTALL_TIME_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF_STATE
    chmod 0644 "$STATE_FILE"
}

write_env_file() {
    local ygg_iface="$1"
    local out_iface="$2"
    local enable_nat="$3"

    mkdir -p "$CONFIG_DIR"

    cat > "$ENV_FILE" <<EOF_ENV
# ygg-exitd generated config
# Edit only if you understand what you are changing.

YGG_IFACE=$ygg_iface
LISTEN_PORT=$LISTEN_PORT_DEFAULT

TUN_NAME=$TUN_NAME_DEFAULT
TUN_CIDR=$TUN_CIDR_DEFAULT
TUN_NET=$TUN_NET_DEFAULT
TUN_MTU=$TUN_MTU_DEFAULT

ENABLE_NAT=$enable_nat
OUT_IFACE=$out_iface

POLICY_TABLE=$POLICY_TABLE_DEFAULT
POLICY_PRIORITY=$POLICY_PRIORITY_DEFAULT
EOF_ENV

    chmod 0644 "$ENV_FILE"
    log "Конфиг создан: $ENV_FILE"
}

write_runner() {
    cat > "$RUNNER_PATH" <<'EOF_RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ENV_FILE="/etc/ygg-exitd/ygg-exitd.env"
BIN_PATH="/usr/local/bin/ygg-exitd"

[[ -f "$ENV_FILE" ]] || { echo "Config not found: $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

is_ygg_ipv6() {
    local ip="$1"
    local first
    first="${ip%%:*}"
    first="${first,,}"
    [[ "$first" =~ ^[0-9a-f]{3}$ ]] || return 1
    (( 16#$first >= 16#200 && 16#$first <= 16#3ff ))
}

detect_ygg_ipv6() {
    local line ifname addr ip fallback_ip

    if [[ -n "${YGG_IFACE:-}" ]] && ip link show "$YGG_IFACE" >/dev/null 2>&1; then
        while read -r line; do
            [[ -n "$line" ]] || continue
            addr="$(awk '{print $4}' <<< "$line")"
            ip="${addr%/*}"
            if is_ygg_ipv6 "$ip"; then
                printf '%s\n' "$ip"
                return 0
            fi
        done < <(ip -o -6 addr show dev "$YGG_IFACE" scope global 2>/dev/null || true)
    fi

    while read -r line; do
        [[ -n "$line" ]] || continue
        ifname="$(awk '{print $2}' <<< "$line" | cut -d'@' -f1)"
        addr="$(awk '{print $4}' <<< "$line")"
        ip="${addr%/*}"
        if is_ygg_ipv6 "$ip"; then
            if [[ "$ifname" =~ [Yy][Gg][Gg] ]]; then
                printf '%s\n' "$ip"
                return 0
            fi
            [[ -n "${fallback_ip:-}" ]] || fallback_ip="$ip"
        fi
    done < <(ip -o -6 addr show scope global 2>/dev/null || true)

    [[ -n "${fallback_ip:-}" ]] || return 1
    printf '%s\n' "$fallback_ip"
}

YGG_IPV6="$(detect_ygg_ipv6)" || {
    echo "Cannot detect Yggdrasil IPv6 address from local interfaces." >&2
    echo "Yggdrasil must be running and must have an address from 0200::/7." >&2
    exit 1
}

exec "$BIN_PATH" \
    --listen "[$YGG_IPV6]:${LISTEN_PORT:-40001}" \
    --tun-name "${TUN_NAME:-yggexit0}" \
    --tun-cidr "${TUN_CIDR:-10.66.0.1/24}" \
    --tun-mtu "${TUN_MTU:-1280}"
EOF_RUNNER

    chmod 0755 "$RUNNER_PATH"
    log "Runner создан: $RUNNER_PATH"
}

write_routing_helpers() {
    cat > "$HELPER_APPLY_ROUTING" <<'EOF_APPLY_ROUTING'
#!/usr/bin/env bash
set -Eeuo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV_FILE="/etc/ygg-exitd/ygg-exitd.env"
[[ -f "$ENV_FILE" ]] || exit 0
# shellcheck disable=SC1090
. "$ENV_FILE"

[[ "${ENABLE_NAT:-0}" == "1" ]] || exit 0
[[ -n "${OUT_IFACE:-}" ]] || exit 0
[[ "$OUT_IFACE" != "none" ]] || exit 0

ip link show "$OUT_IFACE" >/dev/null 2>&1 || {
    echo "OUT_IFACE does not exist: $OUT_IFACE" >&2
    exit 1
}

sysctl -w net.ipv4.ip_forward=1 >/dev/null

ip route flush table "${POLICY_TABLE:-42066}" 2>/dev/null || true

DEFAULT_LINE="$(ip -4 route show default dev "$OUT_IFACE" 2>/dev/null | head -n1 || true)"
GATEWAY=""
if [[ -n "$DEFAULT_LINE" ]]; then
    GATEWAY="$(awk '{ for (i=1;i<=NF;i++) if ($i=="via") { print $(i+1); exit } }' <<< "$DEFAULT_LINE")"
fi

if [[ -n "$GATEWAY" ]]; then
    ip route replace default via "$GATEWAY" dev "$OUT_IFACE" table "${POLICY_TABLE:-42066}"
else
    ip route replace default dev "$OUT_IFACE" table "${POLICY_TABLE:-42066}"
fi

if ! ip rule show | grep -q "from ${TUN_NET:-10.66.0.0/24} lookup ${POLICY_TABLE:-42066}"; then
    ip rule add from "${TUN_NET:-10.66.0.0/24}" table "${POLICY_TABLE:-42066}" priority "${POLICY_PRIORITY:-10066}"
fi
EOF_APPLY_ROUTING

    cat > "$HELPER_REMOVE_ROUTING" <<'EOF_REMOVE_ROUTING'
#!/usr/bin/env bash
set -Eeuo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV_FILE="/etc/ygg-exitd/ygg-exitd.env"
[[ -f "$ENV_FILE" ]] || exit 0
# shellcheck disable=SC1090
. "$ENV_FILE"

while ip rule show | grep -q "from ${TUN_NET:-10.66.0.0/24} lookup ${POLICY_TABLE:-42066}"; do
    ip rule del from "${TUN_NET:-10.66.0.0/24}" table "${POLICY_TABLE:-42066}" priority "${POLICY_PRIORITY:-10066}" 2>/dev/null || \
    ip rule del from "${TUN_NET:-10.66.0.0/24}" table "${POLICY_TABLE:-42066}" 2>/dev/null || \
    break
done
ip route flush table "${POLICY_TABLE:-42066}" 2>/dev/null || true
EOF_REMOVE_ROUTING

    chmod 0755 "$HELPER_APPLY_ROUTING" "$HELPER_REMOVE_ROUTING"
    log "Routing helpers созданы."
}

write_nft_helpers() {
    cat > "$HELPER_APPLY_NFT" <<'EOF_APPLY_NFT'
#!/usr/bin/env bash
set -Eeuo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV_FILE="/etc/ygg-exitd/ygg-exitd.env"
NFT_FILE="/etc/ygg-exitd/nftables.nft"
[[ -f "$ENV_FILE" ]] || exit 0
# shellcheck disable=SC1090
. "$ENV_FILE"

if [[ "${ENABLE_NAT:-0}" != "1" || -z "${OUT_IFACE:-}" || "$OUT_IFACE" == "none" ]]; then
    nft list table inet ygg_exitd >/dev/null 2>&1 && nft delete table inet ygg_exitd || true
    exit 0
fi

ip link show "$OUT_IFACE" >/dev/null 2>&1 || {
    echo "OUT_IFACE does not exist: $OUT_IFACE" >&2
    exit 1
}

mkdir -p /etc/ygg-exitd
cat > "$NFT_FILE" <<EOF_NFT
# Generated by ygg-exitd installer.
# This file owns only table inet ygg_exitd.
# It does not flush or modify any other nftables tables.

table inet ygg_exitd {
    chain forward {
        type filter hook forward priority 0; policy accept;

        iifname "${TUN_NAME:-yggexit0}" oifname "$OUT_IFACE" ip saddr ${TUN_NET:-10.66.0.0/24} accept
        iifname "$OUT_IFACE" oifname "${TUN_NAME:-yggexit0}" ip daddr ${TUN_NET:-10.66.0.0/24} ct state established,related accept
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        oifname "$OUT_IFACE" ip saddr ${TUN_NET:-10.66.0.0/24} masquerade
    }
}
EOF_NFT

nft list table inet ygg_exitd >/dev/null 2>&1 && nft delete table inet ygg_exitd || true
nft -f "$NFT_FILE"
EOF_APPLY_NFT

    cat > "$HELPER_REMOVE_NFT" <<'EOF_REMOVE_NFT'
#!/usr/bin/env bash
set -Eeuo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
if command -v nft >/dev/null 2>&1; then
    nft list table inet ygg_exitd >/dev/null 2>&1 && nft delete table inet ygg_exitd || true
fi
EOF_REMOVE_NFT

    chmod 0755 "$HELPER_APPLY_NFT" "$HELPER_REMOVE_NFT"
    log "nftables helpers созданы."
}

write_docker_fw_helper() {
    cat > "$HELPER_DOCKER_FW" <<'EOF_DOCKER_FW'
#!/usr/bin/env bash
set -Eeuo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ENV_FILE="/etc/ygg-exitd/ygg-exitd.env"
[[ -f "$ENV_FILE" ]] || exit 0
# shellcheck disable=SC1090
. "$ENV_FILE"

TUN_IFACE="${TUN_NAME:-yggexit0}"
OUT_IFACE="${OUT_IFACE:-none}"
TUN_NET="${TUN_NET:-10.66.0.0/24}"

[[ "${ENABLE_NAT:-0}" == "1" ]] || exit 0
[[ -n "$OUT_IFACE" && "$OUT_IFACE" != "none" ]] || exit 0
command -v iptables >/dev/null 2>&1 || exit 0

ensure_docker_user_chain() {
    iptables -N DOCKER-USER 2>/dev/null || true
    iptables -S DOCKER-USER >/dev/null 2>&1 || return 1
}

apply_rules() {
    ensure_docker_user_chain || exit 0

    iptables -C DOCKER-USER \
        -i "$TUN_IFACE" -o "$OUT_IFACE" \
        -s "$TUN_NET" \
        -j ACCEPT 2>/dev/null || \
    iptables -I DOCKER-USER 1 \
        -i "$TUN_IFACE" -o "$OUT_IFACE" \
        -s "$TUN_NET" \
        -j ACCEPT

    iptables -C DOCKER-USER \
        -i "$OUT_IFACE" -o "$TUN_IFACE" \
        -d "$TUN_NET" \
        -m conntrack --ctstate RELATED,ESTABLISHED \
        -j ACCEPT 2>/dev/null || \
    iptables -I DOCKER-USER 2 \
        -i "$OUT_IFACE" -o "$TUN_IFACE" \
        -d "$TUN_NET" \
        -m conntrack --ctstate RELATED,ESTABLISHED \
        -j ACCEPT
}

remove_rules() {
    iptables -S DOCKER-USER >/dev/null 2>&1 || exit 0

    while iptables -C DOCKER-USER \
        -i "$TUN_IFACE" -o "$OUT_IFACE" \
        -s "$TUN_NET" \
        -j ACCEPT 2>/dev/null; do
        iptables -D DOCKER-USER \
            -i "$TUN_IFACE" -o "$OUT_IFACE" \
            -s "$TUN_NET" \
            -j ACCEPT
    done

    while iptables -C DOCKER-USER \
        -i "$OUT_IFACE" -o "$TUN_IFACE" \
        -d "$TUN_NET" \
        -m conntrack --ctstate RELATED,ESTABLISHED \
        -j ACCEPT 2>/dev/null; do
        iptables -D DOCKER-USER \
            -i "$OUT_IFACE" -o "$TUN_IFACE" \
            -d "$TUN_NET" \
            -m conntrack --ctstate RELATED,ESTABLISHED \
            -j ACCEPT
    done
}

case "${1:-apply}" in
    apply) apply_rules ;;
    remove) remove_rules ;;
    *) echo "Usage: $0 {apply|remove}" >&2; exit 1 ;;
esac
EOF_DOCKER_FW

    chmod 0755 "$HELPER_DOCKER_FW"
    log "Docker firewall helper создан: $HELPER_DOCKER_FW"
}

docker_firewall_needed() {
    local enable_nat="$1"

    [[ "$enable_nat" == "1" ]] || return 1
    cmd_exists iptables || return 1

    if systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
        return 0
    fi

    if iptables -S DOCKER-USER >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

write_docker_fw_systemd_unit() {
    cat > "$DOCKER_FW_UNIT" <<EOF_UNIT
[Unit]
Description=ygg-exitd Docker forwarding compatibility rules
Documentation=https://github.com/incident201/yggdrasil-exitd
After=docker.service network-online.target ygg-exitd.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$HELPER_DOCKER_FW apply
ExecStop=$HELPER_DOCKER_FW remove

[Install]
WantedBy=multi-user.target
EOF_UNIT

    chmod 0644 "$DOCKER_FW_UNIT"
    systemctl daemon-reload
    log "systemd unit для Docker firewall создан: $DOCKER_FW_UNIT"
}

setup_docker_firewall_if_needed() {
    local enable_nat="$1"

    DOCKER_FW_CONFIGURED="0"

    if ! docker_firewall_needed "$enable_nat"; then
        rm -f "$DOCKER_FW_UNIT" "$HELPER_DOCKER_FW"
        return 0
    fi

    write_docker_fw_helper
    write_docker_fw_systemd_unit

    systemctl enable --now ygg-exitd-docker-fw.service >/dev/null
    DOCKER_FW_CONFIGURED="1"
    log "Добавлены совместимые правила в DOCKER-USER для ygg-exitd."
}

write_sysctl_file() {
    local enable_nat="$1"

    if [[ "$enable_nat" != "1" ]]; then
        rm -f "$SYSCTL_FILE"
        return 0
    fi

    cat > "$SYSCTL_FILE" <<'EOF_SYSCTL'
# Generated by ygg-exitd installer.
# Required for forwarding client traffic from ygg-exitd TUN to selected OUT_IFACE.
net.ipv4.ip_forward = 1
EOF_SYSCTL
    chmod 0644 "$SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null
    log "IPv4 forwarding включён через $SYSCTL_FILE"
}

write_systemd_unit() {
    cat > "$SYSTEMD_UNIT" <<EOF_UNIT
[Unit]
Description=ygg-exitd UDP-over-Yggdrasil TUN exit daemon
Documentation=https://github.com/incident201/yggdrasil-exitd
After=network-online.target yggdrasil.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStartPre=$HELPER_APPLY_ROUTING
ExecStartPre=$HELPER_APPLY_NFT
ExecStart=$RUNNER_PATH
ExecStopPost=$HELPER_REMOVE_NFT
ExecStopPost=$HELPER_REMOVE_ROUTING
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_UNIT

    chmod 0644 "$SYSTEMD_UNIT"
    systemctl daemon-reload
    log "systemd unit создан: $SYSTEMD_UNIT"
}

choose_out_iface() {
    local default_iface out_iface
    default_iface="$(first_default_iface || true)"

    echo
    echo "Доступные интерфейсы:"
    list_ifaces || true
    echo
    echo "Укажи интерфейс, куда выпускать трафик клиентов ygg-exitd."
    echo "Обычно это внешний интерфейс сервера: eth0/ens3/enp1s0."
    echo "Если хочешь гнать трафик через другой VPN, укажи его: wg0/awg0/tun0."
    echo "Если NAT/forwarding сейчас не нужен, введи: none"
    echo

    while true; do
        out_iface="$(ask "OUT_IFACE" "${default_iface:-none}")"
        out_iface="${out_iface//[[:space:]]/}"

        if [[ "$out_iface" == "none" ]]; then
            CHOSEN_OUT_IFACE="$out_iface"
            return 0
        fi

        validate_iface_name "$out_iface" || {
            warn "Некорректное имя интерфейса: $out_iface"
            continue
        }

        iface_exists "$out_iface" || {
            warn "Интерфейс не найден: $out_iface"
            continue
        }

        CHOSEN_OUT_IFACE="$out_iface"
        return 0
    done
}

main() {
    local detected ygg_iface ygg_ipv6 out_iface enable_nat

    need_root
    require_cmd ip
    require_cmd systemctl
    require_cmd sysctl
    require_cmd nft

    check_existing_install
    check_yggdrasil

    detected="$(detect_ygg_ipv6_and_iface)" || {
        err "Не смог автоматически найти Yggdrasil IPv6 на локальных интерфейсах."
        err "Нужен поднятый Yggdrasil с адресом из диапазона 0200::/7, например 200:... или 300:..."
        err "Проверь: ip -6 addr"
        exit 1
    }
    ygg_iface="$(awk '{print $1}' <<< "$detected")"
    ygg_ipv6="$(awk '{print $2}' <<< "$detected")"

    log "Найден Yggdrasil адрес: $ygg_ipv6 на интерфейсе $ygg_iface"

    choose_out_iface
    out_iface="$CHOSEN_OUT_IFACE"
    if [[ "$out_iface" == "none" ]]; then
        enable_nat="0"
        warn "NAT/forwarding не будет настроен. ygg-exitd только поднимет TUN и UDP listener."
    else
        enable_nat="1"
        log "Трафик клиентов будет выпускаться через интерфейс: $out_iface"
    fi

    write_state_file
    install_binary
    write_whitelist_if_missing
    write_env_file "$ygg_iface" "$out_iface" "$enable_nat"
    write_runner
    write_routing_helpers
    write_nft_helpers
    write_sysctl_file "$enable_nat"
    write_systemd_unit

    systemctl enable --now "$SERVICE_NAME.service"
    setup_docker_firewall_if_needed "$enable_nat"

    echo
    log "Установка завершена."
    echo
    echo "Параметры:"
    echo "  listen:       [$ygg_ipv6]:$LISTEN_PORT_DEFAULT"
    echo "  tun:          $TUN_NAME_DEFAULT"
    echo "  tun cidr:     $TUN_CIDR_DEFAULT"
    echo "  tun mtu:      $TUN_MTU_DEFAULT"
    echo "  whitelist:    $WHITELIST_FILE"
    echo "  out iface:    $out_iface"
    echo "  nft table:    inet ygg_exitd"
    if [[ "$DOCKER_FW_CONFIGURED" == "1" ]]; then
        echo "  docker fw:    enabled via DOCKER-USER"
    else
        echo "  docker fw:    not needed / not detected"
    fi
    echo
    echo "Сейчас whitelist пустой. Добавь Yggdrasil IPv6 клиента в $WHITELIST_FILE и перезапусти сервис:"
    echo "  sudo nano $WHITELIST_FILE"
    echo "  sudo systemctl restart $SERVICE_NAME"
    echo
    echo "Проверка:"
    echo "  systemctl status $SERVICE_NAME"
    echo "  journalctl -u $SERVICE_NAME -f"
    if [[ "$DOCKER_FW_CONFIGURED" == "1" ]]; then
        echo "  systemctl status ygg-exitd-docker-fw"
        echo "  sudo iptables -vnL DOCKER-USER"
    fi
    echo
    echo "Откат:"
    echo "  sudo ./uninstall.sh"
}

main "$@"
