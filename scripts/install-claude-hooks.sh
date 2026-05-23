#!/usr/bin/env bash
# install-claude-hooks.sh
# Merge AgentIsland hooks into ~/.claude/settings.json.
# Idempotent — re-running is safe.
set -euo pipefail

SETTINGS="${HOME}/.claude/settings.json"
HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/hooks/claude-code-settings.example.json"

if ! command -v agentisland >/dev/null 2>&1; then
  echo "warning: 'agentisland' is not on PATH yet."
  echo "         After building, symlink it:  ln -sf \"$(pwd)/.build/release/agentisland\" /usr/local/bin/agentisland"
fi

mkdir -p "$(dirname "$SETTINGS")"
if [[ ! -f "$SETTINGS" ]]; then echo "{}" > "$SETTINGS"; fi

python3 - <<PY
import json, pathlib, sys
settings_path = pathlib.Path("${SETTINGS}")
hook_path     = pathlib.Path("${HOOK_SRC}")
settings = json.loads(settings_path.read_text() or "{}")
hooks_blob = json.loads(hook_path.read_text())["hooks"]
settings.setdefault("hooks", {})
for event, defs in hooks_blob.items():
    existing = settings["hooks"].get(event, [])
    # Filter out any prior AgentIsland entries to keep this idempotent.
    cleaned = []
    for group in existing:
        keep = []
        for h in group.get("hooks", []):
            if "agentisland hook" not in h.get("command", ""):
                keep.append(h)
        if keep:
            cleaned.append({**group, "hooks": keep})
    settings["hooks"][event] = cleaned + defs
settings_path.write_text(json.dumps(settings, indent=2))
print(f"updated {settings_path}")
PY
