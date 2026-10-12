#!/bin/sh
# reality-deploy.sh
# Interactive VLESS + REALITY deployment helper.
# Roles:
#   1) Linux VPS server (systemd)
#   2) OpenWrt fw3/iptables router client (full-LAN fail-closed gateway)
#   3) Linux systemd workstation client (host-only fail-closed TUN)
#
# Design goals:
#   - POSIX /bin/sh so it can run on BusyBox ash as well as normal Linux.
#   - Ask for environment-specific values instead of assuming one router/VPS.
#   - Validate sing-box configs before enabling them.
#   - Back up files before replacement.
#   - Fail closed on client activation failures.
#
# Tested design lineage: OpenWrt 21.02/fw3/iptables + sing-box 1.14.x.
# Newer OpenWrt fw4/nftables routers are intentionally rejected by the router
# adapter until a separate fw4 implementation is added.

set -u

SCRIPT_VERSION="0.1"
DEFAULT_SB_VERSION="1.14.1"
DEFAULT_PORT="8443"
DEFAULT_SNI="www.microsoft.com"
DEFAULT_DNS="1.1.1.1"
DEFAULT_TUN_ADDR="172.19.0.1/30"
DEFAULT_TUN_IF="sb-tun"
DEFAULT_DNS_PORT="15353"
DEFAULT_TABLE="200"
DEFAULT_LAN_SUBNET="192.168.8.0/24"
DEFAULT_LAN_IF="br-lan"

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" = "0" ] || die "Run this installer as root."
}

have() { command -v "$1" >/dev/null 2>&1; }

prompt() {
    # prompt VAR "Question" "default"
    _var="$1"; _q="$2"; _def="${3:-}"
    if [ -n "$_def" ]; then
        printf '%s [%s]: ' "$_q" "$_def" >&2
    else
        printf '%s: ' "$_q" >&2
    fi
    IFS= read -r _ans || exit 1
    [ -n "$_ans" ] || _ans="$_def"
    eval "$_var=\$_ans"
}

