# Plan: Arcane Dispatch → Speedify-Class Multi-WAN Bonding VPN (v1)

**Date:** 2026-05-11
**Codebase:** `arcane_dispatch` (Flutter/Dart macOS menu-bar app)
**Goal:** Evolve the current Dart SOCKS load-balancer into an open-source, system-wide,
packet-level bonding VPN that matches Speedify feature-for-feature on macOS first,
then iOS/Linux/Windows.
**Scope of this plan:** End-to-end roadmap, architecture, phased delivery, file/component
contracts, verification gates. No code changes are made here.

---

## 0. Executive Summary

`arcane_dispatch` today is a **connection-level** SOCKS4/5 proxy that picks an outbound
local IP per new TCP connection using weighted round-robin (`lib/core/socks_proxy_server.dart:234-269`,
`lib/core/weighted_address.dart:168-209`). Speedify is a **packet-level** bonding VPN with
an encrypted custom transport to a relay server and a system-wide TUN. Closing the gap
requires four orthogonal new systems:

1. A **macOS Network Extension** (`NEPacketTunnelProvider` as a System Extension) that
   owns the TUN device and the packet-scheduling engine.
2. A **bonded transport protocol** (UDP-first, TCP/HTTPS fallback) with per-packet
   sequencing, encryption, reassembly, and per-link congestion estimation.
3. A **relay server** (Speed Server) that terminates the bonded transport and bridges to
   the internet, plus a peer-to-peer **Local Mode** that uses no relay.
4. A **control plane** in the Flutter app for per-link health metrics, priority/limits,
   bonding mode selection, kill-switch, streaming detection, captive portal assist, and
   Pair & Share.

The Dart codebase keeps the proxy engine (`lib/core/socks_proxy_server.dart`) as a
**legacy/fallback** transport (still useful for selective per-app routing and CI tests),
but all new functionality lives behind an abstraction (`Transport`) so the same UI/
metrics path drives either engine.

---

## 1. Current State (Anchor)

### 1.1 Capabilities present
| Capability | Source |
| --- | --- |
| SOCKS5 NOAUTH `CONNECT` + SOCKS4/4a `CONNECT` | `lib/core/socks_proxy_server.dart:138-232` |
| Weighted RR dispatch per IPv4/IPv6 family | `lib/core/weighted_address.dart:168-230` |
| Interface enumeration + bind probe | `lib/core/network_interface_repository.dart:25-96` |
| Hive-persisted settings | `lib/core/dispatch_settings.dart:1-78` |
| Menu-bar UI + tray (Swift + Dart) | `lib/platform/window_controller.dart:1-187`, `macos/Runner/DispatchTrayController.swift:1-182` |
| LaunchAgent autostart | `lib/platform/startup_service.dart:1-102` |
| Basic event log | `lib/core/proxy_event.dart:1-36`, `lib/screen/home_screen.dart:384-453` |
| Unit + widget tests | `test/core/*`, `test/widget/*` |

### 1.2 Capabilities absent
No TUN/VPN, no encryption, no packet scheduling, no failover beyond TCP `Socket.connect`
retry, no metrics, no priorities/limits, no streaming detection, no Pair & Share, no
captive portal handling, no kill switch, no server-side reassembly.

### 1.3 macOS entitlement state
Sandbox is **off** in `macos/Runner/DebugProfile.entitlements:5-6` and `Release.entitlements:5-6`.
This must change for a Network Extension: the container app and the extension each need
their own (different) entitlement sets, including `com.apple.developer.networking.networkextension`
with the `packet-tunnel-provider` value, an App Group, and Apple Developer team approval
(non-self-signable).

---

## 2. Target State (Speedify 1:1)

| Feature | Acceptance criteria |
| --- | --- |
| System-wide TUN | All traffic from all apps flows through the bonded tunnel by default (with split-tunnel allow-list). |
| Packet-level bonding | A single TCP flow's packets are striped across ≥ 2 physical links and reassembled on the server; iperf3 shows aggregate throughput ≥ 1.5× the fastest link in Speed mode. |
| Bonding modes | `Speed`, `Redundant`, `Streaming` (low-latency QoS), `Local` (no relay) selectable at runtime. |
| Real-time metrics | Per-link RTT, jitter, loss%, MOS, up/down throughput; 1 Hz refresh; ≤ 200 ms staleness in UI. |
| Smart priorities | Per-link `Primary` / `Secondary` / `Backup` / `Never`, per-link speed cap and monthly data cap with rollover date. |
| Gapless failover | Active link removal under load drops < 3 packets and < 250 ms RTT spike; TCP sessions survive. |
| Encryption | ChaCha20-Poly1305 (default) or AES-256-GCM (HW-accelerated); X25519 ECDH; Noise IK or WireGuard-style handshake; per-session keys rotated every 1 GiB or 30 min. |
| Auto protocol switch | Transport degrades UDP → TCP → HTTPS (port 443) on the same link without re-handshake when probes detect blocking. |
| Streaming/video QoS | Flows matching well-known streaming/video-call signatures (SNI list, port heuristics) get a dedicated low-latency queue and the Streaming mode scheduler. |
| Pair & Share | Phone-as-cellular-uplink: peer joins via Bonjour + on-device hotspot or local relay; appears as a virtual link. |
| Captive portal | Each link is health-probed via http://captive.apple.com; portal detection surfaces a "Solve" action (system browser) without dropping the tunnel; portal link is held in `Backup` until resolved. |
| Speed Server | Reference open-source relay reachable from anywhere; client can also pin a private/self-hosted server URL. |
| Local mode | Two devices on the same LAN can bond without a relay (one acts as the egress). |
| Per-connection stats | UI shows per-flow link assignment and bytes for the last 60 s. |
| Universal app support | No client configuration; works for any app/socket via TUN. |
| Kill switch | When the tunnel is meant to be up but is down, all non-allow-listed traffic is blocked; `pf` / route nullification used. |

---

## 3. Gap Matrix (current → target)

| Layer | Current | Target | Action |
| --- | --- | --- | --- |
| Tunnel | None (SOCKS opt-in) | `NEPacketTunnelProvider` System Extension | New target `ArcaneDispatchTunnel.appex` |
| Engine language | Dart only | Dart UI + Swift extension + Rust/Go relay | Add Swift sources under `macos/ArcaneDispatchTunnel/`, optional Rust core via FFI |
| Routing unit | TCP connection | IP packet | New scheduler & reassembler |
| Health | TCP `connect` success | Multi-metric probe loop | New `LinkProbe` service |
| Crypto | None | Noise + ChaCha20-Poly1305 / AES-GCM | New `crypto/` module |
| Failover | None | Sub-second, gapless | New `LinkSupervisor` |
| Config | List of strings | Typed `Link` + `Policy` graph | New models, Hive schema migration |
| UI | Single page | Dashboard + per-link cards + graphs | New screens & widgets |
| Tests | Dart only | Dart + Swift XCTest + relay integration tests | New CI matrix |

---

## 4. Target Architecture

```
+--------------------------- Container App (Flutter) ---------------------------+
| lib/                                                                          |
|   core/         models (Link, Policy, Mode, Metrics, FlowStat)                |
|   transport/    Transport interface { SocksTransport, BondedTunnelTransport } |
|   probes/       LinkProbeService (ICMP-ish + DNS + HTTP)                      |
|   policy/       PolicyEngine (priority, limits, caps, kill-switch)            |
|   bridge/       NEManagerChannel  ----MethodChannel----+                      |
|   screen/       Dashboard, LinkCard, FlowList, Logs    |                      |
+--------------------------------------------------------|----------------------+
                                                         |
                                                  XPC + UserDefaults
                                                  (App Group)
                                                         |
+---------------- ArcaneDispatchTunnel.appex (Swift + Rust core) ---------------+
|  PacketTunnelProvider                                                         |
|    - setTunnelNetworkSettings(IPv4/IPv6, DNS, MTU, routes)                    |
|    - reads IP packets from `packetFlow.readPackets`                           |
|    - writes IP packets to `packetFlow.writePackets`                           |
|  Engine (Rust via FFI, or pure Swift v1):                                     |
|    Splitter    -> assigns packet to link by mode + weights + EWMA throughput  |
|    Cipher      -> wraps frame: [hdr|seq|nonce|ct|tag]                         |
|    LinkIO      -> per physical interface UDP/TCP/HTTPS socket                 |
|    Probes      -> in-band keepalives + per-link latency/jitter/loss           |
|    Reassembler -> reorder buffer, gap timer, NAK/SACK                         |
|    QoS         -> 2 queues (RT, BE); Streaming flows go RT                    |
|    KillSwitch  -> if disabled or starved, drop egress                         |
+-------------------------------------------------------------------------------+
                                                         |
                                          UDP/TCP/HTTPS (multipath)
                                                         |
+--------------------------- Speed Server (separate repo) ----------------------+
|  Listens 443/udp + 443/tcp + 443/tls; reassembles by client-session;          |
|  egresses to internet via NAT44/NAT66; rate-limits; auth via token.           |
|  Reference impl: Go (preferred) or Rust; deployable single binary + Docker.   |
+-------------------------------------------------------------------------------+
```

Notes:
* Dart never sees packets. The extension is the only process touching the TUN.
* Dart receives **stats deltas** at 1 Hz over a Darwin notification + shared
  `UserDefaults(suiteName: "group.art.arcane.dispatch")`.
* Dart pushes **policy changes** as JSON blobs to a wake-up notification + shared file.
* Bonded transport is a separate library and is link-agnostic; LinkIO maps each policy
  link to a `(localAddress, transport, optionalServerURL)` tuple.

---

## 5. Phased Roadmap

Each phase has a single user-visible outcome and is independently shippable. Phases 1–4
land while still using SOCKS as the egress (no tunnel yet). Phase 5 introduces the
extension. Phases 6–8 deliver "real" Speedify behavior. Phases 9–16 are polish + parity.

| # | Phase | Outcome | Risk |
| --- | --- | --- | --- |
| 1 | Core refactor | Typed Link/Policy/Mode models; Transport interface; legacy SOCKS behind it | low |
| 2 | Live per-link metrics | RTT/jitter/loss/throughput shown in UI; persisted history (60 s) | low |
| 3 | Priority + limits engine | Primary/Secondary/Backup/Never + speed cap + data cap honored by SOCKS scheduler | low |
| 4 | Connection-level failover & kill switch (SOCKS scope) | Flows retried on alt link; kill-switch blocks SOCKS when no link healthy | medium |
| 5 | Network Extension scaffold | App + extension bundle, App Group, NEVPNManager wiring, "Connect" button toggles a tunnel that just NATs locally | high (entitlements, signing) |
| 6 | Local IP forwarding through tunnel | All system traffic exits via the chosen single best link; UI shows real per-app stats | medium |
| 7 | Bonded transport (lab/local) | Two-link striping client+server (loopback on the same Mac); reassembly verified | high |
| 8 | Speed Server reference | Public-internet server binary deploys; auth + relay; client connects with token | high |
| 9 | Encryption + handshake | Noise IK / WireGuard-style; key rotation; replay protection | medium |
| 10 | Real bonded modes | Speed / Redundant / Streaming schedulers operational | medium |
| 11 | Auto protocol switch | UDP → TCP → HTTPS-443 fallback per link | medium |
| 12 | Streaming detection + QoS | SNI/port classifier; RT queue; user toggle "Prioritize streaming" | low |
| 13 | Pair & Share | Bonjour discovery, paired device as virtual link | high |
| 14 | Captive portal assist | Per-link captive probe, "Solve" button, auto-recovery | medium |
| 15 | UI overhaul | Per-link cards with sparkline graphs, MOS, color coding, flow inspector | low |
| 16 | Local mode + finalization | Peer-to-peer bonding without relay; settings polish; signed/notarized release | medium |

---

## 6. Detailed Phase Specifications

### Phase 1 — Core refactor (no behavior change)

**Goal:** Make the codebase able to host two transports without rewrites.

**New files:**
* `lib/core/link.dart` — `Link` (id, label, interface name, source IP v4/v6, priority, speedCap, dataCap, dataUsedThisCycle, billingCycleAnchor, status).
* `lib/core/policy.dart` — `Policy` (mode, priorityOverrides, killSwitch, streamingDetection, dnsServers, splitTunnelAllowList).
* `lib/core/bonding_mode.dart` — `enum BondingMode { speed, redundant, streaming, local }`.
* `lib/core/link_metric.dart` — `LinkMetric` (rttMs, jitterMs, lossPct, mos, bpsIn, bpsOut, capturedAt).
* `lib/core/flow_stat.dart` — `FlowStat` (remoteHost, remotePort, linkId, bytesIn, bytesOut, openedAt).
* `lib/transport/transport.dart` — abstract `Transport { Future<void> start(Policy); Future<void> stop(); Stream<LinkMetric> metrics; Stream<FlowStat> flows; }`.
* `lib/transport/socks_transport.dart` — adapter over current `SocksProxyServer`.
* `lib/transport/tunnel_transport.dart` — stub that delegates to the (not-yet-implemented) extension.

**Existing files to edit:**
* `lib/screen/dispatch_controller.dart:14-162` — switch from holding a `SocksProxyServer` directly to holding a `Transport` selected by user.
* `lib/core/dispatch_settings.dart:1-78` — migrate `selectedTargets` to a list of `Link` (Hive type adapter; one-time migration on first launch reads old key and writes new schema; keep `selectedTargets` for rollback).
* `lib/core/weighted_address.dart` — keep `WeightedRoundRobinDispatcher` (used by SOCKS transport); rename `ResolvedWeightedAddress` consumers to wrap a `Link`.

**Tests:**
* `test/core/policy_test.dart` — serialization round-trip; defaults.
* `test/transport/socks_transport_test.dart` — equivalent of `test/core/socks_proxy_server_test.dart:1-173` but through the `Transport` API.

**Done when:**
* `flutter analyze` clean, `flutter test` green.
* Manual: existing SOCKS smoke test (`curl --socks5-hostname 127.0.0.1:1080 https://example.com`) still passes.

---

### Phase 2 — Live per-link metrics

**Goal:** Show RTT / jitter / loss / throughput / MOS per link, updated 1 Hz, with a 60 s
sparkline.

**New files:**
* `lib/probes/link_probe_service.dart`
  - For each enabled `Link`, runs three concurrent probes:
    1. **ICMP-like RTT:** since Dart can't open raw sockets, use UDP echo to a known endpoint or, preferably, TCP-SYN to `1.1.1.1:443` / `8.8.8.8:53` with `Socket.connect` and `sourceAddress` set to the link's IP; measure connect time. Also fire DNS-over-UDP queries to `1.1.1.1:53` for parallel data.
    2. **Loss/jitter:** 10 Hz UDP-echo to a known reflector (we will run a tiny echo on the Speed Server; for now use `stun.l.google.com:19302` STUN binding requests, which give us latency and effectively loss when responses are missing).
    3. **Throughput estimation:** EWMA of bytes/sec actually pushed through this link by SOCKS / tunnel transport (read from `Transport.flows` + a kernel-level counter when available via `getifaddrs` / `sysctl net.link.…`).
  - Computes MOS via E-model approximation: `MOS = 1 + 0.035*R + 7e-6*R*(R-60)*(100-R)` where R = 93.2 - delayPenalty(rtt, jitter) - lossPenalty(lossPct). Cap to [1.0, 4.5].
