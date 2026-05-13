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
