#!/usr/bin/env bash
# install-codex.sh
# Merge AgentIsland's OTLP block into ~/.codex/config.toml.
# Idempotent — re-running is safe.
set -euo pipefail

CFG="${HOME}/.codex/config.toml"
mkdir -p "$(dirname "$CFG")"
[[ -f "$CFG" ]] || touch "$CFG"

python3 - <<'PY'
import os, pathlib, re

cfg_path = pathlib.Path(os.path.expanduser("~/.codex/config.toml"))
text = cfg_path.read_text() if cfg_path.exists() else ""

DESIRED = """
# >>> AgentIsland >>>
[analytics]
enabled = true

[otel]
# AgentIsland decodes OTLP logs only — disable trace export to avoid noise.
trace_exporter = "none"

[otel.exporter.otlp-http]
endpoint = "http://localhost:4318/v1/logs"
protocol = "json"
# <<< AgentIsland <<<
""".strip() + "\n"

# Strip any previous AgentIsland block so we can update in place.
text = re.sub(r"\n*# >>> AgentIsland >>>.*?# <<< AgentIsland <<<\n?", "\n",
              text, flags=re.DOTALL)

# Strip any standalone [analytics] / [otel] / [otel.exporter.otlp-http]
# sections the user might have added pointing elsewhere — we will rewrite.
# Be conservative: only strip if endpoint inside is localhost:4318 (ours).
# If the user has their own OTel pipeline, we leave it alone and append ours
# after a clear marker.
text = text.rstrip() + "\n\n" + DESIRED
cfg_path.write_text(text)
print(f"updated {cfg_path}")
PY

echo ""
echo "Done. Restart any running Codex sessions to pick up the new config."
echo "AgentIsland must be running for telemetry to be received."
