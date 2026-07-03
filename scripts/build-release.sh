#!/usr/bin/env sh
# Build a release tarball for the current machine architecture.
# For both arm64 and x86_64, run this script on each host (or use CI matrix jobs).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-dev}"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) ASSET_ARCH="arm64" ;;
  x86_64) ASSET_ARCH="x86_64" ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

BUILD_DIR="$ROOT/.build/release"

echo "Building meetscribe for darwin-${ASSET_ARCH}..."
swift build -c release --disable-sandbox

mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/meetscribe-darwin-${ASSET_ARCH}.tar.gz"
tar -czf "$OUT" -C "$BUILD_DIR" meetscribe

echo "Created $OUT (version label: $VERSION)"
echo "Repeat on the other architecture for universal release coverage."