* `lib/probes/link_metric_store.dart` — Ring buffer (60 samples × N links) in memory; persisted snapshot every 5 s to Hive so reopening the window does not show empty graphs.

**Edited files:**
* `lib/screen/dispatch_controller.dart` — owns the probe service; surfaces `Map<LinkId, LinkMetric>` as a `ValueListenable`.
* `lib/ui/dispatch_ui.dart` — add `MetricBadge`, `SparklinePainter`.

**Notes / risks:**
* Apple firewall (`pf`) on some networks blocks STUN; the probe service must have a
  fallback target (DNS over TCP to `1.1.1.1:53` always works).
* Need to **bind probes to the source IP** of the link to get per-link numbers; this is
  exactly what `lib/core/socks_proxy_server.dart:249-254` already does via `sourceAddress`.

**Tests:**
* `test/probes/link_probe_service_test.dart` — fake reflectors; assert MOS formula bounds;
  assert ring buffer evicts at 60 samples.

**Done when:**
* Each enabled link shows live RTT/jitter/loss/MOS/throughput in the UI.
* Pulling Wi-Fi cable spikes loss to ~100 % within 2 s.

---

### Phase 3 — Priority + limits engine

**Goal:** User can mark each link Primary/Secondary/Backup/Never, set a per-link Mbps cap
and a monthly data cap with rollover date. SOCKS dispatcher honors these.

**New files:**
* `lib/policy/policy_engine.dart`
  - Inputs: list of `Link`, current `LinkMetric` map, `Policy`.
  - Output: ordered list of `EligibleLink` with effective weights.
  - Rules:
    * `Never` links are excluded.
    * Health gate: link is excluded if `lossPct > 30 %` OR `rtt > 1500 ms` OR data-cap-exhausted.
    * `Primary` group is used while ≥ 1 Primary is healthy. Otherwise drop to Secondary, then Backup.
    * Within a group, weights = clamp(speedCap_bps / sum(speedCap_bps), 0.05, 0.95) when caps set; else 1/N.
    * Speed cap throttling implemented in `socks_transport.dart` via per-link `TokenBucket`.
    * Data cap: persistent counter in Hive, reset on `billingCycleAnchor`.
* `lib/policy/token_bucket.dart` — leaky-bucket throttle (bytes/sec).
* `lib/policy/data_meter.dart` — accumulator + rollover.

**Edited files:**
* `lib/transport/socks_transport.dart` — between `Socket.connect` (analog to `lib/core/socks_proxy_server.dart:249-254`) and the pipe loop (`_pipeMultiple`, `lib/core/socks_proxy_server.dart:347-369`), wrap both directions in the link's `TokenBucket` and increment `DataMeter`.
* `lib/core/weighted_address.dart:168-209` — `WeightedRoundRobinDispatcher` becomes a thin wrapper over `PolicyEngine.eligible()` results.
* UI: priority dropdown, Mbps cap field, data cap field per link.

**Tests:**
* `test/policy/policy_engine_test.dart` — primary fails → fall back to secondary; data cap hit → link disabled.
* `test/policy/token_bucket_test.dart` — caps measured rate within 5 % over 2 s.

**Done when:**
* Marking a Primary as Never makes existing flows migrate (Phase 4) and new flows route to Secondary.
* Setting a 5 Mbps cap on a link makes `iperf3 -c via curl --socks5 …` clamp at ~ 5 Mbps.

---

### Phase 4 — Connection-level failover & kill switch (still SOCKS scope)

**Goal:** When a link goes unhealthy, in-flight SOCKS connections re-route on next read
failure; new flows skip the bad link; kill switch closes the SOCKS listener when no link
is healthy AND `Policy.killSwitch` is true.

**Edited files:**
* `lib/transport/socks_transport.dart`
  - Wrap `_pipeMultiple` (current behavior in `lib/core/socks_proxy_server.dart:347-369`) with a watchdog: if RX or TX stalls > 4 s AND the link is now `unhealthy`, the loop tries to open a parallel connection to the same remote on a different healthy link, splices the buffer, then swaps. This is best-effort; it works for stateless HTTP-style transfers and silently falls back to closing the connection otherwise.
* `lib/policy/link_supervisor.dart` — subscribes to metrics, emits `LinkHealthEvent(linkId, state)`. When all healthy = 0 AND killSwitch → stop transport; resume when ≥ 1 healthy.
* macOS firewall hook (preview): when extension exists in Phase 5, this becomes `pf` rule injection. For Phase 4 it only stops the SOCKS listener.

**Tests:**
* `test/policy/link_supervisor_test.dart` — feed synthetic metrics; assert transitions.

**Done when:**
* Yank Wi-Fi during a long `curl` through SOCKS — the request either survives via the second link or fails fast; the proxy never silently hangs.
* Kill-switch on + all links down → SOCKS port closed, UI shows banner.

---

### Phase 5 — Network Extension scaffold

**Goal:** Ship a System Extension that owns a TUN, accepts policy from Dart, and (for
this phase only) forwards every IP packet back to the kernel via a tiny in-extension
SOCKS-like NAT — i.e., the extension wraps the existing SOCKS engine behavior with a
TUN front-end. Result: traffic is now system-wide, no app config needed, but bonding is
not yet implemented.