confirm() {
    _q="$1"; _def="${2:-y}"
    if [ "$_def" = "y" ]; then _hint="Y/n"; else _hint="y/N"; fi
    printf '%s [%s]: ' "$_q" "$_hint" >&2
    IFS= read -r _a || exit 1
    [ -n "$_a" ] || _a="$_def"
    case "$_a" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

json_escape() {
    # Good enough for hostnames, IPs, tags, keys and UUIDs accepted here.
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

backup_path() {
    _path="$1"
    [ -e "$_path" ] || return 0
    _ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
    cp -a "$_path" "${_path}.reality-backup.${_ts}" || die "Could not back up $_path"
    say "Backed up $_path -> ${_path}.reality-backup.${_ts}"
}

install_sing_box_official() {
    _version="$1"
    if have sing-box; then
        say "sing-box already installed: $(sing-box version 2>/dev/null | head -1)"
        if confirm "Keep the installed sing-box binary?" y; then
            return 0
        fi
    fi
    have curl || die "curl is required to install sing-box automatically. Install curl first."
    say "Installing sing-box ${_version} using the official installer..."
    curl -fsSL https://sing-box.app/install.sh | sh -s -- --version "$_version" || die "sing-box installation failed"
    have sing-box || die "sing-box binary still not found after installation"
}

generate_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif have uuidgen; then
        uuidgen | tr 'A-Z' 'a-z'
    else
        die "No UUID generator available."
    fi
}

generate_short_id() {
    if have openssl; then
        openssl rand -hex 4
    elif [ -r /dev/urandom ] && have od; then
        od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
    else
        die "Cannot generate REALITY short ID."
    fi
}

generate_reality_keys() {
    _out="$(sing-box generate reality-keypair 2>&1)" || die "Could not generate REALITY keypair: $_out"
    REALITY_PRIVATE_KEY="$(printf '%s\n' "$_out" | awk -F': *' '/[Pp]rivate/{print $2; exit}')"
    REALITY_PUBLIC_KEY="$(printf '%s\n' "$_out" | awk -F': *' '/[Pp]ublic/{print $2; exit}')"
    [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || {
        printf '%s\n' "$_out" >&2
        die "Could not parse sing-box REALITY keypair output."
    }
}

write_systemd_unit() {
    _config="$1"
    cat > /etc/systemd/system/sing-box-reality.service <<EOF_UNIT
[Unit]
Description=sing-box VLESS REALITY
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/sing-box run -c ${_config}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_UNIT
    systemctl daemon-reload
}

server_install() {
    need_root
    [ "$(uname -s)" = "Linux" ] || die "Server role currently supports Linux VPSes only."
    have systemctl || die "Server role requires systemd."

    say ""
    say "=== VLESS + REALITY SERVER INSTALL ==="
    prompt SB_VERSION "sing-box version" "$DEFAULT_SB_VERSION"
    install_sing_box_official "$SB_VERSION"

    _detected_ip=""
    if have curl; then _detected_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"; fi
    prompt SERVER_ADDR "Public IPv4/domain clients will use for this VPS" "$_detected_ip"
    [ -n "$SERVER_ADDR" ] || die "Server address is required."
    prompt LISTEN_PORT "VLESS+REALITY TCP listen port" "$DEFAULT_PORT"
    prompt SNI "REALITY handshake/SNI hostname" "$DEFAULT_SNI"
    prompt HANDSHAKE_PORT "REALITY handshake destination port" "443"

    _uuid_default="$(generate_uuid)"
    prompt UUID "VLESS UUID (press Enter to use generated value)" "$_uuid_default"
    _sid_default="$(generate_short_id)"
    prompt SHORT_ID "REALITY short ID (0-8 hex digits)" "$_sid_default"

    generate_reality_keys

    mkdir -p /etc/sing-box /root/reality-deploy
    chmod 700 /root/reality-deploy
    backup_path /etc/sing-box/reality-server.json

    cat > /etc/sing-box/reality-server.json <<EOF_JSON
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "listen_port": ${LISTEN_PORT},
      "users": [
        {
          "name": "reality-client",
          "uuid": "$(json_escape "$UUID")",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$(json_escape "$SNI")",
            "server_port": ${HANDSHAKE_PORT}
          },
          "private_key": "$(json_escape "$REALITY_PRIVATE_KEY")",
          "short_id": [
            "$(json_escape "$SHORT_ID")"
          ],
          "max_time_difference": "1m"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF_JSON
    chmod 600 /etc/sing-box/reality-server.json

    sing-box check -c /etc/sing-box/reality-server.json || die "Generated server config did not pass sing-box check"

    write_systemd_unit /etc/sing-box/reality-server.json
    systemctl enable sing-box-reality.service >/dev/null 2>&1 || die "Could not enable server service"
    systemctl restart sing-box-reality.service || die "Could not start server service"
    sleep 1
    systemctl is-active --quiet sing-box-reality.service || die "Server service is not active"

    # Best-effort local firewall opening. Cloud/provider firewall is still the user's responsibility.
    if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "${LISTEN_PORT}/tcp" || warn "Could not add UFW rule"
    elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${LISTEN_PORT}/tcp" || warn "Could not add firewalld rule"
        firewall-cmd --reload || warn "Could not reload firewalld"
    fi

    cat > /root/reality-deploy/client.env <<EOF_ENV
REALITY_SERVER='${SERVER_ADDR}'
REALITY_PORT='${LISTEN_PORT}'
REALITY_UUID='${UUID}'
REALITY_PUBLIC_KEY='${REALITY_PUBLIC_KEY}'
REALITY_SHORT_ID='${SHORT_ID}'
REALITY_SNI='${SNI}'
REALITY_SINGBOX_VERSION='${SB_VERSION}'
EOF_ENV
    chmod 600 /root/reality-deploy/client.env

    say ""
    say "=== SERVER READY ==="
    say "Config: /etc/sing-box/reality-server.json"
    say "Service: sing-box-reality.service"
    say "Client bundle: /root/reality-deploy/client.env (KEEP PRIVATE)"
    say ""
    cat /root/reality-deploy/client.env
    say ""
    say "IMPORTANT: Ensure your VPS/provider firewall allows TCP ${LISTEN_PORT}."
}

ask_client_credentials() {
    prompt SERVER_ADDR "VPS IPv4/domain" ""
    prompt SERVER_PORT "VLESS+REALITY TCP port" "$DEFAULT_PORT"
    prompt UUID "VLESS UUID" ""
    prompt PUBLIC_KEY "REALITY public key" ""
    prompt SHORT_ID "REALITY short ID" ""
    prompt SNI "REALITY SNI/handshake hostname" "$DEFAULT_SNI"
    prompt REMOTE_DNS "DNS server to reach through the tunnel" "$DEFAULT_DNS"
    [ -n "$SERVER_ADDR" ] && [ -n "$UUID" ] && [ -n "$PUBLIC_KEY" ] || die "Missing required client credentials"
}

write_openwrt_client_config() {
    mkdir -p /etc/sing-box /etc/reality
    cat > /etc/sing-box/reality-client.json <<EOF_JSON
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "reality-tun",
      "interface_name": "${TUN_IF}",
      "address": ["${TUN_ADDR}"],
      "mtu": ${TUN_MTU},
      "auto_route": false,
      "strict_route": false
    },
    {
      "type": "direct",
      "tag": "reality-dns",
      "listen": "127.0.0.1",
      "listen_port": ${DNS_PORT},
      "override_address": "${REMOTE_DNS}",
      "override_port": 53
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "reality-out",
      "server": "$(json_escape "$SERVER_ADDR")",
      "server_port": ${SERVER_PORT},
      "uuid": "$(json_escape "$UUID")",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$(json_escape "$SNI")",
        "reality": {
          "enabled": true,
          "public_key": "$(json_escape "$PUBLIC_KEY")",
          "short_id": "$(json_escape "$SHORT_ID")"
        }
      }
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "reality-out"
  }
}
EOF_JSON
    chmod 600 /etc/sing-box/reality-client.json
    sing-box check -c /etc/sing-box/reality-client.json || die "Generated OpenWrt client config failed sing-box check"
}

write_openwrt_service() {
    backup_path /etc/init.d/sing-box
    cat > /etc/init.d/sing-box <<'EOF_INIT'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10

start_service() {
    /usr/bin/sing-box check -c /etc/sing-box/reality-client.json || return 1
    procd_open_instance
    procd_set_param command /usr/bin/sing-box run -c /etc/sing-box/reality-client.json
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param file /etc/sing-box/reality-client.json
    procd_close_instance
}
EOF_INIT
    chmod 755 /etc/init.d/sing-box
    /etc/init.d/sing-box enable
}

write_openwrt_env() {
    cat > /etc/reality/install.env <<EOF_ENV
MODE_FILE='/etc/reality/mode'
LAN_INTERFACE='${LAN_IF}'
LAN_SUBNET='${LAN_SUBNET}'
FORWARDING='${FORWARDING}'
TUN_INTERFACE='${TUN_IF}'
TUN_ADDRESS='${TUN_ADDR}'
TABLE_ID='${TABLE_ID}'
DNS_PORT='${DNS_PORT}'
REMOTE_DNS='${REMOTE_DNS}'
SERVER_ADDR='${SERVER_ADDR}'
SERVER_PORT='${SERVER_PORT}'
EOF_ENV
    chmod 600 /etc/reality/install.env
}

