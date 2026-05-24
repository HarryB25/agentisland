#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG_NAME="${1:-${AGENTISLAND_VERSION:-}}"
if [[ -z "$TAG_NAME" ]]; then
  TAG_NAME="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
fi
if [[ -z "$TAG_NAME" ]]; then
  TAG_NAME="v0.0.0-dev"
fi

VERSION="${TAG_NAME#v}"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) ;;
  *)
    echo "error: unsupported macOS architecture '$ARCH'" >&2
    exit 1
    ;;
esac

OUT_DIR="${OUT_DIR:-$ROOT/dist/$TAG_NAME}"
WORK_DIR="$OUT_DIR/.work"
APP_NAME="AgentIsland"
APP_BUNDLE="$WORK_DIR/$APP_NAME.app"
BUILD_DIR="$ROOT/.build/release"
APP_EXECUTABLE="$BUILD_DIR/AgentIslandApp"
CLI_EXECUTABLE="$BUILD_DIR/agentisland"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR" "$WORK_DIR"

echo "==> Building release binaries"
swift build -c release --package-path "$ROOT"

if [[ ! -x "$APP_EXECUTABLE" || ! -x "$CLI_EXECUTABLE" ]]; then
  echo "error: expected release products not found under $BUILD_DIR" >&2
  exit 1
fi

echo "==> Creating app bundle"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$APP_EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/AgentIslandApp"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>AgentIslandApp</string>
  <key>CFBundleIdentifier</key>
  <string>io.agentisland.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AgentIsland</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "==> Packaging desktop artifacts"
APP_ZIP="$OUT_DIR/agentisland-macos-$ARCH.zip"
(
  cd "$WORK_DIR"
  zip -qry -X "$APP_ZIP" "$APP_NAME.app"
)

DMG_STAGE="$WORK_DIR/dmg"
mkdir -p "$DMG_STAGE"
COPYFILE_DISABLE=1 ditto "$APP_BUNDLE" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
DMG_PATH="$OUT_DIR/agentisland-macos-$ARCH.dmg"
hdiutil create -volname "AgentIsland" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null

echo "==> Packaging CLI artifact"
CLI_STAGE="$WORK_DIR/agentisland-cli"
mkdir -p "$CLI_STAGE/bin" "$CLI_STAGE/share/agentisland/scripts"
cp "$CLI_EXECUTABLE" "$CLI_STAGE/bin/agentisland"
cp "$ROOT/scripts/install-codex.sh" "$CLI_STAGE/share/agentisland/scripts/install-codex.sh"
cp "$ROOT/scripts/install-claude-hooks.sh" "$CLI_STAGE/share/agentisland/scripts/install-claude-hooks.sh"
cp "$ROOT/LICENSE" "$CLI_STAGE/LICENSE"
CLI_TARBALL="$OUT_DIR/agentisland-cli-macos-$ARCH.tar.gz"
tar -C "$WORK_DIR" -czf "$CLI_TARBALL" agentisland-cli

echo "==> Writing install helper"
cp "$ROOT/scripts/release/install.sh" "$OUT_DIR/install.sh"
chmod +x "$OUT_DIR/install.sh"

echo "==> Writing checksums"
(
  cd "$OUT_DIR"
  shasum -a 256 \
    "agentisland-macos-$ARCH.zip" \
    "agentisland-macos-$ARCH.dmg" \
    "agentisland-cli-macos-$ARCH.tar.gz" \
    "install.sh" > "checksums-$ARCH.txt"
)

echo ""
echo "Release assets written to:"
echo "  $OUT_DIR"
ls -1 "$OUT_DIR"