**New Xcode target:** `ArcaneDispatchTunnel.appex` (Network Extension, Packet Tunnel Provider).
* Path: `macos/ArcaneDispatchTunnel/`
* Bundle ID: `art.arcane.ArcaneDispatch.tunnel`
* Entitlements (`macos/ArcaneDispatchTunnel/ArcaneDispatchTunnel.entitlements`):
  - `com.apple.security.app-sandbox = true`
  - `com.apple.developer.networking.networkextension = [packet-tunnel-provider]`
  - `com.apple.security.application-groups = [group.art.arcane.dispatch]`
* Files:
  - `macos/ArcaneDispatchTunnel/PacketTunnelProvider.swift` — overrides `startTunnel`, `stopTunnel`, `handleAppMessage`.
  - `macos/ArcaneDispatchTunnel/Engine/PolicyStore.swift` — reads policy JSON from the App Group container.
  - `macos/ArcaneDispatchTunnel/Engine/PacketPump.swift` — `packetFlow.readPackets` loop; for v1 each packet is wrapped into a TCP/UDP socket created with `sourceAddress` matching the chosen link.
  - `macos/ArcaneDispatchTunnel/Engine/UserTcpStack.swift` — a minimal userspace TCP reassembler good enough to translate TUN IP/TCP packets into `Socket.connect` (use `swift-nio` or hand-roll for v1; recommend `swift-nio` for stability).

**Container app changes:**
* `macos/Runner/DebugProfile.entitlements`, `Release.entitlements`: enable sandbox, add
  `com.apple.security.application-groups = [group.art.arcane.dispatch]`, add
  `com.apple.developer.networking.networkextension = [packet-tunnel-provider]`.
* `macos/Runner/MainFlutterWindow.swift:25-50` — extend the `dispatch_tray` channel or add a `dispatch_tunnel` channel with methods: `installExtension`, `startTunnel(policyJson)`, `stopTunnel`, `status`.
* New Swift: `macos/Runner/TunnelManager.swift`
  - Wraps `NEVPNManager.shared()` + `NETunnelProviderManager` to load/save a `NETunnelProviderProtocol` whose `providerBundleIdentifier = art.arcane.ArcaneDispatch.tunnel`.
  - Wraps `OSSystemExtensionRequest` to install/activate the extension on first run.
* Dart side: `lib/bridge/tunnel_channel.dart` — `MethodChannel('dispatch_tunnel')`. Used by `lib/transport/tunnel_transport.dart`.

**Signing prerequisite (must be resolved before merging Phase 5):**
* Apple Developer Program membership.
* Provisioning profiles for `art.arcane.ArcaneDispatch` (container) AND
  `art.arcane.ArcaneDispatch.tunnel` (extension) with NetworkExtension capability.
* Hardened Runtime; both bundles notarized.
* `LSUIElement` stays true in `macos/Runner/Info.plist:25-26` (container is menu-bar).

**Tests:**
* XCTest target `ArcaneDispatchTunnelTests` — exercise `PolicyStore` round-trip and the `UserTcpStack` against a loopback echo.
* Manual: `Settings → Network → VPN` shows the configuration; toggling Connect from the UI brings up the TUN; `route -n get default` shows the TUN as default.

**Done when:**
* Connect/Disconnect from the menu-bar UI flips macOS into "VPN active" state.
* `curl https://example.com` works with no SOCKS env var set.
* Traffic still uses the user-selected link(s) (no bonding yet, just per-flow dispatch).

---

### Phase 6 — Tunnel routing through link selector

**Goal:** The extension's per-packet decisions go through the same `PolicyEngine` the
Dart UI shows. Per-link, per-flow stats become live and accurate. Apps need no config.

**Work:**
* Port the Dart `PolicyEngine` (Phase 3) to Swift in `macos/ArcaneDispatchTunnel/Engine/PolicyEngine.swift`. Source of truth is JSON in App Group; Dart writes, Swift reads. Both must agree on the schema (publish `docs/policy_schema.json`).
* Per-flow stats: extension publishes `flow.created`, `flow.bytes`, `flow.closed` deltas to a shared ring buffer; Dart reads via `UserDefaults` notification.
* Maintain a per-flow `linkId` so when Phase 7 ships, sticky flows are easy.
* Kill switch: when active and no healthy link, the extension simply drops packets (no special pf rules needed because traffic must transit the TUN by routing).

**Done when:**
* Disable the only Primary in UI → app's existing connections die / migrate to Secondary (still connection-level migration, not packet-level).
* Flow inspector in UI shows real assignments.

---

### Phase 7 — Bonded transport (lab/local first)

**Goal:** A single TCP flow's packets are striped across two links and reassembled.
Validated on loopback first: two virtual links bind to two loopback aliases on the same
machine, the "server" runs in a separate process on the same Mac.

**Protocol v0 (UDP first):**
* Wire format (network byte order):
  ```
  | magic(2) | ver(1) | flags(1) | sessionId(8) | seq(8) | linkId(2) | payloadLen(2) | payload |
  | 0xDA01   | 0x01   | …        |              |        |          |               |         |
  ```
  Flags: `[QoS:2 | ack:1 | nak:1 | keepalive:1 | reserved:3]`.
