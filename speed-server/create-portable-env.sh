#!/usr/bin/env bash
set -euo pipefail

env_dir="./arcane-dispatch-relay-env"
archive_path=""
binary_path=""
target_goos="linux"
target_goarch="amd64"
client_name="${USER:-arcane}"
public_host=""
udp_addr=":7777"
tcp_addr=":7778"
stats_addr="127.0.0.1:9090"
tun_name="dispatch0"
server_ip="10.42.0.1"
client_ip="10.42.0.2"
tun_mtu="1400"
log_level="info"
tun_enabled="false"
force="false"
work_dir=""

usage() {
  cat <<EOF
Usage:
  ./create-portable-env.sh [options]

Creates a drop-in ArcaneDispatch relay runtime folder with bin/, data/,
logs/, run/, .env, start.sh, stop.sh, status.sh, and stats.sh.

Options:
  --env-dir PATH          Output folder. Default: ./arcane-dispatch-relay-env.
  --archive PATH          Also create a .tar.gz archive for upload.
  --binary PATH           Use this prebuilt Linux binary instead of building.
  --goos GOOS             Build target OS. Default: linux.
  --goarch GOARCH         Build target architecture. Default: amd64.
  --client-name NAME      Auth user to create. Default: current user.
  --public-host HOST      Public DNS/IP printed in relay-info.txt.
  --udp-port PORT         UDP relay port. Default: 7777.
  --tcp-port PORT         TCP relay port. Default: 7778.
  --udp-addr ADDR         Full UDP listen address. Overrides --udp-port.
  --tcp-addr ADDR         Full TCP listen address. Overrides --tcp-port.
  --stats ADDR            Stats listen address. Default: 127.0.0.1:9090.
  --tun NAME              TUN device name. Default: dispatch0.
  --server-ip IP          Relay-side tunnel IP. Default: 10.42.0.1.
  --client-ip IP          Client-side tunnel IP. Default: 10.42.0.2.
  --tun-mtu MTU           TUN MTU. Default: 1400.
  --enable-tun            Enable /dev/net/tun egress in the generated env.
  --disable-tun           Run relay without /dev/net/tun egress. Default.
  --log-level LEVEL       debug, info, warn, or error. Default: info.
  --force                 Replace an existing env folder.
  -h, --help              Show this help.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[arcane-dispatch-env] %s\n' "$*" >&2
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-dir)
        env_dir="${2:?missing value for --env-dir}"
        shift 2
        ;;
      --archive)
        archive_path="${2:?missing value for --archive}"
        shift 2
        ;;
      --binary)
        binary_path="${2:?missing value for --binary}"
        shift 2
        ;;
      --goos)
        target_goos="${2:?missing value for --goos}"
        shift 2
        ;;
      --goarch)
        target_goarch="${2:?missing value for --goarch}"
        shift 2
        ;;
      --client-name)
        client_name="${2:?missing value for --client-name}"
        shift 2
        ;;
      --public-host)
        public_host="${2:?missing value for --public-host}"
        shift 2
        ;;
      --udp-port)
        udp_addr=":${2:?missing value for --udp-port}"
        shift 2
        ;;
      --tcp-port)
        tcp_addr=":${2:?missing value for --tcp-port}"
        shift 2
        ;;
      --udp-addr)
        udp_addr="${2:?missing value for --udp-addr}"
        shift 2
        ;;
      --tcp-addr)
        tcp_addr="${2:?missing value for --tcp-addr}"
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
      --disable-tun)
        tun_enabled="false"
        shift
        ;;
      --enable-tun)
        tun_enabled="true"
        shift
        ;;
      --log-level)
        log_level="${2:?missing value for --log-level}"
        shift 2
        ;;
      --force)
        force="true"
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

script_dir() {
  local source_path
  source_path="${BASH_SOURCE[0]}"
  while [[ -L "$source_path" ]]; do
    source_path="$(readlink "$source_path")"
  done
  cd "$(dirname "$source_path")" >/dev/null 2>&1
  pwd
}

validate_options() {
  case "$log_level" in
    debug|info|warn|error) ;;
    *) die "--log-level must be debug, info, warn, or error" ;;
  esac
  if [[ -e "$env_dir" && "$force" != "true" ]]; then
    die "$env_dir already exists; pass --force to replace it"
  fi
}

build_or_select_binary() {
  local dir
  local out
  dir="$(script_dir)"
  if [[ -n "$binary_path" ]]; then
    [[ -x "$binary_path" ]] || die "binary is not executable: $binary_path"
    printf '%s\n' "$binary_path"
    return
  fi
  command -v go >/dev/null 2>&1 || die "Go is required unless --binary is provided"
  out="$work_dir/dispatch-speed-server"
  info "building static ${target_goos}/${target_goarch} relay binary"
  (cd "$dir" && CGO_ENABLED=0 GOOS="$target_goos" GOARCH="$target_goarch" go build -trimpath -ldflags="-s -w" -o "$out" .)
  printf '%s\n' "$out"
}

write_env_file() {
  local tun_arg="-tun ${tun_name} -server-ip ${server_ip} -client-ip ${client_ip} -tun-mtu ${tun_mtu}"
  if [[ "$tun_enabled" != "true" ]]; then
    tun_arg=""
  fi
  cat > "$env_dir/.env" <<EOF
: "\${RELAY_PUBLIC_HOST:=${public_host}}"
: "\${RELAY_UDP_ADDR:=${udp_addr}}"
: "\${RELAY_TCP_ADDR:=${tcp_addr}}"
: "\${RELAY_STATS_ADDR:=${stats_addr}}"
: "\${RELAY_TUN_ENABLED:=${tun_enabled}}"
: "\${RELAY_TUN_ARGS:=${tun_arg}}"
: "\${RELAY_LOG_LEVEL:=${log_level}}"
: "\${RELAY_CLIENT_NAME:=${client_name}}"
EOF
}

write_start_script() {
  cat > "$env_dir/start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
set -a
source ./.env
set +a

mkdir -p logs run data

if [[ -f run/dispatch-speed-server.pid ]] && kill -0 "$(cat run/dispatch-speed-server.pid)" >/dev/null 2>&1; then
  echo "ArcaneDispatch relay is already running with pid $(cat run/dispatch-speed-server.pid)"
  exit 0
fi

if [[ ! -f data/server.key ]]; then
  echo "Generating relay server key"
  ./bin/dispatch-speed-server genkey -out ./data/server.key > relay-info.txt
  chmod 0600 ./data/server.key
fi

if [[ ! -f data/auth.json ]] || ! grep -Fq "\"name\": \"${RELAY_CLIENT_NAME}\"" data/auth.json 2>/dev/null; then
  echo "Creating relay auth user ${RELAY_CLIENT_NAME}"
  ./bin/dispatch-speed-server adduser -auth ./data/auth.json -user "${RELAY_CLIENT_NAME}" | tee -a relay-info.txt
  chmod 0600 ./data/auth.json
fi

args=(
  serve
  -udp "${RELAY_UDP_ADDR}"
  -tcp "${RELAY_TCP_ADDR}"
  -stats "${RELAY_STATS_ADDR}"
  -auth "./data/auth.json"
  -key "./data/server.key"
  -log-level "${RELAY_LOG_LEVEL}"
)

if [[ "${RELAY_TUN_ENABLED}" == "true" ]]; then
  read -r -a tun_args <<< "${RELAY_TUN_ARGS}"
  args+=("${tun_args[@]}")
fi

echo "Starting ArcaneDispatch relay"
echo "  UDP: ${RELAY_UDP_ADDR}"
echo "  TCP: ${RELAY_TCP_ADDR}"
echo "  stats: ${RELAY_STATS_ADDR}"
echo "  tun: ${RELAY_TUN_ENABLED}"
echo "  logs: logs/relay.log"

if [[ -n "${PTERODACTYL:-}" || -n "${SERVER_MEMORY:-}" ]]; then
  exec > >(tee -a logs/relay.log) 2>&1
  exec ./bin/dispatch-speed-server "${args[@]}"
fi

nohup ./bin/dispatch-speed-server "${args[@]}" >> logs/relay.log 2>&1 &
echo "$!" > run/dispatch-speed-server.pid
echo "ArcaneDispatch relay started with pid $(cat run/dispatch-speed-server.pid)"
EOF
  chmod +x "$env_dir/start.sh"
}