write_openwrt_firewall() {
    cat > /etc/reality/firewall.sh <<'EOF_FW'
#!/bin/sh
. /etc/reality/install.env
MODE="$(cat "$MODE_FILE" 2>/dev/null)"
V4=REALITY_GUARD
V6=REALITY6_GUARD
D4=REALITY_DNS4
D6=REALITY_DNS6
NR=REALITY_DNS_REDIRECT

remove_rules() {
    while iptables -w 5 -D FORWARD -j "$V4" 2>/dev/null; do :; done
    while ip6tables -w 5 -D FORWARD -j "$V6" 2>/dev/null; do :; done
    for p in tcp udp; do
        while iptables -w 5 -D OUTPUT -p "$p" --dport 53 -j "$D4" 2>/dev/null; do :; done
        while ip6tables -w 5 -D OUTPUT -p "$p" --dport 53 -j "$D6" 2>/dev/null; do :; done
        while iptables -w 5 -t nat -D PREROUTING -i "$LAN_INTERFACE" -p "$p" --dport 53 -j "$NR" 2>/dev/null; do :; done
    done
    iptables -w 5 -F "$V4" 2>/dev/null; iptables -w 5 -X "$V4" 2>/dev/null
    ip6tables -w 5 -F "$V6" 2>/dev/null; ip6tables -w 5 -X "$V6" 2>/dev/null
    iptables -w 5 -F "$D4" 2>/dev/null; iptables -w 5 -X "$D4" 2>/dev/null
    ip6tables -w 5 -F "$D6" 2>/dev/null; ip6tables -w 5 -X "$D6" 2>/dev/null
    iptables -w 5 -t nat -F "$NR" 2>/dev/null; iptables -w 5 -t nat -X "$NR" 2>/dev/null
}

[ "$MODE" = "reality" ] || { remove_rules; exit 0; }

iptables -w 5 -N "$V4" 2>/dev/null || iptables -w 5 -L "$V4" >/dev/null || exit 1
ip6tables -w 5 -N "$V6" 2>/dev/null || ip6tables -w 5 -L "$V6" >/dev/null || exit 1
iptables -w 5 -N "$D4" 2>/dev/null || iptables -w 5 -L "$D4" >/dev/null || exit 1
ip6tables -w 5 -N "$D6" 2>/dev/null || ip6tables -w 5 -L "$D6" >/dev/null || exit 1
iptables -w 5 -t nat -N "$NR" 2>/dev/null || iptables -w 5 -t nat -L "$NR" >/dev/null || exit 1

iptables -w 5 -F "$V4" || exit 1
ip6tables -w 5 -F "$V6" || exit 1
iptables -w 5 -F "$D4" || exit 1
ip6tables -w 5 -F "$D6" || exit 1
iptables -w 5 -t nat -F "$NR" || exit 1

iptables -w 5 -A "$V4" -i "$LAN_INTERFACE" -o "$TUN_INTERFACE" -j ACCEPT || exit 1
iptables -w 5 -A "$V4" -i "$LAN_INTERFACE" -j REJECT || exit 1
ip6tables -w 5 -A "$V6" -i "$LAN_INTERFACE" -j REJECT || exit 1

iptables -w 5 -A "$D4" -d 127.0.0.0/8 -j RETURN || exit 1
iptables -w 5 -A "$D4" -j REJECT || exit 1
ip6tables -w 5 -A "$D6" -d ::1/128 -j RETURN || exit 1
ip6tables -w 5 -A "$D6" -j REJECT || exit 1

iptables -w 5 -t nat -A "$NR" -j REDIRECT --to-ports 53 || exit 1

iptables -w 5 -C FORWARD -j "$V4" 2>/dev/null || iptables -w 5 -I FORWARD 1 -j "$V4" || exit 1
ip6tables -w 5 -C FORWARD -j "$V6" 2>/dev/null || ip6tables -w 5 -I FORWARD 1 -j "$V6" || exit 1
for p in tcp udp; do
    iptables -w 5 -C OUTPUT -p "$p" --dport 53 -j "$D4" 2>/dev/null || iptables -w 5 -I OUTPUT 1 -p "$p" --dport 53 -j "$D4" || exit 1
    ip6tables -w 5 -C OUTPUT -p "$p" --dport 53 -j "$D6" 2>/dev/null || ip6tables -w 5 -I OUTPUT 1 -p "$p" --dport 53 -j "$D6" || exit 1
    iptables -w 5 -t nat -C PREROUTING -i "$LAN_INTERFACE" -p "$p" --dport 53 -j "$NR" 2>/dev/null || \
        iptables -w 5 -t nat -I PREROUTING 1 -i "$LAN_INTERFACE" -p "$p" --dport 53 -j "$NR" || exit 1
done
exit 0
EOF_FW
    chmod 755 /etc/reality/firewall.sh

    # Ensure firewall.user calls our script exactly once.
    [ -f /etc/firewall.user ] || : > /etc/firewall.user
    grep -q '^/bin/sh /etc/reality/firewall.sh$' /etc/firewall.user 2>/dev/null || \
        printf '\n/bin/sh /etc/reality/firewall.sh\n' >> /etc/firewall.user
}

write_openwrt_recover() {
    cat > /etc/reality/recover.sh <<'EOF_REC'
#!/bin/sh
. /etc/reality/install.env
FAILED=0
error(){ echo "WARNING: $*"; FAILED=1; }

echo "Restoring normal Internet..."
[ "$(uci -q get "$FORWARDING.src")" = "lan" ] && [ "$(uci -q get "$FORWARDING.dest")" = "wan" ] || {
    echo "ERROR: Native forwarding selector no longer points to lan->wan."
    exit 1
}
while ip -4 rule del pref 10000 from "$LAN_SUBNET" iif "$LAN_INTERFACE" lookup "$TABLE_ID" 2>/dev/null; do :; done
while ip -4 rule del pref 10001 from "$LAN_SUBNET" iif "$LAN_INTERFACE" unreachable 2>/dev/null; do :; done
while ip -6 rule del pref 10000 iif "$LAN_INTERFACE" unreachable 2>/dev/null; do :; done
while ip -4 rule del pref 9000 from "$LAN_SUBNET" iif "$LAN_INTERFACE" unreachable 2>/dev/null; do :; done
while ip -6 rule del pref 9000 iif "$LAN_INTERFACE" unreachable 2>/dev/null; do :; done
ip -4 route flush table "$TABLE_ID" 2>/dev/null

if [ -f /etc/reality/dhcp.normal ]; then
    cp /etc/reality/dhcp.normal /etc/config/dhcp || error "Cannot restore DNS configuration"
    /etc/init.d/dnsmasq restart || error "Cannot restart dnsmasq"
else
    error "Normal DNS backup is missing"
fi

echo normal > "$MODE_FILE" || error "Cannot save normal mode"
/bin/sh /etc/reality/firewall.sh || error "Cannot remove REALITY firewall guards"

if [ "$FAILED" -eq 0 ]; then
    uci set "$FORWARDING.enabled=1" || error "Cannot enable native forwarding"
    uci commit firewall || error "Cannot commit native forwarding"
    [ "$FAILED" -eq 0 ] && /etc/init.d/firewall reload >/dev/null 2>&1 || error "Cannot reload firewall"
fi

[ "$FAILED" -eq 0 ] || { echo "ERROR: Recovery incomplete."; exit 1; }
echo "Recovery completed."
EOF_REC
    chmod 755 /etc/reality/recover.sh
}

