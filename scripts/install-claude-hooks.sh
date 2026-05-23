#!/usr/bin/env bash
# install-claude-hooks.sh
# Merge AgentIsland hooks into ~/.claude/settings.json using the absolute
# path to the locally-built agentisland binary (no sudo, no PATH dance).
# Idempotent — re-running is safe.
set -euo pipefail

SETTINGS="${HOME}/.claude/settings.json"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# Pick the freshest of release/debug.
BIN_RELEASE="$REPO/.build/release/agentisland"
BIN_DEBUG="$REPO/.build/debug/agentisland"
if [[ -x "$BIN_RELEASE" && ( ! -x "$BIN_DEBUG" || "$BIN_RELEASE" -nt "$BIN_DEBUG" ) ]]; then
  BIN="$BIN_RELEASE"
elif [[ -x "$BIN_DEBUG" ]]; then
  BIN="$BIN_DEBUG"
else
  echo "error: agentisland binary not found. Run 'swift build' first." >&2
  exit 1
fi
echo "Using binary: $BIN"

mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo "{}" > "$SETTINGS"

python3 - "$BIN" "$SETTINGS" <<'PY'
import json, pathlib, sys

bin_path, settings_path_str = sys.argv[1], sys.argv[2]
settings_path = pathlib.Path(settings_path_str)
settings = json.loads(settings_path.read_text() or "{}")

EVENTS = [
    "SessionStart", "UserPromptSubmit",
    "PreToolUse", "PostToolUse",
    "Notification", "Stop", "SubagentStop", "SessionEnd",
]

settings.setdefault("hooks", {})
for event in EVENTS:
    existing = settings["hooks"].get(event, [])
    # Strip any previous AgentIsland entries (anything that contains
    # 'agentisland hook') so re-running is idempotent.
    cleaned = []
    for group in existing:
        keep = [h for h in group.get("hooks", [])
                if "agentisland hook" not in h.get("command", "")]
        if keep:
            cleaned.append({**group, "hooks": keep})
    cleaned.append({
        "hooks": [{
            "type": "command",
            "command": f"{bin_path} hook {event}",
        }]
    })
    settings["hooks"][event] = cleaned

settings_path.write_text(json.dumps(settings, indent=2))
print(f"updated {settings_path}")
PY

echo ""
echo "Done. Existing Claude Code sessions will pick up hooks on their next event."
echo "AgentIsland must be running (nohup .build/debug/AgentIsland & disown)."
