# ArcaneDispatch Remote Relay Setup

This folder is the operator package for a self-hosted ArcaneDispatch relay.
Use it for the SLC server or any Linux VPS with systemd.

Current SLC relay:

```text
Host: slc01.qualitynode.com
Primary client endpoint: udp://slc01.qualitynode.com:7777
Container UDP listener: :7777
Container TCP listener: :7778
Stats listener: 127.0.0.1:9090
```

If the target is Pterodactyl, use the portable environment flow in
[`pterodactyl/README.md`](pterodactyl/README.md). It creates a drop-in
folder with its own binary, data, logs, run files, and startup scripts.

## What the server needs

- Linux with systemd and sudo/root access.
- `UDP 7777` and `TCP 7778` reachable from the Mac, or alternate open ports.
- No other local process already bound to the same protocol/port pair.
- Go 1.22+ on the server, or a prebuilt Linux `dispatch-speed-server` binary copied with the installer.
- `/dev/net/tun` support for full tunnel egress.
- `nft`, `ip`, `iptables`, and `sysctl` available when NAT/TUN egress is enabled.

The relay stats port stays private on `127.0.0.1:9090`; reach it through SSH.

## Copy it to the server

From this repo on the Mac:

```bash
cd /Users/brianfopiano/Developer/RemoteGit/ArcaneArts/ArcaneDispatch
tar \
  --exclude 'speed-server/.DS_Store' \
  --exclude 'speed-server/dispatch-speed-server' \
  -czf /tmp/arcane-dispatch-speed-server.tar.gz \
  -C speed-server .
scp /tmp/arcane-dispatch-speed-server.tar.gz USER@SERVER:/tmp/
```

On the server:

```bash
sudo mkdir -p /opt/arcane-dispatch-speed-server
sudo tar -xzf /tmp/arcane-dispatch-speed-server.tar.gz -C /opt/arcane-dispatch-speed-server
cd /opt/arcane-dispatch-speed-server
```

If the server does not have Go installed, build a Linux binary on the Mac and copy that too:

```bash
cd /Users/brianfopiano/Developer/RemoteGit/ArcaneArts/ArcaneDispatch/speed-server
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /tmp/dispatch-speed-server .
scp /tmp/dispatch-speed-server USER@SERVER:/tmp/
```

Then on the server:

```bash
sudo install -m 0755 /tmp/dispatch-speed-server /opt/arcane-dispatch-speed-server/dispatch-speed-server
```

Use `GOARCH=arm64` instead of `amd64` if the server is ARM.

## Create a portable drop-in folder

For Pterodactyl or any host where you do not want systemd/global install,
create a self-contained runtime folder:

```bash
cd /Users/brianfopiano/Developer/RemoteGit/ArcaneArts/ArcaneDispatch/speed-server
./create-portable-env.sh \
  --public-host slc01.qualitynode.com \
  --udp-port 7777 \
  --tcp-port 7778 \
  --archive /tmp/arcane-dispatch-relay-env.tar.gz
```

Portable envs default to `RELAY_TUN_ENABLED=false` so they can boot inside a
normal Pterodactyl-style container. Add `--enable-tun` only when the target
environment has `/dev/net/tun` plus the needed network capabilities.

Upload and extract the archive. The runtime starts with:

```bash
./start.sh
```

It keeps all mutable state inside the folder:

```text
data/auth.json
data/server.key
logs/relay.log
run/dispatch-speed-server.pid
```

## Launch it on the SLC server

Use the ports you said are open:

```bash
cd /opt/arcane-dispatch-speed-server
sudo ./install-linux.sh \
  --public-host slc01.qualitynode.com \
  --udp-port 7777 \
  --tcp-port 7778 \
  --open-firewall \
  --log-level info
```

If the relay needs full VPN egress immediately, add NAT/TUN setup:

```bash
sudo ./install-linux.sh \
  --public-host slc01.qualitynode.com \
  --udp-port 7777 \
  --tcp-port 7778 \
  --open-firewall \
  --enable-nat \
  --log-level info
```

The installer prints:

- UDP endpoint, usually `udp://slc01.qualitynode.com:7777`.
- TCP endpoint, usually `tcp://slc01.qualitynode.com:7778`.
- server public key.
- client token, only when a new auth user is created.
- the `journalctl` command for logs.

Rerunning the installer updates the service and binary but preserves the existing server key and auth store.

## Logging

Service logs:

```bash
sudo journalctl -u dispatch-speed-server -f
```

Last boot logs:

```bash
sudo journalctl -u dispatch-speed-server -b --no-pager
```

Service state:

```bash
sudo systemctl status dispatch-speed-server --no-pager
```

Verbose relay debugging:

```bash
cd /opt/arcane-dispatch-speed-server
sudo ./install-linux.sh \
  --public-host slc01.qualitynode.com \
  --udp-port 7777 \
  --tcp-port 7778 \
  --log-level debug
sudo journalctl -u dispatch-speed-server -f
```

Debug logs include low-level relay events such as decode failures, sealed frame rejections, NAKs, egress byte counts, TUN commands, packet-device writes, and session reaping. Keep `info` for normal operation; use `debug` when validating the Mac client or diagnosing link problems.

## Stats

Open an SSH tunnel from the Mac:

```bash
ssh -L 9090:127.0.0.1:9090 USER@SERVER
```

Then from another local terminal:

```bash
curl http://127.0.0.1:9090/stats
```

Useful counters:

- `dispatch_packets_in`: bonded frames received by the relay.
- `dispatch_packets_bad`: frames that could not decode.
- `dispatch_packets_accepted`: valid frames accepted into sessions.
- `dispatch_bytes_egress`: reassembled client bytes written toward egress.
- `dispatch_packets_out`: reply packets framed back to the client.
- `dispatch_bytes_out`: reply bytes sent back toward the client.
- `dispatch_sessions`: active relay sessions.

If `packets_in` increases but `bytes_egress` does not, the client is reaching the relay but packet reassembly or tunnel egress is failing. If no counters move, check port forwarding, firewall rules, and whether the Mac is using the expected endpoint.

## Later app integration contract

When wiring the Flutter/macOS client to the remote relay, the app should collect and persist:

```text
Relay UDP endpoint: udp://slc01.qualitynode.com:7777
Relay TCP fallback: tcp://slc01.qualitynode.com:7778 if that allocation is exposed
Server public key: value printed by install-linux.sh
Client token: value printed by install-linux.sh
Bonded transport: enabled
```

The app-side policy should then set:

```text
Policy.serverUrl = udp://slc01.qualitynode.com:7777
Policy.serverToken = CLIENT_TOKEN
Policy.bondedTransport = true
```

If TCP fallback is represented separately, use `tcp://slc01.qualitynode.com:7778` only after confirming that `7778/tcp` is exposed by the Pterodactyl allocation. If the current policy only accepts one URL, start with UDP.

The macOS Network Extension should receive the same relay config through the tunnel policy or `TunnelChannel.setServer`, rebuild its relay socket pool, then open one relay path per eligible active interface. The expected validation path is:

```bash
curl ifconfig.io
```

With the tunnel active, that should return the SLC server public IP. During a large download or `iperf3` test, relay stats should show inbound frames and egress/reply counters moving.

## Quick failure map

- Installer says `UDP port 7777 is already in use`: the game server or another process already owns that UDP port.
- Relay log says `tun: false` but sessions open: the Mac is reaching the relay, but the server is not an internet egress path yet. Enable TUN/NAT on the host or move the relay to a VPS/bare-metal service with `/dev/net/tun`, forwarding, and NAT.
- Installer says `TCP port 7778 is already in use`: another process already owns that TCP port.
- Service fails immediately: check `journalctl -u dispatch-speed-server -b --no-pager`.
- Client cannot connect: verify router/provider forwarding for UDP 7777 and TCP 7778, then run `sudo ss -lunp | grep 7777` and `sudo ss -ltnp | grep 7778`.
- Stats works over SSH but no packets arrive: the relay process is alive, but external routing/firewall/client endpoint config is wrong.
- Packets arrive but internet egress fails: inspect TUN/NAT setup with `ip addr show dispatch0`, `sysctl net.ipv4.ip_forward`, and `sudo nft list ruleset`.
