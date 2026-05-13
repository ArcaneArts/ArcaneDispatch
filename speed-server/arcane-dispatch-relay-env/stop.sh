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
