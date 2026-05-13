#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
set -a
source ./.env
set +a

./bin/dispatch-speed-server stats -addr "http://${RELAY_STATS_ADDR}/stats" -timeout 3s