* `seq` is per-session, monotonic, increments per outbound payload byte (TCP-like) so the
  server can reassemble even when packets arrive out of order or from different links.
* Reassembly buffer: per-session sliding window keyed by `seq`; gap timer = 2× max(RTT)
  across active links; on gap timeout the server sends a NAK; the client retransmits on
  the *fastest currently healthy* link.
* Per-link keepalive at 5 Hz; carries `inflight` counter for BBR-like pacing.
* Client scheduler v0 (Speed mode): packet `n` → link with the most send credit
  (credit = bandwidth × RTT − inflight). Falls back to weighted RR on ties.

**Where it lives:**
* Swift implementation: `macos/ArcaneDispatchTunnel/Bonded/BondedClient.swift`,
  `BondedReassembler.swift`, `BondedScheduler.swift`, `BondedFraming.swift`.
* Server: separate repo `dispatch-speed-server` (Go). For this phase it can be embedded
  as a Swift binary started by the test harness; ship as Docker later.
* Pure-Swift v0; consider Rust core later for performance.

**Tests:**
* Lab harness: `tools/bondlab.sh` — uses `dummynet`/`pfctl` to add latency and loss to two
  loopback interfaces; expects aggregate iperf3 ≥ 1.5× single-link in Speed mode.
* Loss injection: 5 % loss on one link → reassembly still completes; no out-of-order
  bytes delivered to the kernel-side TCP stack.

**Done when:**
* iperf3 through the bonded transport in a two-link lab is faster than either link alone.

---

### Phase 8 — Speed Server reference

**Goal:** A public, deployable open-source relay so the bonded transport works on the
real internet.

**Deliverable (in sibling repo `dispatch-speed-server`):**
* Single Go binary.
* Subcommands: `serve`, `genkey`, `adduser`, `stats`.
* Listens on:
  - UDP/443
  - TCP/443 with raw bonded framing
  - TLS/443 (HTTPS) with `Upgrade: dispatch-bonded` for hostile NATs
* Auth: ed25519 server key; per-client X25519 ECDH (matches the on-device handshake from
  Phase 9). Token-based pre-auth so unauthenticated UDP traffic gets dropped at zero cost.
* Egress: pure NAT44/NAT66 to the public internet; no logging beyond counters.
* Stats: Prometheus endpoint on `:9090`.
* `docker-compose.yml`, `systemd` unit, `infra/terraform/` for AWS/Hetzner one-click.

**Dart side:**
* Settings: server URL + token (with QR scan from `genkey` output for ease).
* `lib/bridge/tunnel_channel.dart` exposes `setServer(url, token)`.

**Done when:**
* Run server on a $5 VPS; from a different network the client connects through it and a
  bonded `curl ifconfig.io` reports the server's IP.

---

### Phase 9 — Encryption + handshake

**Goal:** End-to-end secrecy + integrity + forward secrecy + replay protection.

**Choice:** Noise Protocol Framework, pattern `IK` (interactive, client knows server's
static key in advance — fits the "user installs server URL + key" model).

* Curve: X25519. Cipher: ChaCha20-Poly1305 by default; AES-256-GCM negotiated if both
  sides advertise hardware support (`Common Crypto` on macOS).
* Per-packet header includes a 64-bit nonce; sliding-window anti-replay (1024 entries) on
  the receiver.
* Session rekey on `min(1 GiB, 30 min)`; rekey is a 1-RTT in-band handshake.
* Identity: client key persisted in macOS Keychain (Service: `arcane_dispatch`,
  Account: `client_identity`).

**Implementation:**
* `macos/ArcaneDispatchTunnel/Crypto/Noise.swift` (wrap `swift-noise` or hand-roll over
  `CryptoKit`).
* Server picks up the same Noise framing.

**Tests:**
* Wire compatibility vectors against the Noise spec.
* Replay test: re-send the same encrypted UDP frame — receiver drops.

**Done when:**
* Wireshark capture between client and server shows nothing identifiable beyond UDP/443
  to `<server_ip>`; HTTPS-tunneled mode looks like generic TLS.

---

### Phase 10 — Real bonded modes

**Goal:** All four Speedify modes are real and switchable at runtime.

* `Speed`: scheduler from Phase 7 (BBR-credit based).
* `Redundant`: each payload is sent on *all* `Primary` links; receiver de-dupes by `seq`.
  Latency = min(link latencies), throughput = min link's throughput.
* `Streaming`: low-latency variant of Speed:
  - Disables Nagle equivalents.
  - Caps in-flight per link to 1×BDP (not 4×) so jitter buffer stays small.
  - Promotes flows tagged "RT" (Phase 12) to a separate higher-priority queue.
  - Falls back to Redundant for RT flows when loss > 1 %.
* `Local`: no relay. Two devices on the same LAN; one device's TUN is the egress. Uses
  the same bonded protocol but to a peer instead of a server. Discovery via
  `NWBrowser`/Bonjour service `_dispatch-bonded._udp`.

**Done when:**
* Switching modes mid-flow does not drop existing TCP connections.
* Redundant mode survives 30 % loss on one link without throughput degradation worse than
  20 %.

---

### Phase 11 — Auto protocol switch (TCP/UDP/HTTPS)

