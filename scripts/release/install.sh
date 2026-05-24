#!/usr/bin/env bash
set -euo pipefail

REPO="${AGENTISLAND_REPO:-HarryB25/agentisland}"
VERSION="${AGENTISLAND_VERSION:-latest}"
ARCH="$(uname -m)"
BIN_DIR="${INSTALL_BIN_DIR:-$HOME/.local/bin}"
SHARE_DIR="${INSTALL_SHARE_DIR:-$HOME/.local/share/agentisland}"
APP_DIR="${INSTALL_APP_DIR:-/Applications}"
INSTALL_APP=0

usage() {
  cat <<EOF
Install the AgentIsland CLI, and optionally the macOS app.

Usage:
  install.sh [--app] [--bin-dir PATH] [--share-dir PATH] [--app-dir PATH]

Environment:
  AGENTISLAND_REPO       GitHub repo (default: HarryB25/agentisland)
  AGENTISLAND_VERSION    Release tag or 'latest' (default: latest)
  INSTALL_BIN_DIR        CLI install dir (default: ~/.local/bin)
  INSTALL_SHARE_DIR      Support files dir (default: ~/.local/share/agentisland)
  INSTALL_APP_DIR        App install dir (default: /Applications)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      INSTALL_APP=1
      shift
      ;;
    --bin-dir)
      BIN_DIR="$2"
      shift 2
      ;;
    --share-dir)
      SHARE_DIR="$2"
      shift 2
      ;;
    --app-dir)
      APP_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$ARCH" in
  arm64|x86_64) ;;
  *)
    echo "error: unsupported macOS architecture '$ARCH'" >&2
    exit 1
    ;;
esac

if [[ "$VERSION" == "latest" ]]; then
  BASE_URL="https://github.com/$REPO/releases/latest/download"
else
  BASE_URL="https://github.com/$REPO/releases/download/$VERSION"
fi

CLI_ASSET="agentisland-cli-macos-$ARCH.tar.gz"
APP_ASSET="agentisland-macos-$ARCH.zip"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Downloading $CLI_ASSET"
curl -fsSL "$BASE_URL/$CLI_ASSET" -o "$TMP_DIR/$CLI_ASSET"

echo "==> Installing CLI to $BIN_DIR"
mkdir -p "$BIN_DIR" "$SHARE_DIR"
tar -xzf "$TMP_DIR/$CLI_ASSET" -C "$TMP_DIR"
install -m 0755 "$TMP_DIR/agentisland-cli/bin/agentisland" "$BIN_DIR/agentisland"
rm -rf "$SHARE_DIR/scripts"
mkdir -p "$SHARE_DIR/scripts"
cp "$TMP_DIR/agentisland-cli/share/agentisland/scripts/install-codex.sh" "$SHARE_DIR/scripts/install-codex.sh"
cp "$TMP_DIR/agentisland-cli/share/agentisland/scripts/install-claude-hooks.sh" "$SHARE_DIR/scripts/install-claude-hooks.sh"
chmod +x "$SHARE_DIR/scripts/"*.sh

if [[ "$INSTALL_APP" -eq 1 ]]; then
  echo "==> Downloading $APP_ASSET"
  curl -fsSL "$BASE_URL/$APP_ASSET" -o "$TMP_DIR/$APP_ASSET"
  unzip -q "$TMP_DIR/$APP_ASSET" -d "$TMP_DIR"

  TARGET_APP_DIR="$APP_DIR"
  if [[ ! -w "$TARGET_APP_DIR" ]]; then
    TARGET_APP_DIR="$HOME/Applications"
    mkdir -p "$TARGET_APP_DIR"
  fi

  echo "==> Installing AgentIsland.app to $TARGET_APP_DIR"
  rm -rf "$TARGET_APP_DIR/AgentIsland.app"
  ditto "$TMP_DIR/AgentIsland.app" "$TARGET_APP_DIR/AgentIsland.app"
  xattr -dr com.apple.quarantine "$TARGET_APP_DIR/AgentIsland.app" >/dev/null 2>&1 || true
fi

echo ""
echo "Installed:"
echo "  CLI: $BIN_DIR/agentisland"
echo "  Helpers: $SHARE_DIR/scripts"
if [[ "$INSTALL_APP" -eq 1 ]]; then
  echo "  App: ${TARGET_APP_DIR:-$APP_DIR}/AgentIsland.app"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo ""
    echo "Add this to your shell profile if needed:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac
