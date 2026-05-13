# ArcaneDispatch Speed Server

This is the server-side relay for the ArcaneDispatch bonded transport.
Clients (the macOS Network Extension shipped with `arcane_dispatch`)
encrypt and split a single TCP/UDP flow across multiple internet links
and ship the resulting bonded frames to this relay; the relay
reassembles them and NAT44s the application traffic to the public
internet.

For the self-hosted SLC/game-server deployment flow, see
[`REMOTE_RELAY.md`](REMOTE_RELAY.md).
For Pterodactyl, see [`pterodactyl/README.md`](pterodactyl/README.md).

Current SLC endpoint for app integration:

```text
udp://slc01.qualitynode.com:7777
```

The protocol is documented inline in `bonded/framing.go`. The Dart and
Swift mirrors live in
[`lib/bonded/`](../lib/bonded/) and
[`macos/ArcaneDispatchTunnel/Bonded/`](../macos/ArcaneDispatchTunnel/Bonded/);
all three sides share the canned-bytes vectors in `bonded/framing_test.go`.

## Quick start (bare-metal systemd)

```bash
# Build a static binary on a Linux host with Go 1.22+:
CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
    -o dispatch-speed-server .

# Then follow the install steps in systemd/dispatch-speed-server.service.
```

The service starts the relay with the V1 TUN-backed path:

```bash
dispatch-speed-server serve \
  -udp :4430 \
  -tcp :4430 \
  -tun dispatch0 \
  -client-ip 10.42.0.2 \
  -server-ip 10.42.0.1 \
  -auth /var/lib/dispatch/auth.json \
  -key /var/lib/dispatch/server.key
```

The `adduser` output prints a bearer token — paste it into the macOS
client's relay config with an endpoint like `udp://VM_PUBLIC_IP:4430`.

Open UDP/TCP 4430 to the internet. Keep 9090 bound to localhost and reach
it with `ssh -L 9090:127.0.0.1:9090`.

## Docker

```bash
docker compose run --rm dispatch genkey  -out /data/server.key
docker compose run --rm dispatch adduser -auth /data/auth.json -user yourname
docker compose up -d
curl http://127.0.0.1:9090/stats
```

Docker remains useful for protocol smoke tests and auth bootstrap, but the
distroless/nonroot image does not include `ip`/`iptables` and does not create
the production TUN path.

## One-command Linux install

For a Linux VPS or self-hosted box with systemd, the installer builds or
installs the relay binary, creates the `dispatch` system user, preserves
existing keys/tokens, writes the systemd unit, and starts the service:

```bash
sudo ./install-linux.sh --public-host relay.example.com
```

On the SLC game server where the forwarded ports are `7777` and `7778`,
run it with explicit relay ports:

```bash
sudo ./install-linux.sh \
  --public-host slc01.qualitynode.com \
  --udp-port 7777 \
  --tcp-port 7778 \
  --log-level info
```

Add `--open-firewall` if the host uses `ufw` or `firewalld` and you want
the installer to open those two ports locally. The installed service creates
`dispatch0`, enables IPv4 forwarding, and adds MASQUERADE for
`10.42.0.2/32` at runtime.

For deeper debugging, rerun the installer with `--log-level debug` and
watch `journalctl -u dispatch-speed-server -f`.

## Portable runtime

For Pterodactyl or any host where the relay should live entirely inside one
folder, generate a drop-in runtime:

```bash
./create-portable-env.sh \
  --public-host slc01.qualitynode.com \
  --udp-port 7777 \
  --tcp-port 7778 \
  --archive /tmp/arcane-dispatch-relay-env.tar.gz
```

The generated folder contains `bin/`, `data/`, `logs/`, `run/`, `.env`, and
`start.sh`. Upload/extract it and run `./start.sh`. Portable envs default to
TUN off; add `--enable-tun` only when the container/host exposes
`/dev/net/tun` with the needed network capabilities.

If a game server is already bound to `UDP 7777` or `TCP 7778`, choose
different relay ports or move the game service first. The installer
checks for local listener conflicts before starting the relay.

## GCE deploy helper

`deploy-gce.sh` targets project `oraculartestdeployments` by default. It
creates the VM if needed, opens UDP/TCP relay firewall rules, uploads a fresh
Linux binary plus `install-linux.sh`, and runs the installer over SSH.

```bash
./deploy-gce.sh
```

Override `--zone`, `--instance`, `--machine-type`, `--udp-port`, or
`--tcp-port` when needed. The script creates billable GCE resources, so review
the flags before running it.

## Subcommands

| Subcommand | Purpose                                                  |
|------------|----------------------------------------------------------|
| `serve`    | Bind UDP/TCP/HTTP, run the relay loop.                   |
| `genkey`   | Generate a fresh ed25519 private key (Phase 9 will use). |
| `adduser`  | Add a bearer-token user to the auth store.               |
| `stats`    | `curl` the live counters endpoint and print to stdout.   |

Run `dispatch-speed-server <cmd> -h` for command-specific flags.

## Phase status

The relay is on the Phase 8 deliverable list of the master plan
(`plans/2026-05-11-speedify-clone-v1.md`). Current V1 slice:

- UDP listener + per-session reassembly.
- Linux TUN packet-device egress and reverse-path bonded frames.
- Reverse-path NAK frames for missing upstream sequences.
- Auth store (token table on disk).
- Prometheus-style `/stats` endpoint bound to localhost by default.
- Bare-metal systemd deploy artifact for GCE/VPS use.

Auth/Noise handshaking is still staged; keep the relay VM private except for
4430 until that work is finished. TCP accepts frames as a fallback listener,
but UDP is the first path wired to the TUN packet device. The wire format
will not change — that's locked in by the cross-language vector tests.

## Tests

```bash
go test ./...
```

Cross-language vector parity with the Dart/Swift sides is enforced by
`bonded/framing_test.go::TestEncode_CrossLanguageVectors`.
