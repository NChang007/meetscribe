#!/usr/bin/env sh
# meetscribe installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/NChang007/meetscribe/main/scripts/install.sh | sh
#   curl -fsSL ... | sh -s -- --version v0.1.0
#   INSTALL_DIR=$HOME/.local/bin curl -fsSL ... | sh
#   MEETSCRIBE_SKIP_MODELS=1 curl -fsSL ... | sh   # air-gapped / skip ~1GB download
#
# Override repo: MEETSCRIBE_REPO=your-org/meetscribe

set -eu

REPO="${MEETSCRIBE_REPO:-NChang007/meetscribe}"
VERSION="${MEETSCRIBE_VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
FROM_SOURCE="${MEETSCRIBE_FROM_SOURCE:-0}"
SKIP_MODELS="${MEETSCRIBE_SKIP_MODELS:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --from-source)
      FROM_SOURCE=1
      shift
      ;;
    --prefix)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --skip-models)
      SKIP_MODELS=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$ARCH" in
  arm64|aarch64) ASSET_ARCH="arm64" ;;
  x86_64|amd64) ASSET_ARCH="x86_64" ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

if [ "$OS" != "darwin" ]; then
  echo "meetscribe currently supports macOS only." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"

install_from_source() {
  if ! command -v swift >/dev/null 2>&1; then
    echo "Swift toolchain not found. Install Xcode Command Line Tools:" >&2
    echo "  xcode-select --install" >&2
    exit 1
  fi

  WORKDIR="${TMPDIR:-/tmp}/meetscribe-install-$$"
  mkdir -p "$WORKDIR"
  trap 'rm -rf "$WORKDIR"' EXIT INT TERM

  if [ -d ".git" ] && [ -f "Package.swift" ]; then
    SRC_DIR="$(pwd)"
  else
    echo "Cloning $REPO..."
    git clone --depth 1 "https://github.com/$REPO.git" "$WORKDIR/src"
    SRC_DIR="$WORKDIR/src"
    if [ -f "$WORKDIR/src/meetscribe/Package.swift" ]; then
      SRC_DIR="$WORKDIR/src/meetscribe"
    fi
  fi

  echo "Building meetscribe from source..."
  (
    cd "$SRC_DIR"
    swift build -c release --disable-sandbox
  )

  install -m 755 "$SRC_DIR/.build/release/meetscribe" "$INSTALL_DIR/meetscribe"
}

install_from_release() {
  if [ "$VERSION" = "latest" ]; then
    URL="https://github.com/$REPO/releases/latest/download/meetscribe-${OS}-${ASSET_ARCH}.tar.gz"
  else
    URL="https://github.com/$REPO/releases/download/$VERSION/meetscribe-${OS}-${ASSET_ARCH}.tar.gz"
  fi

  WORKDIR="${TMPDIR:-/tmp}/meetscribe-install-$$"
  mkdir -p "$WORKDIR"
  trap 'rm -rf "$WORKDIR"' EXIT INT TERM

  echo "Downloading $URL"
  if ! curl -fsSL "$URL" -o "$WORKDIR/meetscribe.tar.gz"; then
    echo "Release download failed. Falling back to source build..." >&2
    FROM_SOURCE=1
    install_from_source
    return
  fi

  tar -xzf "$WORKDIR/meetscribe.tar.gz" -C "$WORKDIR"
  install -m 755 "$WORKDIR/meetscribe" "$INSTALL_DIR/meetscribe"
}

if [ "$FROM_SOURCE" = "1" ]; then
  install_from_source
else
  install_from_release
fi

echo ""
echo "Installed meetscribe to $INSTALL_DIR/meetscribe"

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    echo ""
    echo "Add this to your shell profile:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    ;;
esac

echo ""
echo "Setting up meetscribe (config + on-device models)..."
if [ "$SKIP_MODELS" = "1" ]; then
  "$INSTALL_DIR/meetscribe" init --skip-models
else
  echo "Downloading Core ML model weights (~1GB, one-time, not your audio)..."
  "$INSTALL_DIR/meetscribe" init
fi

echo ""
echo "Next steps:"
echo "  meetscribe doctor"
echo "  meetscribe permissions"
echo "  meetscribe record start --title \"My meeting\""