write_openwrt_control() {
    cat > /etc/reality/control.sh <<'EOF_CTL'
#!/bin/sh
. /etc/reality/install.env
FIREWALL=/etc/reality/firewall.sh
TRANSITION_STARTED=0

check_forwarding(){
    [ "$(uci -q get "$FORWARDING.src")" = "lan" ] && [ "$(uci -q get "$FORWARDING.dest")" = "wan" ]
}

fail(){
    echo "ERROR: $*"
    if [ "$TRANSITION_STARTED" = "1" ]; then
        echo "Activation began; preserving fail-closed state."
        echo reality > "$MODE_FILE" 2>/dev/null || echo "CRITICAL: Cannot persist REALITY mode."
        if check_forwarding && [ "$(uci -q get "$FORWARDING.enabled")" != "0" ]; then
            uci set "$FORWARDING.enabled=0" && uci commit firewall && /etc/init.d/firewall reload >/dev/null 2>&1 || \
                echo "CRITICAL: Could not persist native WAN restriction."
        fi
        echo "Use /etc/reality/recover.sh only if you intentionally want ordinary Internet."
    else
        echo "Activation stopped before network changes."
    fi
    exit 1
}

show_status(){
    echo "=== Operating mode ==="; cat "$MODE_FILE"
    echo "=== Native LAN-to-WAN forwarding ==="; uci -q get "$FORWARDING.enabled"
    echo "=== sing-box ==="; /etc/init.d/sing-box status
    echo "=== REALITY interface ==="; ip -br addr show "$TUN_INTERFACE" 2>/dev/null || true
    echo "=== IPv4 routing ==="; ip -4 rule show; ip -4 route show table "$TABLE_ID" 2>/dev/null
    echo "=== IPv6 routing ==="; ip -6 rule show
    echo "=== Firewall guards ==="; iptables -S FORWARD 2>/dev/null | grep REALITY_GUARD || true; ip6tables -S FORWARD 2>/dev/null | grep REALITY6_GUARD || true
    echo "=== DNS ==="; uci show dhcp.@dnsmasq[0] 2>/dev/null | grep -E 'noresolv|server' || true
}

activate(){
    [ "$(cat "$MODE_FILE" 2>/dev/null)" = "normal" ] || { echo "ERROR: Router is not in normal mode."; return 1; }
    check_forwarding || { echo "ERROR: Native forwarding selector differs."; return 1; }
    [ "$(uci -q get "$FORWARDING.enabled")" = "1" ] || { echo "ERROR: Native forwarding is not enabled."; return 1; }
    /etc/init.d/sing-box status >/dev/null || { echo "ERROR: sing-box is not running."; return 1; }
    ip link show "$TUN_INTERFACE" >/dev/null 2>&1 || { echo "ERROR: REALITY TUN unavailable."; return 1; }
    for p in 9000 10000 10001; do ip -4 rule show | grep -q "^${p}:" && { echo "ERROR: Unexpected IPv4 rule $p"; return 1; }; done
    for p in 9000 10000; do ip -6 rule show | grep -q "^${p}:" && { echo "ERROR: Unexpected IPv6 rule $p"; return 1; }; done
    T="$(ip -4 route show table "$TABLE_ID" 2>&1)"; R=$?
    if [ "$R" -eq 0 ]; then [ -z "$T" ] || { echo "ERROR: table $TABLE_ID not empty"; return 1; }
    elif [ "$T" != "Dump terminated" ]; then echo "ERROR: Cannot inspect table $TABLE_ID: $T"; return 1; fi

    cp /etc/config/dhcp /etc/reality/dhcp.normal || { echo "ERROR: Cannot back up normal DNS configuration."; return 1; }

    echo "Installing temporary forwarding protection..."
    ip -4 rule add pref 9000 from "$LAN_SUBNET" iif "$LAN_INTERFACE" unreachable || fail "Cannot install temporary IPv4 protection"
    TRANSITION_STARTED=1
    ip -6 rule add pref 9000 iif "$LAN_INTERFACE" unreachable || fail "Cannot install temporary IPv6 protection"
    echo reality > "$MODE_FILE" || fail "Cannot save REALITY mode"

    echo "Disabling native LAN-to-WAN forwarding..."
    uci set "$FORWARDING.enabled=0" || fail "Cannot configure native firewall"
    uci commit firewall || fail "Cannot save native firewall"
    /etc/init.d/firewall reload >/dev/null 2>&1 || fail "Native firewall reload failed"
    [ "$(uci -q get "$FORWARDING.enabled")" = "0" ] || fail "Native forwarding restriction not saved"
    iptables -S zone_lan_forward 2>/dev/null | grep -q 'zone_wan_dest_ACCEPT' && fail "Native LAN->WAN forwarding still present"

    echo "Preparing protected tunnel routing..."
    ip -4 route add unreachable default metric 42700 table "$TABLE_ID" || fail "Cannot install unreachable fallback"
    ip -4 route add default dev "$TUN_INTERFACE" metric 10 table "$TABLE_ID" || fail "Cannot install tunnel route"
    ip -6 rule add pref 10000 iif "$LAN_INTERFACE" unreachable || fail "Cannot install IPv6 restriction"
    /bin/sh "$FIREWALL" || fail "Cannot install REALITY firewall"

    echo "Configuring protected DNS..."
    uci set dhcp.@dnsmasq[0].noresolv='1' || fail "Cannot configure dnsmasq"
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#${DNS_PORT}" || fail "Cannot set protected DNS upstream"
    uci commit dhcp || fail "Cannot save DNS config"
    /etc/init.d/dnsmasq restart || fail "Cannot restart dnsmasq"

    echo "Installing permanent routing protection..."
    ip -4 rule add pref 10001 from "$LAN_SUBNET" iif "$LAN_INTERFACE" unreachable || fail "Cannot install IPv4 fallback"
    ip -4 rule add pref 10000 from "$LAN_SUBNET" iif "$LAN_INTERFACE" lookup "$TABLE_ID" || fail "Cannot install tunnel policy"
    ip -4 rule show | grep -q '^10000:.*lookup ' || fail "Tunnel policy verification failed"
    ip -4 rule show | grep -q '^10001:.*unreachable' || fail "IPv4 fallback verification failed"
    ip -6 rule show | grep -q '^10000:.*unreachable' || fail "IPv6 verification failed"
    ip -4 route show table "$TABLE_ID" | grep -q "default dev ${TUN_INTERFACE}" || fail "Tunnel route verification failed"
    ip -4 route show table "$TABLE_ID" | grep -q 'unreachable default metric 42700' || fail "Unreachable route verification failed"

    echo "Releasing temporary startup restrictions..."
    ip -4 rule del pref 9000 from "$LAN_SUBNET" iif "$LAN_INTERFACE" unreachable || fail "Cannot remove temporary IPv4 protection"
    ip -6 rule del pref 9000 iif "$LAN_INTERFACE" unreachable || fail "Cannot remove temporary IPv6 protection"

    echo "REALITY LAN mode activated."
    echo "Native LAN-to-WAN forwarding: DISABLED"
    echo "Protected network: $LAN_SUBNET"
}

case "${1:-}" in
    status) show_status ;;
    reality|on) activate ;;
    normal|off) /bin/sh /etc/reality/recover.sh ;;
    *) echo "Usage: $0 {status|reality|normal}"; exit 1 ;;
