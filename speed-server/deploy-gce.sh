#!/usr/bin/env bash
set -euo pipefail

project="oraculartestdeployments"
zone="us-central1-a"
instance="arcane-dispatch-relay"
machine_type="e2-small"
image_family="debian-12"
image_project="debian-cloud"
network_tag="arcane-dispatch-relay"
udp_port="4430"
tcp_port="4430"

usage() {
  cat <<EOF
Usage:
  ./deploy-gce.sh [options]

Options:
  --project ID          GCP project. Default: oraculartestdeployments.
  --zone ZONE           Compute zone. Default: us-central1-a.
  --instance NAME       VM name. Default: arcane-dispatch-relay.
  --machine-type TYPE   VM shape. Default: e2-small.
  --udp-port PORT       Public UDP relay port. Default: 4430.
  --tcp-port PORT       Public TCP relay port. Default: 4430.
  -h, --help            Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      project="${2:?missing value for --project}"
      shift 2
      ;;
    --zone)
      zone="${2:?missing value for --zone}"
      shift 2
      ;;
    --instance)
      instance="${2:?missing value for --instance}"
      shift 2
      ;;
    --machine-type)
      machine_type="${2:?missing value for --machine-type}"
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v gcloud >/dev/null 2>&1 || {
  echo "gcloud is required" >&2
  exit 1
}
command -v go >/dev/null 2>&1 || {
  echo "Go 1.22+ is required" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

gcloud config set project "$project" >/dev/null

if ! gcloud compute firewall-rules describe arcane-dispatch-relay-udp --project "$project" >/dev/null 2>&1; then
  gcloud compute firewall-rules create arcane-dispatch-relay-udp \
    --project "$project" \
    --allow "udp:${udp_port}" \
    --target-tags "$network_tag" \
    --description "ArcaneDispatch relay UDP"
fi

if ! gcloud compute firewall-rules describe arcane-dispatch-relay-tcp --project "$project" >/dev/null 2>&1; then
  gcloud compute firewall-rules create arcane-dispatch-relay-tcp \
    --project "$project" \
    --allow "tcp:${tcp_port}" \
    --target-tags "$network_tag" \
    --description "ArcaneDispatch relay TCP"
fi

if ! gcloud compute instances describe "$instance" --zone "$zone" --project "$project" >/dev/null 2>&1; then
  gcloud compute instances create "$instance" \
    --project "$project" \
    --zone "$zone" \
    --machine-type "$machine_type" \
    --image-family "$image_family" \
    --image-project "$image_project" \
    --tags "$network_tag" \
    --boot-disk-size 20GB
fi

(cd "$script_dir" && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o "$work_dir/dispatch-speed-server" .)
cp "$script_dir/install-linux.sh" "$work_dir/install-linux.sh"

gcloud compute scp \
  --project "$project" \
  --zone "$zone" \
  "$work_dir/dispatch-speed-server" \
  "$work_dir/install-linux.sh" \
  "${instance}:/tmp/"

public_ip="$(gcloud compute instances describe "$instance" \
  --project "$project" \
  --zone "$zone" \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"

gcloud compute ssh "$instance" \
  --project "$project" \
  --zone "$zone" \
  --command "sudo bash /tmp/install-linux.sh --binary /tmp/dispatch-speed-server --public-host ${public_ip} --udp-port ${udp_port} --tcp-port ${tcp_port}"
