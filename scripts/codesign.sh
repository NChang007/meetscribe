#!/usr/bin/env sh
# Optional codesign + notarization for public macOS distribution.
# Set SIGNING_IDENTITY to your Developer ID Application certificate name.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$ROOT/.build/release/meetscribe"

if [ -z "${SIGNING_IDENTITY:-}" ]; then
  echo "Set SIGNING_IDENTITY to your Developer ID Application certificate." >&2
  echo "Example: SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' $0" >&2
  exit 1
fi

if [ ! -f "$BINARY" ]; then
  swift build -c release --disable-sandbox
fi

codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$BINARY"
codesign --verify --verbose "$BINARY"
echo "Signed $BINARY"
echo "For Gatekeeper-friendly distribution, notarize with xcrun notarytool and staple the app/binary."
