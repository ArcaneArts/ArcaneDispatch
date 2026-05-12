# ArcaneDispatch Speed Server

This is the server-side relay for the ArcaneDispatch bonded transport.
Clients (the macOS Network Extension shipped with `arcane_dispatch`)
encrypt and split a single TCP/UDP flow across multiple internet links
and ship the resulting bonded frames to this relay; the relay
reassembles them and NAT44s the application traffic to the public
internet.

The protocol is documented inline in `bonded/framing.go`. The Dart and
Swift mirrors live in
[`lib/bonded/`](../lib/bonded/) and
[`macos/ArcaneDispatchTunnel/Bonded/`](../macos/ArcaneDispatchTunnel/Bonded/);
all three sides share the canned-bytes vectors in `bonded/framing_test.go`.

## Quick start (Docker)

```bash
# 1. One-shot bootstrap (creates ./data/server.key + auth.json)
docker compose run --rm dispatch genkey  -out /data/server.key
docker compose run --rm dispatch adduser -auth /data/auth.json -user yourname

# 2. Run the relay
docker compose up -d

# 3. Live counters
curl http://127.0.0.1:9090/stats
```

The `adduser` output prints a bearer token — paste it into the macOS
client's "Speed Server" pane (Phase 8.12 wires the
`setServer(url, token)` MethodChannel; until then it's a TODO).

## Quick start (bare-metal systemd)

```bash
# Build a static binary on a Linux host with Go 1.22+:
CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
    -o dispatch-speed-server .

# Then follow the install steps in systemd/dispatch-speed-server.service.
```

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
(`plans/2026-05-11-speedify-clone-v1.md`). Phase 8 ships:

- UDP listener + per-session reassembly (NAT44 egress is logged-only).
- Auth store (token table on disk).
- Prometheus-style `/stats` endpoint.
- Container + systemd deploy artifacts.

Phase 9 layers Noise IK on top, Phase 11 wires real NAT44 + TCP/TLS
fallback. The wire format will not change — that's locked in by the
cross-language vector tests.

## Tests

```bash
go test ./...
```

Cross-language vector parity with the Dart/Swift sides is enforced by
`bonded/framing_test.go::TestEncode_CrossLanguageVectors`.