write_stop_script() {
  cat > "$env_dir/stop.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
if [[ ! -f run/dispatch-speed-server.pid ]]; then
  echo "ArcaneDispatch relay is not running"
  exit 0
fi

pid="$(cat run/dispatch-speed-server.pid)"
if kill -0 "$pid" >/dev/null 2>&1; then
  kill "$pid"
  for _ in 1 2 3 4 5; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      rm -f run/dispatch-speed-server.pid
      echo "ArcaneDispatch relay stopped"
      exit 0
    fi
    sleep 1
  done
  kill -9 "$pid" >/dev/null 2>&1 || true
fi
rm -f run/dispatch-speed-server.pid
echo "ArcaneDispatch relay stopped"
EOF
  chmod +x "$env_dir/stop.sh"
}

write_status_script() {
  cat > "$env_dir/status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
if [[ -f run/dispatch-speed-server.pid ]] && kill -0 "$(cat run/dispatch-speed-server.pid)" >/dev/null 2>&1; then
  echo "running pid=$(cat run/dispatch-speed-server.pid)"
else
  echo "stopped"
fi
tail -n 40 logs/relay.log 2>/dev/null || true
EOF
  chmod +x "$env_dir/status.sh"
}

write_stats_script() {
  cat > "$env_dir/stats.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
set -a
source ./.env
set +a

./bin/dispatch-speed-server stats -addr "http://${RELAY_STATS_ADDR}/stats" -timeout 3s
EOF
  chmod +x "$env_dir/stats.sh"
}

bootstrap_credentials() {
  local key_path="$env_dir/data/server.key"
  local auth_path="$env_dir/data/auth.json"
  local token_output
  if ! run_host_cli genkey -out "$key_path" > "$env_dir/relay-info.txt"; then
    {
      printf 'credentials: will be generated on first target start\n'
      printf 'client: %s\n' "$client_name"
    } > "$env_dir/relay-info.txt"
    return
  fi
  token_output="$(run_host_cli adduser -auth "$auth_path" -user "$client_name")"
  chmod 0600 "$key_path" "$auth_path"
  {
    printf 'client: %s\n' "$client_name"
    printf '%s\n' "$token_output"
  } >> "$env_dir/relay-info.txt"
}

run_host_cli() {
  local dir
  dir="$(script_dir)"
  if command -v go >/dev/null 2>&1 && [[ -f "$dir/go.mod" ]]; then
    (cd "$dir" && go run . "$@")
    return
  fi
  if [[ "$(uname -s)" == "Linux" && -x "$env_dir/bin/dispatch-speed-server" ]]; then
    "$env_dir/bin/dispatch-speed-server" "$@"
    return
  fi
  return 127
}

write_info() {
  local udp_port="${udp_addr##*:}"
  local tcp_port="${tcp_addr##*:}"
  {
    printf '\nRuntime folder: %s\n' "$env_dir"
    printf 'Start: ./start.sh\n'
    printf 'Stop: ./stop.sh\n'
    printf 'Status: ./status.sh\n'
    printf 'Stats: ./stats.sh\n'
    if [[ -n "$public_host" ]]; then
      printf 'Client UDP endpoint: udp://%s:%s\n' "$public_host" "$udp_port"
      printf 'Client TCP endpoint: tcp://%s:%s\n' "$public_host" "$tcp_port"
    else
      printf 'Client UDP endpoint: udp://SERVER_PUBLIC_IP_OR_DNS:%s\n' "$udp_port"
      printf 'Client TCP endpoint: tcp://SERVER_PUBLIC_IP_OR_DNS:%s\n' "$tcp_port"
    fi
    printf 'Logs: logs/relay.log\n'
  } >> "$env_dir/relay-info.txt"
}

write_archive() {
  [[ -n "$archive_path" ]] || return
  local parent
  local leaf
  parent="$(cd "$(dirname "$env_dir")" >/dev/null 2>&1 && pwd)"
  leaf="$(basename "$env_dir")"
  mkdir -p "$(dirname "$archive_path")"
  tar -czf "$archive_path" -C "$parent" "$leaf"
  info "created portable archive at $archive_path"
}

main() {
  parse_args "$@"
  validate_options
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  selected_binary="$(build_or_select_binary)"

  rm -rf "$env_dir"
  mkdir -p "$env_dir/bin" "$env_dir/data" "$env_dir/logs" "$env_dir/run"
  cp "$selected_binary" "$env_dir/bin/dispatch-speed-server"
  chmod +x "$env_dir/bin/dispatch-speed-server"

  write_env_file
  write_start_script
  write_stop_script
  write_status_script
  write_stats_script
  bootstrap_credentials
  write_info
  write_archive

  info "created portable relay environment at $env_dir"
  cat "$env_dir/relay-info.txt"
}

main "$@"
