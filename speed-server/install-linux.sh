#!/usr/bin/env bash
set -euo pipefail

service_name="dispatch-speed-server"
service_user="dispatch"
install_dir="/usr/local/bin"
data_dir="/var/lib/dispatch"
udp_port="4430"
tcp_port="4430"
stats_addr="127.0.0.1:9090"
tun_name="dispatch0"
server_ip="10.42.0.1"
client_ip="10.42.0.2"
tun_mtu="1400"
log_level="info"
client_name="${SUDO_USER:-${USER:-arcane}}"
public_host=""
public_interface="auto"
binary_path=""
open_firewall="false"
enable_nat="false"
start_service="true"
work_dir=""

usage() {
  cat <<EOF
Usage:
  sudo ./install-linux.sh [options]

Options:
  --client-name NAME       Auth user to create. Defaults to the sudo user.
  --public-host HOST       DNS name or public IP printed in the client config.
  --udp-port PORT          Public UDP relay port. Default: 4430.
  --tcp-port PORT          Public TCP relay port. Default: 4430.
  --stats ADDR             Stats bind address. Default: 127.0.0.1:9090.
  --tun NAME               TUN device name. Default: dispatch0.
  --server-ip IP           Relay-side tunnel IP. Default: 10.42.0.1.
  --client-ip IP           Client-side tunnel IP. Default: 10.42.0.2.
  --tun-mtu MTU            TUN MTU. Default: 1400.
  --log-level LEVEL        Relay log level: debug, info, warn, error. Default: info.
  --data-dir PATH          State directory. Default: /var/lib/dispatch.
  --install-dir PATH       Binary install directory. Default: /usr/local/bin.
  --service-user USER      System user. Default: dispatch.
  --service-name NAME      systemd service name. Default: dispatch-speed-server.
  --binary PATH            Install this prebuilt Linux binary instead of building.
  --public-interface IFACE Interface used for optional NAT. Default: auto.
  --open-firewall          Open UDP/TCP relay ports with ufw or firewalld when present.
  --enable-nat             Also install persistent nftables NAT for 10.42.0.0/24.
  --no-start               Install files but do not start or restart the service.
  -h, --help               Show this help.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[arcane-dispatch-install] %s\n' "$*" >&2
}

need_root() {
  if [[ "$(id -u)" != "0" ]]; then
    die "run this installer with sudo"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

run_as_service_user() {
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$service_user" -- "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo -u "$service_user" "$@"
    return
  fi
  die "missing runuser or sudo for service-user commands"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --client-name)
        client_name="${2:?missing value for --client-name}"
        shift 2
        ;;
      --public-host)
        public_host="${2:?missing value for --public-host}"
        shift 2
        ;;
      --udp-port)
        udp_port="${2:?missing value for --udp-port}"
        shift 2
        ;;
      --tcp-port)
        tcp_port="${2:?missing value for --tcp-port}"
        shift 2
        ;;
      --stats)
        stats_addr="${2:?missing value for --stats}"
        shift 2
        ;;
      --tun)
        tun_name="${2:?missing value for --tun}"
        shift 2
        ;;
      --server-ip)
        server_ip="${2:?missing value for --server-ip}"
        shift 2
        ;;
      --client-ip)
        client_ip="${2:?missing value for --client-ip}"
        shift 2
        ;;
      --tun-mtu)
        tun_mtu="${2:?missing value for --tun-mtu}"
        shift 2
        ;;
      --log-level)
        log_level="${2:?missing value for --log-level}"
        shift 2
        ;;
      --data-dir)
        data_dir="${2:?missing value for --data-dir}"
        shift 2
        ;;
      --install-dir)
        install_dir="${2:?missing value for --install-dir}"
        shift 2
        ;;
      --service-user)
        service_user="${2:?missing value for --service-user}"
        shift 2
        ;;
      --service-name)
        service_name="${2:?missing value for --service-name}"
        shift 2
        ;;
      --binary)
        binary_path="${2:?missing value for --binary}"
        shift 2
        ;;
      --public-interface)
        public_interface="${2:?missing value for --public-interface}"
        shift 2
        ;;
      --open-firewall)
        open_firewall="true"
        shift
        ;;
      --enable-nat)
        enable_nat="true"
        shift
        ;;
      --no-start)
        start_service="false"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

detect_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "this installer must run on Linux"
  [[ -d /run/systemd/system ]] || die "systemd is required"
  case "$log_level" in
    debug|info|warn|error) ;;
    *) die "--log-level must be debug, info, warn, or error" ;;
  esac
}

