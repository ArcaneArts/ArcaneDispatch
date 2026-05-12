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
