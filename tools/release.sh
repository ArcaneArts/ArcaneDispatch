#!/usr/bin/env bash
# tools/release.sh — One-shot release pipeline for Arcane Dispatch.
#
# What it does:
#   1. Builds the Flutter macOS app (release config).
#   2. Codesigns the .app + its bundled NetworkExtension with the team's
#      Developer ID Application certificate.
#   3. Submits the bundle to Apple's notary service and waits for the staple.
#   4. Cross-compiles the Go speed-server for darwin/linux × arm64/amd64.
#   5. Drops all artifacts in `dist/` with versioned filenames + SHA256SUMS.
#
# One-time setup (run these once per machine, then forget):
#   1. Install the Developer ID Application cert in Keychain (Apple Developer
#      portal → Certificates → Developer ID Application → Download → import).
#   2. Store a notarytool keychain profile:
#        xcrun notarytool store-credentials "arcane-dispatch" \
#            --apple-id "you@example.com" \
#            --team-id "ABCDE12345" \
#            --password "<app-specific-password>"
#   3. cp tools/release.env.example tools/release.env  # then edit it.
#
# Required env (read from `tools/release.env` if present, else your shell):
#   ADL_TEAM_ID         — your Apple Developer team ID (10-char).
#   ADL_SIGNING_ID      — "Developer ID Application: Name (TEAMID)" string.
#   ADL_NOTARY_PROFILE  — name of the `notarytool` keychain profile.
#
# Optional:
#   ADL_VERSION         — version tag for filenames (default: git short-hash).
#
# Usage:
#   ./tools/release.sh                   # build everything
#   ./tools/release.sh --skip-notary     # local dev (signs but doesn't upload)
#   ./tools/release.sh --only-server     # just the Go binaries
#   ./tools/release.sh --only-app        # just the Flutter app
#
# Re-runnable: the script is idempotent; rerunning rebuilds in-place.
#
# Tag-and-ship checklist (manual, until Sparkle is wired):
#   1. Bump version in pubspec.yaml + macos/Runner/Configs/AppInfo.xcconfig.
#   2. `git tag vX.Y.Z && git push --tags`
#   3. `ADL_VERSION=vX.Y.Z ./tools/release.sh`
#   4. Upload contents of `dist/` to your GitHub release (the .zip plus all
#      four Go binaries plus SHA256SUMS-vX.Y.Z.txt).
#   5. Users verify downloads against the SHA256SUMS file before running.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="ArcaneDispatch"

# ---------------------------------------------------------------------------
# Env / flags
# ---------------------------------------------------------------------------

SKIP_NOTARY=0
ONLY_SERVER=0
ONLY_APP=0
for arg in "$@"; do
    case "$arg" in
        --skip-notary)  SKIP_NOTARY=1 ;;
        --only-server)  ONLY_SERVER=1 ;;
        --only-app)     ONLY_APP=1 ;;
        --help|-h)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "release.sh: unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

if [[ -f "$ROOT/tools/release.env" ]]; then
    # shellcheck disable=SC1091
    source "$ROOT/tools/release.env"
fi

ADL_VERSION="${ADL_VERSION:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"

mkdir -p "$DIST"

# ---------------------------------------------------------------------------
# App: Flutter build + codesign + notarize
# ---------------------------------------------------------------------------

build_app() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "release.sh: app build requires macOS; skipping" >&2
        return 0
    fi
    echo "==> Building Flutter macOS app ($ADL_VERSION)"
    pushd "$ROOT" >/dev/null
    flutter clean
    flutter pub get
    flutter build macos --release
    popd >/dev/null

    APP_PATH="$ROOT/build/macos/Build/Products/Release/$APP_NAME.app"
    if [[ ! -d "$APP_PATH" ]]; then
        # Flutter renames .app from the bundle display name. Fall back to glob.
        APP_PATH="$(find "$ROOT/build/macos/Build/Products/Release" \
            -maxdepth 1 -name '*.app' -type d | head -n1)"
    fi
    if [[ -z "${APP_PATH:-}" || ! -d "$APP_PATH" ]]; then
        echo "release.sh: could not locate built .app" >&2
        exit 1
    fi

    if [[ -z "${ADL_SIGNING_ID:-}" ]]; then
        echo "release.sh: ADL_SIGNING_ID is unset; skipping codesign" >&2
    else
        echo "==> Codesigning $APP_PATH"
        # The NetworkExtension bundle inside Contents/Library/SystemExtensions
        # must be signed *before* the outer .app so the outer signature
        # captures the inner hash.
        find "$APP_PATH/Contents" -name '*.systemextension' -type d \
            -print0 | while IFS= read -r -d '' ext; do
            codesign --force --options runtime --timestamp \
                --sign "$ADL_SIGNING_ID" \
                --entitlements "$ROOT/macos/ArcaneDispatchTunnel/ArcaneDispatchTunnel.entitlements" \
                "$ext"
        done
        codesign --force --options runtime --timestamp --deep \
            --sign "$ADL_SIGNING_ID" \
            --entitlements "$ROOT/macos/Runner/Release.entitlements" \
            "$APP_PATH"
        codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    fi

    if [[ "$SKIP_NOTARY" -eq 0 && -n "${ADL_NOTARY_PROFILE:-}" ]]; then
        echo "==> Notarizing $APP_PATH"
        ZIP="$DIST/$APP_NAME-$ADL_VERSION.zip"
        /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP"
        xcrun notarytool submit "$ZIP" \
            --keychain-profile "$ADL_NOTARY_PROFILE" \
            --wait
        xcrun stapler staple "$APP_PATH"
        rm "$ZIP"
    elif [[ "$SKIP_NOTARY" -eq 0 ]]; then
        echo "release.sh: ADL_NOTARY_PROFILE unset; skipping notary" >&2
    fi

    OUT_ZIP="$DIST/$APP_NAME-$ADL_VERSION-macos.zip"
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$OUT_ZIP"
    echo "    -> $OUT_ZIP"
}

# ---------------------------------------------------------------------------
# Go speed-server: cross-compile
# ---------------------------------------------------------------------------

build_server() {
    if ! command -v go >/dev/null 2>&1; then
        echo "release.sh: go missing; skipping server build" >&2
        return 0
    fi
    echo "==> Building dispatch-speed-server ($ADL_VERSION)"
    pushd "$ROOT/speed-server" >/dev/null
    LDFLAGS="-s -w -X main.version=$ADL_VERSION"
    for tgt in \
        darwin/arm64 darwin/amd64 \
        linux/amd64 linux/arm64
    do
        os="${tgt%/*}"
        arch="${tgt#*/}"
        out="$DIST/dispatch-speed-server-$ADL_VERSION-$os-$arch"
        echo "    [$os/$arch] -> $out"
        GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 \
            go build -trimpath -ldflags "$LDFLAGS" -o "$out" .
    done
    popd >/dev/null
}

# ---------------------------------------------------------------------------
# Drive
# ---------------------------------------------------------------------------

if [[ "$ONLY_SERVER" -eq 0 ]]; then
    build_app
fi
if [[ "$ONLY_APP" -eq 0 ]]; then
    build_server
fi

# Final manifest with SHA-256 for downstream pinning.
echo "==> Manifest:"
( cd "$DIST" && shasum -a 256 * 2>/dev/null | tee "SHA256SUMS-$ADL_VERSION.txt" ) || true