script_dir() {
  local source_path
  source_path="${BASH_SOURCE[0]}"
  while [[ -L "$source_path" ]]; do
    source_path="$(readlink "$source_path")"
  done
  cd "$(dirname "$source_path")" >/dev/null 2>&1
  pwd
}

build_or_select_binary() {
  local dir
  local temp_dir
  dir="$(script_dir)"
  if [[ -n "$binary_path" ]]; then
    [[ -x "$binary_path" ]] || die "binary is not executable: $binary_path"
    info "using prebuilt relay binary $binary_path"
    printf '%s\n' "$binary_path"
    return
  fi
  if command -v go >/dev/null 2>&1 && [[ -f "$dir/go.mod" ]]; then
    temp_dir="$work_dir/build"
    mkdir -p "$temp_dir"
    info "building Linux relay binary from $dir"
    (cd "$dir" && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o "$temp_dir/dispatch-speed-server" .)
    printf '%s\n' "$temp_dir/dispatch-speed-server"
    return
  fi
  if [[ -x "$dir/dispatch-speed-server" ]]; then
    printf '%s\n' "$dir/dispatch-speed-server"
    return
  fi
  die "provide --binary or install Go 1.22+ so the relay can be built"
}

ensure_user_and_dirs() {
  local nologin="/usr/sbin/nologin"
  if [[ ! -x "$nologin" && -x /sbin/nologin ]]; then
    nologin="/sbin/nologin"
  fi
  if ! id "$service_user" >/dev/null 2>&1; then
    info "creating system user $service_user"
    useradd --system --home "$data_dir" --shell "$nologin" "$service_user"
  fi
  info "ensuring state directory $data_dir"
  install -d -o "$service_user" -g "$service_user" -m 0700 "$data_dir"
  install -d -m 0755 "$install_dir"
}

install_binary() {
  local selected_binary="$1"
  info "installing relay binary to $install_dir/dispatch-speed-server"
  install -m 0755 "$selected_binary" "$install_dir/dispatch-speed-server"
}

ensure_key_and_auth() {
  local key_path="$data_dir/server.key"
  local auth_path="$data_dir/auth.json"
  local add_output=""
  if [[ ! -f "$key_path" ]]; then
    info "generating server key at $key_path"
    run_as_service_user "$install_dir/dispatch-speed-server" genkey -out "$key_path" >"$work_dir/dispatch-server-key.out"
  else
    info "preserving existing server key at $key_path"
  fi
  if [[ ! -f "$auth_path" ]] || ! grep -Fq "\"name\": \"${client_name}\"" "$auth_path" 2>/dev/null; then
    info "creating relay auth user $client_name"
    set +e
    add_output="$(run_as_service_user "$install_dir/dispatch-speed-server" adduser -auth "$auth_path" -user "$client_name" 2>&1)"
    local add_status=$?
    set -e
    if [[ "$add_status" -eq 0 ]]; then
      printf '%s\n' "$add_output" > "$work_dir/dispatch-client-token.out"
    elif [[ "$add_output" == *"already exists"* ]]; then
      printf 'existing-user\n' > "$work_dir/dispatch-client-token.out"
    else
      die "$add_output"
    fi
  else
    info "preserving existing relay auth user $client_name"
    printf 'existing-user\n' > "$work_dir/dispatch-client-token.out"
  fi
  chown "$service_user:$service_user" "$key_path" "$auth_path"
  chmod 0600 "$key_path" "$auth_path"
}

write_service() {
  local unit_path="/etc/systemd/system/${service_name}.service"
  info "writing systemd unit $unit_path"
  cat > "$unit_path" <<EOF
[Unit]
Description=ArcaneDispatch Bonded Speed Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${service_user}
Group=${service_user}
WorkingDirectory=${data_dir}
ExecStart=${install_dir}/dispatch-speed-server serve -udp :${udp_port} -tcp :${tcp_port} -tun ${tun_name} -server-ip ${server_ip} -client-ip ${client_ip} -tun-mtu ${tun_mtu} -stats ${stats_addr} -auth ${data_dir}/auth.json -key ${data_dir}/server.key -log-level ${log_level}
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=false
ProtectKernelTunables=false
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=true
RestrictRealtime=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
ReadWritePaths=${data_dir}
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=60
StartLimitBurst=5
LimitNOFILE=65536
TasksMax=4096

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$service_name" >/dev/null
}