esac
EOF_CTL
    chmod 755 /etc/reality/control.sh
}

write_openwrt_boot() {
    cat > /etc/reality/restore-boot.sh <<'EOF_RB'
#!/bin/sh
. /etc/reality/install.env
[ "$(cat "$MODE_FILE" 2>/dev/null)" = "reality" ] || exit 0

ip -4 rule show | grep -q '^9000:' || { echo "Missing early IPv4 protection"; exit 1; }
ip -6 rule show | grep -q '^9000:' || { echo "Missing early IPv6 protection"; exit 1; }

N=0
while [ "$N" -lt 20 ]; do
    /etc/init.d/sing-box status >/dev/null 2>&1 && ip link show "$TUN_INTERFACE" >/dev/null 2>&1 && break
    N=$((N+1)); sleep 2
done
ip link show "$TUN_INTERFACE" >/dev/null 2>&1 || { echo "TUN unavailable; keeping early blocks"; exit 1; }

/bin/sh /etc/reality/firewall.sh || exit 1

# Refuse unexpected permanent state; startup protection remains if anything is odd.
for p in 10000 10001; do ip -4 rule show | grep -q "^${p}:" && { echo "Unexpected IPv4 rule $p"; exit 1; }; done
ip -6 rule show | grep -q '^10000:' && { echo "Unexpected IPv6 rule 10000"; exit 1; }

ip -4 route flush table "$TABLE_ID" 2>/dev/null
ip -4 route add unreachable default metric 42700 table "$TABLE_ID" || exit 1
ip -4 route add default dev "$TUN_INTERFACE" metric 10 table "$TABLE_ID" || exit 1
ip -6 rule add pref 10000 iif "$LAN_INTERFACE" unreachable || exit 1
ip -4 rule add pref 10001 from "$LAN_SUBNET" iif "$LAN_INTERFACE" unreachable || exit 1
ip -4 rule add pref 10000 from "$LAN_SUBNET" iif "$LAN_INTERFACE" lookup "$TABLE_ID" || exit 1

ip -4 rule show | grep -q '^10000:.*lookup ' || exit 1
ip -4 rule show | grep -q '^10001:.*unreachable' || exit 1
ip -6 rule show | grep -q '^10000:.*unreachable' || exit 1
ip -4 route show table "$TABLE_ID" | grep -q "default dev ${TUN_INTERFACE}" || exit 1
ip -4 route show table "$TABLE_ID" | grep -q 'unreachable default metric 42700' || exit 1

ip -4 rule del pref 9000 from "$LAN_SUBNET" iif "$LAN_INTERFACE" unreachable || exit 1
ip -6 rule del pref 9000 iif "$LAN_INTERFACE" unreachable || exit 1

echo "Automatic REALITY restoration completed"
EOF_RB
    chmod 755 /etc/reality/restore-boot.sh

    cat > /etc/init.d/reality-early <<'EOF_EARLY'
#!/bin/sh /etc/rc.common
START=18
STOP=90
. /etc/reality/install.env
start() {
    [ "$(cat "$MODE_FILE" 2>/dev/null)" = "reality" ] || return 0
    ip -4 rule show | grep -q '^9000:' || ip -4 rule add pref 9000 from "$LAN_SUBNET" iif "$LAN_INTERFACE" unreachable || return 1
    ip -6 rule show | grep -q '^9000:' || ip -6 rule add pref 9000 iif "$LAN_INTERFACE" unreachable || return 1
    [ "$(uci -q get "$FORWARDING.src")" = "lan" ] && [ "$(uci -q get "$FORWARDING.dest")" = "wan" ] || return 1
    if [ "$(uci -q get "$FORWARDING.enabled")" != "0" ]; then
        uci set "$FORWARDING.enabled=0" || return 1
        uci commit firewall || return 1
    fi
    /bin/sh /etc/reality/firewall.sh || return 1
    if [ -f /etc/reality/dhcp.normal ]; then
        uci set dhcp.@dnsmasq[0].noresolv='1'
        uci -q delete dhcp.@dnsmasq[0].server
        uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#${DNS_PORT}"
        uci commit dhcp
    fi
    return 0
}
EOF_EARLY
    chmod 755 /etc/init.d/reality-early
    /etc/init.d/reality-early enable

    cat > /etc/init.d/zreality-restore <<'EOF_LATE'
#!/bin/sh /etc/rc.common
START=99
STOP=9
LOG=/etc/reality/boot-events.log
log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') RESTORE: $*" >> "$LOG"; logger -t reality-restore "$*"; }
start() {
    . /etc/reality/install.env
    [ "$(cat "$MODE_FILE" 2>/dev/null)" = "reality" ] || { log "Normal mode; nothing to restore"; return 0; }
    log "Reinstalling startup protection"
    /etc/init.d/reality-early start >> "$LOG" 2>&1 || { log "Early protection failed"; return 1; }
    /etc/init.d/firewall reload >> "$LOG" 2>&1 || { log "Firewall reload failed"; return 1; }
    /bin/sh /etc/reality/firewall.sh >> "$LOG" 2>&1 || { log "Custom firewall failed"; return 1; }
    log "Beginning permanent REALITY restoration"
    /bin/sh /etc/reality/restore-boot.sh >> "$LOG" 2>&1 || { log "REALITY restoration failed; early protection retained"; return 1; }
    log "REALITY restoration succeeded"
}
EOF_LATE
    chmod 755 /etc/init.d/zreality-restore
    /etc/init.d/zreality-restore enable
}

