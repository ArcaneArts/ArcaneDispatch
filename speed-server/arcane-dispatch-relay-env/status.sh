#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
if [[ -f run/dispatch-speed-server.pid ]] && kill -0 "$(cat run/dispatch-speed-server.pid)" >/dev/null 2>&1; then
  echo "running pid=$(cat run/dispatch-speed-server.pid)"
else
  echo "stopped"
fi
tail -n 40 logs/relay.log 2>/dev/null || true
