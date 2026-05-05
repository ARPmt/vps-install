#!/usr/bin/env sh

set -eu

export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config}"

if [ -f "$CONFIG_FILE" ]; then
	# shellcheck disable=SC1090
	. "$CONFIG_FILE"
fi

ENABLE_IPTABLES="${ENABLE_IPTABLES:-true}"
SSH_PORT="${SSH_PORT:-60999}"
ZERONEWS_SOURCE_IP="${ZERONEWS_SOURCE_IP:-}"
INSTALL_WIREGUARD_CONFIG="${INSTALL_WIREGUARD_CONFIG:-true}"
WIREGUARD_INTERFACE="${WIREGUARD_INTERFACE:-wg0}"
WIREGUARD_PORT="${WIREGUARD_PORT:-60001}"
WIREGUARD_CONFIG_SOURCE="${WIREGUARD_CONFIG_SOURCE:-$SCRIPT_DIR/${WIREGUARD_INTERFACE}.conf}"
WIREGUARD_CONFIG_TARGET="${WIREGUARD_CONFIG_TARGET:-/etc/wireguard/${WIREGUARD_INTERFACE}.conf}"
WIREGUARD_AUTOSTART="${WIREGUARD_AUTOSTART:-true}"
INSTALL_COREDNS="${INSTALL_COREDNS:-true}"
COREDNS_BINARY_SOURCE="${COREDNS_BINARY_SOURCE:-$SCRIPT_DIR/coredns}"
COREDNS_BINARY_TARGET="${COREDNS_BINARY_TARGET:-/usr/bin/coredns}"
COREDNS_COREFILE_SOURCE="${COREDNS_COREFILE_SOURCE:-$SCRIPT_DIR/Corefile}"
COREDNS_CONFIG_DIR="${COREDNS_CONFIG_DIR:-/etc/coredns}"
COREDNS_COREFILE_TARGET="${COREDNS_COREFILE_TARGET:-$COREDNS_CONFIG_DIR/Corefile}"
COREDNS_SERVICE_NAME="${COREDNS_SERVICE_NAME:-coredns}"

require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "Please run this script as root." >&2
		exit 1
	fi
}

disable_service_if_exists() {
	service_name="$1"
	if systemctl list-unit-files | grep -q "^${service_name}\\.service"; then
		systemctl disable --now "$service_name"
	fi
}

install_packages() {
	apt-get install -y --no-install-recommends "$@"
}

is_enabled() {
	case "$1" in
		1|true|TRUE|yes|YES|on|ON)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

require_file() {
	file_path="$1"
	if [ ! -f "$file_path" ]; then
		echo "Required file not found: $file_path" >&2
		exit 1
	fi
}

get_internet_interface() {
	internet_interface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
	if [ -z "$internet_interface" ]; then
		internet_interface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
	fi

	if [ -z "$internet_interface" ]; then
		echo "Unable to detect internet interface." >&2
		exit 1
	fi

	echo "$internet_interface"
}

setup_ssh_port() {
	sshd_config_file="/etc/ssh/sshd_config"

	if [ ! -f "$sshd_config_file" ]; then
		echo "SSH config file not found: $sshd_config_file" >&2
		exit 1
	fi

	if grep -Eq '^[[:space:]#]*Port[[:space:]]+' "$sshd_config_file"; then
		sed -i.bak -E "s/^[[:space:]#]*Port[[:space:]]+.*/Port $SSH_PORT/" "$sshd_config_file"
	else
		printf '\nPort %s\n' "$SSH_PORT" >> "$sshd_config_file"
	fi

	if command -v sshd >/dev/null 2>&1; then
		sshd -t
	fi

	if systemctl list-unit-files | grep -q '^ssh\.service'; then
		systemctl restart ssh
	elif systemctl list-unit-files | grep -q '^sshd\.service'; then
		systemctl restart sshd
	else
		echo "SSH service not found, skip restart." >&2
	fi
}