**Goal:** When a link's UDP path is blocked/throttled, transparently switch to TCP, then
TLS-on-443.

* Per-link transport probe at handshake time: try UDP/443, on `EHOSTUNREACH` or 5 s of
  no keepalive, fall back to TCP/443; on TCP RST/firewall, fall back to TLS/443 with an
  HTTP/1.1 upgrade.
* During the session, if a link's outbound transport sees > 5 % loss AND no other links
  see loss, kick the per-link probe again.
* Switching is per-link; the bonded scheduler does not need to know which transport each
  link uses.

**Done when:**
* On a network that blocks UDP, the tunnel still comes up via TCP-443 within 6 s of
  handshake start.

---

### Phase 12 — Streaming detection + QoS

**Goal:** Mark video/voice flows as RT; route via low-latency queue (and via the
Streaming-mode scheduler if the user has it on).

* Detection sources (cheap, no DPI):
  - Destination port (UDP/443 to known Zoom/Meet/WebRTC subnets, UDP/3478 STUN).
  - SNI extracted from the first TLS ClientHello (the extension already sees raw IP/TCP).
  - User allow-list of executables (matched via `getsockopt(SO_DELEGATED_IDENT)` or the
    `audit_token_t` from `NEAppRule`).
* Maintain a small classifier table; result attached to the flow's first packet's metadata.

**UI:**
* Toggle: "Prioritize streaming & calls".
* Per-flow tag in the flow inspector.

**Done when:**
* During a Zoom call + a large download, the call's audio MOS stays > 4.0.

---

### Phase 13 — Pair & Share

**Goal:** Use a paired phone's cellular as an additional link.

* Phone-side app (out of scope of this Flutter project for now; sibling iOS app or use
  existing tools): runs a bonded-protocol echo and advertises Bonjour
  `_dispatch-paired._udp`.
* Mac discovers the device, prompts to pair (QR or 6-digit code).
* The paired peer becomes a virtual link with its own `Link` row and metrics.

**Done when:**
* iPhone tethered via the app shows up as a link; bonding includes it.

---

### Phase 14 — Captive portal assist

**Goal:** Don't let a captive portal silently make a Primary link "Internet-less".

* Per-link probe to `http://captive.apple.com/` (Phase 2 already has the plumbing; add
  body check for `<TITLE>Success</TITLE>`).
* On portal detection:
  - Demote the link to `Backup` (effective priority).
  - Surface a UI banner with a "Solve in Safari" button that opens a *link-bound* browser
    session (use `nw_connection`-based proxy or simply hand the user a click that launches
    Safari while temporarily routing only Safari to that link via `NEAppRule`).
  - Re-probe every 15 s; restore priority on success.

**Done when:**
* Joining a hotel Wi-Fi auto-detects the portal; UI lets the user solve it without losing
  cellular tunnel.

---

### Phase 15 — UI overhaul

**Goal:** Replace the current single-page settings view (`lib/screen/home_screen.dart:48-86`)
with a Speedify-style dashboard.

**New screens:**
* `lib/screen/dashboard_screen.dart`
  - Top: connection status (Connected/Connecting/Off), mode picker, big throughput.
  - Middle: per-link `LinkCard` (icon, name, MOS dot color, RTT, loss, up/down sparkline,
    priority dropdown, speed cap chip, data cap chip).
  - Bottom: flow inspector table (top 20 flows by bytes, color of flow = color of link).
* `lib/screen/settings_screen.dart` — current settings + new ones (server URL, mode
  default, kill switch, streaming detection, split tunnel allow-list).
* `lib/widgets/sparkline.dart`, `lib/widgets/mos_pill.dart`, `lib/widgets/throughput_bar.dart`.
* Color palette extended in `lib/ui/dispatch_ui.dart:3-12` with per-link stable colors
  (hash linkId → HCL).

**Done when:**
* The dashboard is the default screen; all Speedify-equivalent info is visible at a glance.

---

### Phase 16 — Local mode + release

**Goal:** Two devices peer-to-peer; sign + notarize + ship.

* Local mode polish (Phase 10 introduced it; this phase ships it).
* Signing/notarization automation in `tools/release.sh`.
* Auto-update via Sparkle or self-managed appcast.
* `CONTRIBUTING.md` only added if user requests it (per project rules; not by default).
* Linux + Windows ports are out of scope for v1 but the `Transport` abstraction and the
  Dart side already support them; the Network Extension is replaced per-platform
  (`wintun`, `tun.go`).

---

## 7. Cross-cutting Concerns

### 7.1 IPC / shared state schema (App Group)

* Path: `~/Library/Group Containers/group.art.arcane.dispatch/`
* Files:
  - `policy.json` — written by Dart, read by extension.
  - `metrics.bin` — ring buffer written by extension, read by Dart (mmap'd struct,
    fixed-size to avoid serialization cost).
  - `flows.bin` — same.
  - `events.log` — append-only NDJSON; extension writes, Dart tails.
* Notification names: `art.arcane.dispatch.policyChanged`,
  `art.arcane.dispatch.metricsTick`.

### 7.2 Logging

* Dart: keep `fast_log` (`lib/main.dart:59-70`).
* Swift: `os_log` with subsystem `art.arcane.dispatch`, categories `tunnel`, `bonded`,
  `crypto`, `policy`.