write_openwrt_hotplug() {
    mkdir -p /etc/hotplug.d/net
    cat > /etc/hotplug.d/net/98-reality-route <<'EOF_HP'
#!/bin/sh
SCRIPT=/etc/hotplug.d/net/98-reality-route
. /etc/reality/install.env
LOG=/tmp/reality-route.log
log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; logger -t reality-route "$*"; }
restore_route(){
    log "Recovery worker started"
    N=0
    while [ "$N" -lt 15 ]; do
        [ "$(cat "$MODE_FILE" 2>/dev/null)" = "reality" ] || return 0
        ip -4 addr show dev "$TUN_INTERFACE" 2>/dev/null | grep -q 'inet ' && break
        N=$((N+1)); sleep 1
    done
    ip -4 addr show dev "$TUN_INTERFACE" 2>/dev/null | grep -q 'inet ' || { log "TUN not ready"; return 1; }
    if ip -4 rule show | grep -q '^9000:' || ip -6 rule show | grep -q '^9000:'; then log "Startup guards active; deferring to boot service"; return 0; fi
    [ "$(uci -q get "$FORWARDING.enabled")" = "0" ] || { log "Native WAN restriction absent"; return 1; }
    ip -4 rule show | grep -q '^10000:.*lookup ' || { log "IPv4 tunnel policy missing"; return 1; }
    ip -4 rule show | grep -q '^10001:.*unreachable' || { log "IPv4 fallback missing"; return 1; }
    ip -6 rule show | grep -q '^10000:.*unreachable' || { log "IPv6 protection missing"; return 1; }
    iptables -C FORWARD -j REALITY_GUARD 2>/dev/null || { log "Firewall guard missing"; return 1; }
    ip -4 route show table "$TABLE_ID" | grep -q 'unreachable default metric 42700' || { log "Unreachable route missing"; return 1; }
    if ip -4 route show table "$TABLE_ID" | grep -q "default dev ${TUN_INTERFACE}.*metric 10"; then log "Tunnel route already installed"; return 0; fi
    ip -4 route replace default dev "$TUN_INTERFACE" metric 10 table "$TABLE_ID" || { log "Route restore failed"; return 1; }
    log "SUCCESS: Tunnel route restored automatically"
}
[ "${1:-}" = "--restore" ] && { restore_route; exit $?; }
[ "$ACTION" = "add" ] || exit 0
[ "$INTERFACE" = "$TUN_INTERFACE" ] || [ "$DEVICENAME" = "$TUN_INTERFACE" ] || exit 0
log "Detected ${TUN_INTERFACE} creation"
[ "$(cat "$MODE_FILE" 2>/dev/null)" = "reality" ] || { log "Normal mode: ignoring tunnel event"; exit 0; }
/bin/sh "$SCRIPT" --restore </dev/null >/dev/null 2>&1 &
exit 0
EOF_HP
    chmod 755 /etc/hotplug.d/net/98-reality-route
}

write_openwrt_aliases() {
    cat > /root/.vpn_aliases <<'EOF_AL'
reality(){ /etc/reality/control.sh reality "$@"; }
normal(){ echo "WARNING: restoring ordinary Internet"; /etc/reality/control.sh normal; }
vpnstatus(){ /etc/reality/control.sh status; }
vpncheck(){
    . /etc/reality/install.env
    echo "=== MODE ==="; cat "$MODE_FILE"
    echo "=== NATIVE FORWARDING ==="; uci -q get "$FORWARDING.enabled"
    echo "=== TUN ==="; ip -br addr show "$TUN_INTERFACE" 2>/dev/null || true
    echo "=== IPv4 ==="; ip -4 rule show; ip -4 route show table "$TABLE_ID" 2>/dev/null
    echo "=== IPv6 ==="; ip -6 rule show
    echo "=== FIREWALL ==="; iptables -S FORWARD 2>/dev/null | grep REALITY || true; ip6tables -S FORWARD 2>/dev/null | grep REALITY || true
}
vpnlogs(){ logread -e sing-box | tail -25; echo; logread -e reality-route | tail -15; echo; tail -20 /etc/reality/boot-events.log 2>/dev/null; }
vpnhelp(){ echo "reality | normal | vpnstatus | vpncheck | vpnlogs | vpnhelp"; }
EOF_AL
    chmod 600 /root/.vpn_aliases
    if [ ! -f /root/.profile ]; then
        cat > /root/.profile <<'EOF_PROF'
#!/bin/sh
[ -r /root/.vpn_aliases ] && . /root/.vpn_aliases
EOF_PROF
    elif ! grep -q '/root/.vpn_aliases' /root/.profile; then
        printf '\n[ -r /root/.vpn_aliases ] && . /root/.vpn_aliases\n' >> /root/.profile
    fi
    chmod 600 /root/.profile
}

