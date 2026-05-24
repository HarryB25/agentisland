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
HOST_ARCH="$(uname -m)"
ARCHES_INPUT="${AGENTISLAND_ARCHES:-$HOST_ARCH}"
read -r -a ARCHES <<< "$ARCHES_INPUT"

validate_arch() {
  case "$1" in
    arm64|x86_64) ;;
    *)
      echo "error: unsupported macOS architecture '$1'" >&2
      exit 1
      ;;
  esac
}

for arch in "${ARCHES[@]}"; do
  validate_arch "$arch"
done

OUT_DIR="${OUT_DIR:-$ROOT/dist/$TAG_NAME}"
WORK_DIR="$OUT_DIR/.work"
APP_NAME="AgentIsland"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR" "$WORK_DIR"

package_arch() {
  local arch="$1"
  local build_dir="$ROOT/.build/${arch}-apple-macosx/release"
  local app_executable="$build_dir/AgentIslandApp"
  local cli_executable="$build_dir/agentisland"
  local arch_work="$WORK_DIR/$arch"
  local app_bundle="$arch_work/$APP_NAME.app"
  local app_zip="$OUT_DIR/agentisland-macos-$arch.zip"
  local dmg_path="$OUT_DIR/agentisland-macos-$arch.dmg"
  local cli_tarball="$OUT_DIR/agentisland-cli-macos-$arch.tar.gz"

  echo "==> Building release binaries for $arch"
  swift build -c release --package-path "$ROOT" --arch "$arch"

  if [[ ! -x "$app_executable" || ! -x "$cli_executable" ]]; then
    echo "error: expected release products not found under $build_dir" >&2
    exit 1
  fi

  echo "==> Creating app bundle for $arch"
  mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
  cp "$app_executable" "$app_bundle/Contents/MacOS/AgentIslandApp"
  cat > "$app_bundle/Contents/Info.plist" <<PLIST
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
    codesign --force --deep --sign - "$app_bundle" >/dev/null 2>&1 || true
  fi
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$app_bundle" >/dev/null 2>&1 || true
  fi

  echo "==> Packaging desktop artifacts for $arch"
  (
    cd "$arch_work"
    zip -qry -X "$app_zip" "$APP_NAME.app"
  )

  local dmg_stage="$arch_work/dmg"
  mkdir -p "$dmg_stage"
  COPYFILE_DISABLE=1 ditto "$app_bundle" "$dmg_stage/$APP_NAME.app"
  ln -s /Applications "$dmg_stage/Applications"
  hdiutil create -volname "AgentIsland" -srcfolder "$dmg_stage" -ov -format UDZO "$dmg_path" >/dev/null

  echo "==> Packaging CLI artifact for $arch"
  local cli_stage="$arch_work/agentisland-cli"
  mkdir -p "$cli_stage/bin" "$cli_stage/share/agentisland/scripts"
  cp "$cli_executable" "$cli_stage/bin/agentisland"
  cp "$ROOT/scripts/install-codex.sh" "$cli_stage/share/agentisland/scripts/install-codex.sh"
  cp "$ROOT/scripts/install-claude-hooks.sh" "$cli_stage/share/agentisland/scripts/install-claude-hooks.sh"
  cp "$ROOT/LICENSE" "$cli_stage/LICENSE"
  tar -C "$arch_work" -czf "$cli_tarball" agentisland-cli

  echo "==> Writing checksums for $arch"
  (
    cd "$OUT_DIR"
    shasum -a 256 \
      "agentisland-macos-$arch.zip" \
      "agentisland-macos-$arch.dmg" \
      "agentisland-cli-macos-$arch.tar.gz" \
      "install.sh" > "checksums-$arch.txt"
  )
}

echo "==> Writing shared install helper"
cp "$ROOT/scripts/release/install.sh" "$OUT_DIR/install.sh"
chmod +x "$OUT_DIR/install.sh"

for arch in "${ARCHES[@]}"; do
  package_arch "$arch"
done

echo ""
echo "Release assets written to:"
echo "  $OUT_DIR"
ls -1 "$OUT_DIR"
