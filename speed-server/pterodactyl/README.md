# Pterodactyl Deployment

This folder contains a custom ArcaneDispatch relay egg plus the notes needed
to run the portable relay environment inside a Pterodactyl server.

Current SLC relay data:

```text
Host: slc01.qualitynode.com
Primary endpoint for app integration: udp://slc01.qualitynode.com:7777
UDP listener: :7777
TCP listener: :7778
Stats listener: 127.0.0.1:9090
```

## Reality check

The relay process itself is easy to run in Pterodactyl. Full VPN egress is the
part that may need node-level privileges:

- `/dev/net/tun` passed into the container.
- `NET_ADMIN` and `NET_RAW` capabilities.
- NAT/forwarding allowed by the node host.

Without those, the relay can still start and accept frames, but it cannot be
the final internet-exit VPN path.

If the startup log includes `tun: false`, sessions opening only proves the Mac
can reach the relay port. System-wide internet through ArcaneDispatch requires
the relay to start with `tun: true` and NAT/forwarding available on the host.

## Egg

Import:

```text
pterodactyl/egg-arcane-dispatch-relay.json
```

The egg is intentionally simple:

- Docker image: `ghcr.io/ptero-eggs/yolks:debian`.
- Startup: `./start.sh`.
- Install script: creates the expected folders only.
- Configurable variables: UDP addr, TCP addr, stats addr, TUN enabled, TUN args, log level.

If you do not want a custom egg, a generic Debian/binary egg also works as
long as the startup command is:

```bash
./start.sh
```

## Allocations

Allocate both TCP and UDP for both available ports if the panel allows it:

```text
7777/tcp
7777/udp
7778/tcp
7778/udp
```

Current defaults use:

```text
UDP relay: :7777
TCP fallback: :7778
```

The extra protocol allocations are fine to keep. They let us swap or add
fallback behavior later without changing the panel allocation.

## Create the drop-in environment

From the Mac:

```bash
cd /Users/brianfopiano/Developer/RemoteGit/ArcaneArts/ArcaneDispatch/speed-server
chmod +x create-portable-env.sh
./create-portable-env.sh \
  --public-host slc01.qualitynode.com \
  --udp-port 7777 \
  --tcp-port 7778 \
  --log-level info \
  --archive /tmp/arcane-dispatch-relay-env.tar.gz
```

That default starts with TUN disabled so a normal Pterodactyl container can
boot. If the node has TUN and network capabilities configured, add
`--enable-tun` or set `RELAY_TUN_ENABLED=true` in the panel variables.

Upload `/tmp/arcane-dispatch-relay-env.tar.gz` to the Pterodactyl server
files, extract it, and move the contents of `arcane-dispatch-relay-env/` to
the server root so `start.sh` is at:

```text
/home/container/start.sh
```

Expected layout:

```text
bin/dispatch-speed-server
data/auth.json
data/server.key
logs/
run/
.env
relay-info.txt
start.sh
stop.sh
status.sh
stats.sh
```

## Panel variables

The generated `.env` provides defaults, but Pterodactyl variables override
them.

Recommended initial values:

```text
RELAY_UDP_ADDR=:7777
RELAY_TCP_ADDR=:7778
RELAY_STATS_ADDR=127.0.0.1:9090
RELAY_TUN_ENABLED=false
RELAY_TUN_ARGS=-tun dispatch0 -server-ip 10.42.0.1 -client-ip 10.42.0.2 -tun-mtu 1400
RELAY_LOG_LEVEL=info
RELAY_CLIENT_NAME=arcane
```

Use `RELAY_LOG_LEVEL=debug` while validating the Mac client.

Only set `RELAY_TUN_ENABLED=true` after the Pterodactyl node is configured
with TUN and network capabilities. If it is enabled without those privileges,
startup should fail with a clear `/dev/net/tun` or permission error.

## Running

The panel starts the relay with `./start.sh`.

From the Pterodactyl console, useful commands are:

```bash
./status.sh
./stats.sh
tail -n 200 logs/relay.log
```

The generated `relay-info.txt` contains the server public key, token, and
client endpoint values needed when the Mac app is wired to the remote relay.
If credentials could not be generated on the Mac because only a Linux binary
was available, `start.sh` generates them on the first container start and
appends them to `relay-info.txt`.

## Later app wiring

Use values from `relay-info.txt`:

```text
Policy.serverUrl = udp://slc01.qualitynode.com:7777
Policy.serverToken = token from relay-info.txt
Policy.bondedTransport = true
```

If TCP fallback is added as a separate app field later, point it at:

```text
tcp://slc01.qualitynode.com:7778
```

Only use that TCP fallback after confirming the Pterodactyl allocation exposes
`7778/tcp`. The UDP app endpoint is the one to wire first.