openwrt_install() {
    need_root
    [ -f /etc/openwrt_release ] || die "This does not look like OpenWrt."
    have uci || die "uci not found"
    have iptables || die "iptables not found. This v1 router adapter supports fw3/iptables only."
    if have fw4 || uci -q get firewall.@defaults[0].fw4 >/dev/null 2>&1; then
        die "Detected a possible fw4/nftables OpenWrt. This v1 router adapter intentionally supports fw3/iptables only."
    fi
    [ -x /etc/init.d/firewall ] || die "OpenWrt firewall service not found"

    say ""
    say "=== OPENWRT FULL-LAN REALITY GATEWAY INSTALL ==="
    warn "This adapter changes routing, dnsmasq and the lan->wan forwarding rule."
    warn "Keep a local SSH session available during first activation."

    prompt SB_VERSION "sing-box version" "$DEFAULT_SB_VERSION"
    install_sing_box_official "$SB_VERSION"
    ask_client_credentials

    prompt LAN_IF "LAN bridge/interface" "$DEFAULT_LAN_IF"
    _guess_subnet="$DEFAULT_LAN_SUBNET"
    if have ip; then
        _cidr="$(ip -4 -o addr show dev "$LAN_IF" 2>/dev/null | awk '{print $4; exit}')"
        [ -n "$_cidr" ] && _guess_subnet="$_cidr"
    fi
    prompt LAN_SUBNET "Protected LAN CIDR" "$_guess_subnet"
    prompt FORWARDING "UCI lan->wan forwarding selector" "firewall.@forwarding[0]"
    [ "$(uci -q get "$FORWARDING.src")" = "lan" ] && [ "$(uci -q get "$FORWARDING.dest")" = "wan" ] || \
        die "$FORWARDING is not a lan->wan forwarding section. Find the correct selector before continuing."
    prompt TUN_IF "TUN interface name" "$DEFAULT_TUN_IF"
    prompt TUN_ADDR "TUN IPv4 CIDR" "$DEFAULT_TUN_ADDR"
    prompt TUN_MTU "TUN MTU" "1400"
    prompt DNS_PORT "Local sing-box DNS relay port" "$DEFAULT_DNS_PORT"
    prompt TABLE_ID "Policy routing table ID" "$DEFAULT_TABLE"

    # Flow/hardware offload can bypass or outlive ordinary netfilter paths on some routers.
    # Keep it disabled for this fail-closed design. We intentionally do not re-enable it
    # when returning to normal mode.
    if uci -q get firewall.@defaults[0] >/dev/null 2>&1; then
        uci set firewall.@defaults[0].flow_offloading='0' 2>/dev/null || true
        uci set firewall.@defaults[0].flow_offloading_hw='0' 2>/dev/null || true
        uci commit firewall 2>/dev/null || true
    fi
    if uci -q get mtkhnat.global.enable >/dev/null 2>&1; then
        uci set mtkhnat.global.enable='0' || die "Could not disable MediaTek hardware acceleration"
        uci commit mtkhnat || die "Could not save MediaTek hardware acceleration setting"
    fi

    mkdir -p /etc/reality /root/network-backup
    [ -f /etc/reality/mode ] || echo normal > /etc/reality/mode
    [ "$(cat /etc/reality/mode 2>/dev/null)" = "normal" ] || die "Existing /etc/reality/mode is not normal; aborting install"

    write_openwrt_env
    write_openwrt_client_config
    write_openwrt_service
    write_openwrt_firewall
    write_openwrt_recover
    write_openwrt_control
    write_openwrt_boot
    write_openwrt_hotplug
    write_openwrt_aliases

    # Initial normal DNS snapshot.
    cp /etc/config/dhcp /etc/reality/dhcp.normal || die "Could not save initial normal DNS config"
    chmod 600 /etc/reality/dhcp.normal

    /etc/init.d/sing-box restart || die "Could not start sing-box"
    sleep 3
    /etc/init.d/sing-box status >/dev/null || die "sing-box not running"
    ip link show "$TUN_IF" >/dev/null 2>&1 || die "TUN interface $TUN_IF not present"

    /bin/sh /etc/reality/firewall.sh || die "Normal-mode firewall cleanup failed"

    say ""
    say "=== OPENWRT CLIENT INSTALLED ==="
    say "The router is still in NORMAL mode."
    say "First activation: /etc/reality/control.sh reality"
    say "Status:           /etc/reality/control.sh status"
    say "Return to normal: /etc/reality/control.sh normal"
    say "After reconnecting SSH, shortcuts: reality, normal, vpnstatus, vpncheck, vpnlogs"
    say ""
    warn "Do not treat the setup as validated until you run an IP test, a sing-box restart test, and a REALITY-mode reboot test on this specific router."
}

write_linux_client_config() {
    mkdir -p /etc/sing-box /etc/reality
    cat > /etc/sing-box/reality-client.json <<EOF_JSON
{
  "log": {"level": "info", "timestamp": true},
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "remote-dns",
        "server": "${REMOTE_DNS}",
        "server_port": 53,
        "detour": "reality-out"
      }
    ],
    "final": "remote-dns",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "${TUN_IF}",
      "address": ["${TUN_ADDR}"],
      "mtu": ${TUN_MTU},
      "dns_mode": "hijack",
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": true
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "reality-out",
      "server": "$(json_escape "$SERVER_ADDR")",
      "server_port": ${SERVER_PORT},
      "uuid": "$(json_escape "$UUID")",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$(json_escape "$SNI")",
        "reality": {
          "enabled": true,
          "public_key": "$(json_escape "$PUBLIC_KEY")",
          "short_id": "$(json_escape "$SHORT_ID")"
        }
      }
    },
    {"type": "direct", "tag": "direct"}
  ],
  "route": {
    "rules": [
      {"action": "sniff"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"ip_is_private": true, "outbound": "direct"}
    ],
    "auto_detect_interface": true,
    "final": "reality-out"
  }
}
EOF_JSON
    chmod 600 /etc/sing-box/reality-client.json
    sing-box check -c /etc/sing-box/reality-client.json || die "Generated Linux client config failed sing-box check"
}

