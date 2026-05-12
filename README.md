# Arcane Dispatch

An Arcane macOS menu-bar Flutter port of `dispatch`, using a pure Dart SOCKS proxy engine.

## What It Does

- Lists usable local network interfaces.
- Runs a local SOCKS proxy on `127.0.0.1:1080` by default.
- Routes outbound connections through selected local addresses.
- Supports SOCKS5 no-auth `CONNECT` and SOCKS4/SOCKS4a `CONNECT`.
- Preserves weighted targets using the same `<interface-or-ip>[/weight]` shape as the Rust CLI.
- Lives in the macOS menu bar with a hidden Dock icon.

## Run

```bash
flutter run -d macos
```

## Validate

```bash
flutter analyze
flutter test
flutter build macos --release
```

The release build is written to:

```bash
build/macos/Build/Products/Release/ArcaneDispatch.app
```

## Client Setup

Once the proxy is running, point SOCKS-capable clients at:

```text
127.0.0.1:1080
```

For a command-line smoke test after selecting an active interface and starting the proxy:

```bash
curl --socks5-hostname 127.0.0.1:1080 https://example.com
```

## Release Builds

`tools/release.sh` automates the full release pipeline: Flutter build + codesign
+ notarize for the `.app`, plus Go cross-compile for the speed-server (darwin /
linux × arm64 / amd64).

```bash
cp tools/release.env.example tools/release.env   # fill in once
./tools/release.sh                               # build everything
./tools/release.sh --only-server                 # just the Go binaries
./tools/release.sh --skip-notary                 # local dev (sign only)
```

Artifacts (and a `SHA256SUMS-<ver>.txt` manifest) land in `dist/`. See
[`speed-server/README.md`](speed-server/README.md) for the relay server's
deploy instructions.

