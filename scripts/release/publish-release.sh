#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<EOF
Build release assets and publish a GitHub release.

Usage:
  publish-release.sh <tag> [--publish]

Examples:
  ./scripts/release/publish-release.sh v0.1.0
  ./scripts/release/publish-release.sh v0.1.0 --publish
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

TAG_NAME="$1"
shift
DRAFT=1
if [[ "${1:-}" == "--publish" ]]; then
  DRAFT=0
  shift
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI is required" >&2
  exit 1
fi

"$ROOT/scripts/release/build-release-assets.sh" "$TAG_NAME"

OUT_DIR="$ROOT/dist/$TAG_NAME"
TITLE="AgentIsland ${TAG_NAME#v}"
NOTES_FILE="$OUT_DIR/release-notes.md"

cat > "$NOTES_FILE" <<EOF
## AgentIsland ${TAG_NAME#v}

Assets in this release:

- \`agentisland-macos-arm64.dmg\`
- \`agentisland-macos-arm64.zip\`
- \`agentisland-cli-macos-arm64.tar.gz\`
- \`install.sh\`
- \`checksums-arm64.txt\`

Install options:

- Desktop app: download the DMG or use Homebrew Cask
- CLI: \`curl -fsSL https://github.com/HarryB25/agentisland/releases/latest/download/install.sh | bash\`
- CLI + app: \`curl -fsSL https://github.com/HarryB25/agentisland/releases/latest/download/install.sh | bash -s -- --app\`
EOF

if gh release view "$TAG_NAME" --repo HarryB25/agentisland >/dev/null 2>&1; then
  gh release upload "$TAG_NAME" "$OUT_DIR"/* --clobber --repo HarryB25/agentisland
  gh release edit "$TAG_NAME" --notes-file "$NOTES_FILE" --title "$TITLE" --repo HarryB25/agentisland
else
  args=(release create "$TAG_NAME" "$OUT_DIR"/* --title "$TITLE" --notes-file "$NOTES_FILE" --repo HarryB25/agentisland)
  if [[ "$DRAFT" -eq 1 ]]; then
    args+=(--draft)
  fi
  gh "${args[@]}"
fi