write_linux_killswitch() {
    have nft || die "Linux workstation mode requires nftables (nft command)."
    cat > /usr/local/sbin/reality-killswitch-on <<EOF_KON
#!/bin/sh
set -e
nft delete table inet reality_killswitch 2>/dev/null || true
nft -f - <<'NFT'
table inet reality_killswitch {
  chain output {
    type filter hook output priority -50; policy drop;
    oifname "lo" accept
    ct state established,related accept
    oifname "${TUN_IF}" accept
    ip daddr ${SERVER_ADDR} tcp dport ${SERVER_PORT} accept
    udp sport 68 udp dport 67 accept
    udp sport 67 udp dport 68 accept
    ip daddr 127.0.0.0/8 accept
NFT
    if [ "$ALLOW_LAN" = "yes" ]; then
        cat >> /tmp/.reality-nft-extra <<'EOF_EXTRA'
EOF_EXTRA
        # Append RFC1918/link-local acceptance by rebuilding with 'nft add rule' after table load.
    fi
    cat >> /usr/local/sbin/reality-killswitch-on <<'EOF_DUMMY'
EOF_DUMMY
EOF_KON
    # Finish the nft heredoc in file; doing this in pieces keeps variable expansion controlled.
    cat >> /usr/local/sbin/reality-killswitch-on <<'EOF_KON2'
  }
}
NFT
EOF_KON2
    if [ "$ALLOW_LAN" = "yes" ]; then
        # Insert before final generic state isn't necessary; nft adds at end and policy still drop.
        cat >> /usr/local/sbin/reality-killswitch-on <<'EOF_LAN'
nft add rule inet reality_killswitch output ip daddr 10.0.0.0/8 accept
nft add rule inet reality_killswitch output ip daddr 172.16.0.0/12 accept
nft add rule inet reality_killswitch output ip daddr 192.168.0.0/16 accept
nft add rule inet reality_killswitch output ip daddr 169.254.0.0/16 accept
EOF_LAN
    fi
    chmod 755 /usr/local/sbin/reality-killswitch-on

    cat > /usr/local/sbin/reality-killswitch-off <<'EOF_KOFF'
#!/bin/sh
nft delete table inet reality_killswitch 2>/dev/null || true
EOF_KOFF
    chmod 755 /usr/local/sbin/reality-killswitch-off
}

write_linux_control() {
    cat > /usr/local/sbin/reality <<'EOF_LCTL'
#!/bin/sh
case "${1:-on}" in
  on)
    /usr/local/sbin/reality-killswitch-on || exit 1
    systemctl restart sing-box-reality-client.service || exit 1
    echo "REALITY client started with fail-closed nftables output policy."
    ;;
  off|normal)
    systemctl stop sing-box-reality-client.service 2>/dev/null || true
    /usr/local/sbin/reality-killswitch-off
    echo "Normal Internet restored."
    ;;
  status)
    systemctl --no-pager --full status sing-box-reality-client.service || true
    echo "=== kill switch ==="
    nft list table inet reality_killswitch 2>/dev/null || echo "kill switch OFF"
    ;;
  *) echo "Usage: reality {on|off|status}"; exit 1 ;;
esac
EOF_LCTL
    chmod 755 /usr/local/sbin/reality
}

linux_client_install() {
    need_root
    [ "$(uname -s)" = "Linux" ] || die "Linux workstation mode supports Linux only."
    have systemctl || die "Linux workstation mode requires systemd."
    say ""
    say "=== LINUX WORKSTATION REALITY CLIENT INSTALL ==="
    prompt SB_VERSION "sing-box version" "$DEFAULT_SB_VERSION"
    install_sing_box_official "$SB_VERSION"
    ask_client_credentials
    prompt TUN_IF "TUN interface name" "$DEFAULT_TUN_IF"
    prompt TUN_ADDR "TUN IPv4 CIDR" "$DEFAULT_TUN_ADDR"
    prompt TUN_MTU "TUN MTU" "1400"
    if confirm "Allow direct access to RFC1918/link-local LANs while kill switch is active?" y; then ALLOW_LAN=yes; else ALLOW_LAN=no; fi

    case "$SERVER_ADDR" in
      *[!0-9.]*|'') die "For fail-closed Linux workstation mode, enter the VPS as a literal IPv4 address (not a hostname)." ;;
    esac

    write_linux_client_config
    write_linux_killswitch
    write_linux_control

    cat > /etc/systemd/system/sing-box-reality-client.service <<EOF_UNIT
[Unit]
Description=sing-box REALITY workstation client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/local/sbin/reality-killswitch-on
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/reality-client.json
Restart=on-failure
RestartSec=2# Deliberately no ExecStopPost: stopping/crashing sing-box leaves the kill switch ON.

[Install]
WantedBy=multi-user.target
EOF_UNIT
    systemctl daemon-reload
    # Do not enable by default: user chooses whether boot should start protected mode.

    say ""
    say "=== LINUX CLIENT INSTALLED ==="
    say "Start protected mode: sudo reality on"
    say "Status:               sudo reality status"
    say "Return to normal:     sudo reality off"
    warn "The service is NOT enabled at boot by default. Use 'systemctl enable sing-box-reality-client.service' only after testing this machine."
}

show_header() {
    say "reality-deploy.sh v${SCRIPT_VERSION}"
    say "Interactive VLESS + REALITY deployment"
    say ""
}

main_menu() {
    show_header
    say "Choose a role:"
    say "  1) VPS server (Linux + systemd)"
    say "  2) OpenWrt router client (fw3/iptables, full LAN)"
    say "  3) Linux computer client (systemd + nftables, this host only)"
    say ""
    prompt ROLE "Role" ""
    case "$ROLE" in
        1|server) server_install ;;
        2|openwrt|router) openwrt_install ;;
        3|linux|client) linux_client_install ;;
        *) die "Unknown role" ;;
    esac
}

main_menu