* Both rotated at 1 MiB (Dart already does, `lib/main.dart:61-63`).

### 7.3 Configuration & migration

* Bump the Hive box name from `settings` to `settings_v2` on first run; one-time copy +
  schema migration; keep `settings` readable for one release for rollback.

### 7.4 Threading

* Dart UI runs on the platform thread.
* Probe service: an `Isolate` (so 10 Hz STUN doesn't jitter the UI).
* Extension's tunnel I/O loop is its own `DispatchQueue` (`tunnel-io`), scheduler is
  `tunnel-sched`, crypto on a pool.

### 7.5 Security

* All keys in Keychain. Server URL in plain prefs is acceptable.
* Tunnel extension manifests its sandbox; container app stays sandboxed in release.
* No third-party telemetry. (Speedify is closed-source and collects stats; this OSS clone
  must not.)

---

## 8. Risks, Unknowns, Showstoppers

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Apple denies NetworkExtension entitlement | Phase 5+ blocked | Apply early (paid Apple Developer Program, ~2 week turnaround). Plan B: ship as user-installed `pfctl` + utun via privileged helper. |
| Bonded throughput aggregation underperforms in real internet | Phase 7+ undermined | Use BBR-credit scheduler; benchmark against `Multipath QUIC` open implementations (e.g., `quic-go` MP-QUIC branch). |
| Server cost for hosted Speed Servers | Project sustainability | Make it BYO (Bring-Your-Own-Server) by default; provide one-click deploy templates. |
| Pair & Share without an iOS companion app | Phase 13 stalls | Initially support paired Mac as second uplink (no iOS app needed); iOS app is a later, separate plan. |
| Streaming detection false positives | Phase 12 hurts non-streaming | Detector is advisory only; user toggle to disable; per-app override. |
| SOCKS fallback masks real-world bugs | Hides regressions | CI runs the bonded transport in a netns harness (Linux runner) for every PR. |
| Captive portals that hijack DNS | Phase 14 detection breaks | Use IP-literal probe URL (`http://17.253.144.10/` is Apple's captive endpoint IP). |
| Hive schema drift | Data loss | Versioned schema + one-shot migration tests in `test/migration/`. |

---

## 9. Verification Strategy

| Phase | Automated | Manual |
| --- | --- | --- |
| 1 | `flutter analyze`, `flutter test` | SOCKS smoke test still passes |
| 2 | Probe unit tests | Disconnect Wi-Fi, see loss spike < 2 s |
| 3 | Engine + bucket tests | iperf throttle within ±10 % of cap |
| 4 | Supervisor tests | Yank Wi-Fi mid-curl; SOCKS port closes when killswitch on |
| 5 | XCTest + smoke | Connect from menu bar, `curl` works without env vars |
| 6 | Schema round-trip tests | Flow inspector reflects real apps |
| 7 | Lab harness (dummynet) | iperf3 ≥ 1.5× single link, 2-link Speed mode |
| 8 | Server integration tests | $5 VPS bonded session for 1 h, no leaks |
| 9 | Noise test vectors, replay test | Wireshark = opaque |
| 10 | Per-mode lab tests | Mode switch mid-flow does not drop sessions |
| 11 | Transport probe matrix | UDP-blocked network → up via TCP/443 in < 6 s |
| 12 | Classifier tests | Zoom MOS > 4.0 with concurrent download |
| 13 | Bonjour discovery test | Paired Mac is a usable extra link |
| 14 | Captive-portal mock server | Hotel Wi-Fi (manual) detected and solvable |
| 15 | Widget tests | Dashboard matches design |
| 16 | E2E in two-Mac lab | Notarized release runs on a clean macOS install |

---

## 10. Deliverables Outside This Plan

These are explicitly *not* part of this plan and will get their own plans when needed:
* iOS companion + Pair & Share peer.
* Linux + Windows clients.
* Multi-hop / chained Speed Servers.
* Cloud-hosted Speed Server fleet & billing.
* Web dashboard / remote management.

---

## 11. Suggested First-Phase Kickoff (Phase 1 only)

When ready to execute, the first set of touchpoints is:

1. Create models: `lib/core/link.dart`, `lib/core/policy.dart`, `lib/core/bonding_mode.dart`,
   `lib/core/link_metric.dart`, `lib/core/flow_stat.dart`.
2. Introduce `lib/transport/transport.dart` and a thin `lib/transport/socks_transport.dart`
   that re-exposes the current `SocksProxyServer` behavior.
3. Migrate `lib/screen/dispatch_controller.dart:14-162` to depend on `Transport` instead
   of `SocksProxyServer` directly. Keep `lib/core/socks_proxy_server.dart` unchanged.
4. Hive migration: `selected_targets` (List<String>) → `links_v1` (List<Link as JSON>);
   one-shot copy on first launch.
5. Tests: add `test/transport/socks_transport_test.dart`; keep
   `test/core/socks_proxy_server_test.dart:1-173` and
   `test/widget/home_screen_test.dart:1-106` working (they will need light edits to
   construct a `Transport` instead of a `SocksProxyServer`).

Expected diff size for Phase 1: ~ 800 LOC added, ~ 80 LOC edited, no behavior change.

---

*End of plan.*
