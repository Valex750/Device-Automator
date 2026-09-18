#!/bin/bash
set -euo pipefail

# Cursor splits `command` on spaces, so this script is launched via:
#   command: /bin/bash
#   args: ["…/Device Automator/scripts/run-mcp.sh"]
#
# Copied Development-signed Mach-Os under Application Support are killed
# (Code Signature Invalid), so they must be re-signed after install. Re-signing
# ad-hoc (--sign -) works but gives every rebuild a different signature, which
# makes macOS TCC treat each rebuild as a brand-new app and re-prompt for the
# "Allow DeviceAutomator to access Xcode?" Automation permission every time.
# Signing with a real, stable certificate instead means TCC recognizes the
# same signing identity across rebuilds, so the grant only needs approving once.
SIGNING_IDENTITY="Apple Development: vinalex750@gmail.com (KLMDKUF4UY)"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/DeviceAutomator/DeviceAutomator.xcodeproj"
INSTALLED="${HOME}/Library/Application Support/DeviceAutomator/bin/DeviceAutomator"

derived_release() {
  local matches=("$HOME"/Library/Developer/Xcode/DerivedData/DeviceAutomator-*/Build/Products/Release/DeviceAutomator)
  if [[ -x "${matches[0]:-}" ]]; then
    printf '%s\n' "${matches[0]}"
  fi
}

install_release() {
  local src="$1"
  mkdir -p "$(dirname "$INSTALLED")"
  /usr/bin/ditto "$src" "$INSTALLED"
  /usr/bin/xattr -cr "$INSTALLED" >/dev/null 2>&1 || true
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --identifier DeviceAutomator "$INSTALLED" >/dev/null
  chmod +x "$INSTALLED"
}

if [[ -x "$INSTALLED" ]]; then
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