setup_iptables() {
	internet_interface=$(get_internet_interface)

	iptables -F
	iptables -X
	iptables -N zeronews

	if ! iptables -C INPUT -j zeronews 2>/dev/null; then
		iptables -A INPUT -j zeronews
	fi

	if [ -n "$ZERONEWS_SOURCE_IP" ]; then
		iptables -A zeronews -p tcp --dport "$SSH_PORT" -s "$ZERONEWS_SOURCE_IP" -j ACCEPT
		iptables -A zeronews -p tcp --dport "$SSH_PORT" -j DROP
	else
		echo "ZERONEWS_SOURCE_IP is empty, skip source-restricted rule for port $SSH_PORT."
	fi

    iptables -N firewall
    iptables -N firewall_allow
    iptables -N firewall_drop

    iptables -A firewall -j firewall_allow
    iptables -A firewall -j firewall_drop
    iptables -A firewall_allow -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    iptables -A firewall_allow -p icmp -j ACCEPT
    iptables -A firewall_allow -p udp -m udp --dport "$WIREGUARD_PORT" -j ACCEPT
	iptables -A firewall_allow -p tcp -m tcp --dport "$SSH_PORT" -j ACCEPT

    iptables -A firewall -j firewall_allow
    iptables -A firewall -j firewall_drop

    iptables -A firewall_drop -j DROP
    iptables -A INPUT -i "$internet_interface" -j firewall
	iptables -t nat -A POSTROUTING -o "$internet_interface" -j MASQUERADE
	systemctl enable netfilter-persistent
	netfilter-persistent save
}

setup_wireguard() {
	require_file "$WIREGUARD_CONFIG_SOURCE"

	install -d -m 0700 /etc/wireguard
	install -m 0600 "$WIREGUARD_CONFIG_SOURCE" "$WIREGUARD_CONFIG_TARGET"

	if is_enabled "$WIREGUARD_AUTOSTART"; then
		systemctl enable --now "wg-quick@${WIREGUARD_INTERFACE}"
	else
		systemctl restart "wg-quick@${WIREGUARD_INTERFACE}" || true
	fi
}

setup_coredns() {
	require_file "$COREDNS_BINARY_SOURCE"
	require_file "$COREDNS_COREFILE_SOURCE"

	install -m 0755 "$COREDNS_BINARY_SOURCE" "$COREDNS_BINARY_TARGET"
	install -d -m 0755 "$COREDNS_CONFIG_DIR"
	install -m 0644 "$COREDNS_COREFILE_SOURCE" "$COREDNS_COREFILE_TARGET"

	cat > "/etc/systemd/system/${COREDNS_SERVICE_NAME}.service" <<EOF
[Unit]
Description=CoreDNS
Documentation=https://coredns.io
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${COREDNS_BINARY_TARGET} -conf ${COREDNS_COREFILE_TARGET}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable --now "$COREDNS_SERVICE_NAME"
}

setup_docker_repo() {
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg" -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc

	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
		> /etc/apt/sources.list.d/docker.list
}

main() {
	require_root

	apt-get update

	disable_service_if_exists nftables
	disable_service_if_exists ufw

	install_packages \
		ca-certificates \
		curl \
		dnsmasq \
		ipset \
		ipset-persistent \
		iptables \
		iptables-persistent \
		wireguard

	setup_ssh_port

	if is_enabled "$ENABLE_IPTABLES"; then
		setup_iptables
	else
		echo "Skip iptables setup because ENABLE_IPTABLES=$ENABLE_IPTABLES"
	fi

	if is_enabled "$INSTALL_WIREGUARD_CONFIG"; then
		setup_wireguard
	else
		echo "Skip WireGuard config because INSTALL_WIREGUARD_CONFIG=$INSTALL_WIREGUARD_CONFIG"
	fi

	if is_enabled "$INSTALL_COREDNS"; then
		setup_coredns
	else
		echo "Skip CoreDNS setup because INSTALL_COREDNS=$INSTALL_COREDNS"
	fi

	setup_docker_repo
	apt-get update
	install_packages \
		containerd.io \
		docker-buildx-plugin \
		docker-ce \
		docker-ce-cli \
		docker-compose-plugin

	systemctl enable --now docker
}

main "$@"
