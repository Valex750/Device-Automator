#!/bin/bash
set -euo pipefail

# Some MCP clients split `command` on spaces, so this script is launched via:
#   command: /bin/bash
#   args: ["…/Ios.device-automator/scripts/run-mcp.sh"]
#
# Copied Development-signed Mach-Os under Application Support are killed
# (Code Signature Invalid), so they must be re-signed after install. Re-sign
# with a real, stable certificate rather than ad-hoc (--sign -): ad-hoc gives
# every rebuild a different signature, which is bad practice regardless of
# whether it affects Xcode's own "Allow external agent" consent dialog (see
# README Troubleshooting — that dialog appears to be scoped per running
# process, not per signature, so it may still reappear on process restarts).
#
# The identity is per-Mac, so it is not stored in this script. In order:
#   1. $DEVICE_AUTOMATOR_SIGNING_IDENTITY
#   2. the first line of ~/Library/Application Support/DeviceAutomator/signing-identity
#   3. the first valid "Apple Development" identity in the keychain
SUPPORT="${HOME}/Library/Application Support/DeviceAutomator"
INSTALLED="$SUPPORT/bin/DeviceAutomator"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/DeviceAutomator/DeviceAutomator.xcodeproj"

signing_identity() {
  if [[ -n "${DEVICE_AUTOMATOR_SIGNING_IDENTITY:-}" ]]; then
    printf '%s\n' "$DEVICE_AUTOMATOR_SIGNING_IDENTITY"
    return
  fi
  if [[ -s "$SUPPORT/signing-identity" ]]; then
    head -n 1 "$SUPPORT/signing-identity"
    return
  fi
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1
}

# Newest Release build across DerivedData folders (moved/cloned checkouts get their own).
derived_release() {
  local newest="" candidate
  for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/DeviceAutomator-*/Build/Products/Release/DeviceAutomator; do
    [[ -x "$candidate" ]] || continue
    if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then
      newest="$candidate"
    fi
  done
  if [[ -n "$newest" ]]; then
    printf '%s\n' "$newest"
  fi
}

install_release() {
  local src="$1" identity
  identity="$(signing_identity)"
  if [[ -z "$identity" ]]; then
    echo "run-mcp.sh: no code-signing identity. Set DEVICE_AUTOMATOR_SIGNING_IDENTITY or write one to $SUPPORT/signing-identity (see README step 3)." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$INSTALLED")"
  /usr/bin/ditto "$src" "$INSTALLED"
  /usr/bin/xattr -cr "$INSTALLED" >/dev/null 2>&1 || true
  /usr/bin/codesign --force --sign "$identity" --timestamp=none --identifier DeviceAutomator "$INSTALLED" >/dev/null
  chmod +x "$INSTALLED"
}

if [[ -x "$INSTALLED" ]]; then
  BIN="$(derived_release || true)"
  if [[ -n "${BIN}" && "$BIN" -nt "$INSTALLED" ]]; then
    install_release "$BIN"
  fi
  exec "$INSTALLED"
fi

BIN="$(derived_release || true)"
if [[ -z "${BIN}" ]]; then
  xcodebuild -project "$PROJ" -scheme DeviceAutomator -configuration Release \
    -destination 'platform=macOS,arch=arm64' build >/dev/null
  BIN="$(derived_release)"
fi

install_release "$BIN"
exec "$INSTALLED"