detect_public_interface() {
  if [[ "$public_interface" != "auto" ]]; then
    printf '%s\n' "$public_interface"
    return
  fi
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

configure_nat() {
  [[ "$enable_nat" == "true" ]] || return
  require_command ip
  require_command nft
  local iface
  iface="$(detect_public_interface)"
  [[ -n "$iface" ]] || die "could not detect public interface; pass --public-interface"
  info "enabling IPv4 forwarding and nftables NAT through $iface"
  install -d -m 0755 /etc/sysctl.d
  printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-arcane-dispatch.conf
  sysctl --system >/dev/null
  nft list table ip dispatch >/dev/null 2>&1 || nft add table ip dispatch
  nft list chain ip dispatch postrouting >/dev/null 2>&1 || nft add chain ip dispatch postrouting '{' type nat hook postrouting priority srcnat ';' policy accept ';' '}'
  if ! nft list chain ip dispatch postrouting | grep -q '10.42.0.0/24'; then
    nft add rule ip dispatch postrouting ip saddr 10.42.0.0/24 oifname "$iface" masquerade
  fi
}

configure_firewall() {
  [[ "$open_firewall" == "true" ]] || return
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    info "opening relay ports with ufw"
    ufw allow "${udp_port}/udp"
    ufw allow "${tcp_port}/tcp"
    return
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    info "opening relay ports with firewalld"
    firewall-cmd --permanent --add-port="${udp_port}/udp"
    firewall-cmd --permanent --add-port="${tcp_port}/tcp"
    firewall-cmd --reload
    return
  fi
  printf 'firewall: no active ufw/firewalld detected; open UDP %s and TCP %s manually if needed\n' "$udp_port" "$tcp_port"
}

check_port_conflicts() {
  command -v ss >/dev/null 2>&1 || return
  info "checking local port conflicts for UDP ${udp_port} and TCP ${tcp_port}"
  if ss -H -lun "sport = :${udp_port}" | grep -q .; then
    die "UDP port ${udp_port} is already in use; choose another --udp-port or stop the conflicting service"
  fi
  if ss -H -ltn "sport = :${tcp_port}" | grep -q .; then
    die "TCP port ${tcp_port} is already in use; choose another --tcp-port or stop the conflicting service"
  fi
}

stop_existing_service_for_update() {
  [[ "$start_service" == "true" ]] || return
  systemctl is-active --quiet "$service_name" || return
  info "stopping existing $service_name before update"
  systemctl stop "$service_name"
}

start_and_probe() {
  [[ "$start_service" == "true" ]] || return
  info "starting $service_name"
  systemctl restart "$service_name"
  for _ in 1 2 3 4 5; do
    if "$install_dir/dispatch-speed-server" stats -addr "http://${stats_addr}/stats" -timeout 2s >"$work_dir/dispatch-stats.out" 2>"$work_dir/dispatch-stats.err"; then
      return
    fi
    sleep 1
  done
  systemctl status "$service_name" --no-pager || true
  cat "$work_dir/dispatch-stats.err" >&2 || true
  die "service started but stats did not respond"
}

guess_public_host() {
  if [[ -n "$public_host" ]]; then
    printf '%s\n' "$public_host"
    return
  fi
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}'
}

print_summary() {
  local host
  local pubkey
  local token
  host="$(guess_public_host)"
  [[ -n "$host" ]] || host="<server-public-ip-or-dns>"
  pubkey="$(tail -c 32 "$data_dir/server.key" | base64 | tr -d '\n')"
  token="$(cat "$work_dir/dispatch-client-token.out" 2>/dev/null || true)"
  printf '\nArcaneDispatch relay installed.\n'
  printf 'Service: %s\n' "$service_name"
  printf 'Endpoint UDP: udp://%s:%s\n' "$host" "$udp_port"
  printf 'Endpoint TCP: tcp://%s:%s\n' "$host" "$tcp_port"
  printf 'Stats: ssh -L 9090:%s %s\n' "$stats_addr" "$host"
  printf 'Server public key: %s\n' "$pubkey"
  if [[ "$token" == "existing-user" ]]; then
    printf 'Client token: existing auth user "%s"; token was not reprinted\n' "$client_name"
  else
    printf 'Client token: %s\n' "$token"
  fi
  printf 'Logs: journalctl -u %s -f\n' "$service_name"
}

main() {
  parse_args "$@"
  need_root
  detect_linux
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  require_command systemctl
  require_command install
  require_command ip
  require_command iptables
  require_command sysctl
  local selected_binary
  selected_binary="$(build_or_select_binary)"
  ensure_user_and_dirs
  install_binary "$selected_binary"
  ensure_key_and_auth
  stop_existing_service_for_update
  check_port_conflicts
  write_service
  configure_nat
  configure_firewall
  start_and_probe
  print_summary
}

main "$@"
