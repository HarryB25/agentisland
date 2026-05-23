# AgentIsland

A thing that lives in your MacBook notch. You always know what your agents are doing without looking at them, switching windows, or interrupting what you're doing.

You probably have several agents running on your machine — Claude Code, Codex, openclaw, Hermes, your own scripts. They run in different terminals, different windows. **You forget which ones are working, which are stuck waiting for your approval, and which finished an hour ago.** AgentIsland sits in the notch. Calm by default. Glows yellow when one needs you. Red when one errors out. Otherwise — silence.

> Status: early MVP. Works on macOS 13+. Currently ships a Claude Code hooks adapter and an OTLP/HTTP receiver for Codex; the protocol is intentionally simple so any agent can join.

## Color language (fixed, memorize once)

| Color | Meaning |
|---|---|
| 🟣 purple | thinking (inference / reasoning) |
| 🟢 green | running (executing a tool) |
| 🟡 yellow | needs you (approval, question, plan review) |
| 🔵 blue | done (finished, awaiting your dismissal) |
| 🔴 red | error |
| ⚪ gray | idle / stale |

**Ambient glow on the notch outline:** calm = no glow. Yellow when any agent needs you. Red when any errors. Running and thinking do **not** glow — they are background activity, not interruptions.

## Principles

1. **Don't interrupt.** Every feature must let you stay in your editor.
2. **Silence is default.** Calm = imperceptible. The pill surfaces only when needed.
3. **One glance, no thought.** Color = information. The mapping above is fixed.
4. **Open protocol.** Any agent that writes a JSON file gets a dot. Not tied to one product.
5. **Light.** < 50MB RAM, near-zero CPU, autostart, invisible.

![collapsed](docs/collapsed.png) ![expanded](docs/expanded.png)

## How it works

```
┌─────────────────────────────────────────────────┐
│   Notch UI (SwiftUI app, always on top)          │
└──────────────▲──────────────────────────────────┘
               │ reads
┌──────────────┴──────────────────────────────────┐
│   ~/.agentisland/state/<agent_id>.json           │  ← single source of truth
└──────────────▲──────────────────────────────────┘
               │ writes
   ┌───────────┼───────────┬─────────────┐
   │           │           │             │
Claude Code  Codex      Hermes       Your script
(via hooks)  (PTY wrap) (SDK)        (`agentisland report ...`)
```

Each agent writes a small JSON file. The UI watches the directory with FSEvents and renders. No daemon, no socket, no database. New adapters are ~20 lines.

## Quick start

Requires macOS 13+ and Swift 5.9 (`xcode-select --install`).

```bash
git clone https://github.com/YOUR/agentisland.git
cd agentisland
swift build -c release

# Run the UI (stays floating; quit with Cmd+Q from the Activity Monitor)
swift run AgentIslandApp &

# Drop demo agents to see all three status types
swift run agentisland demo
```

You should now see a black pill at the top-center of your screen with three colored dots — green (running), orange pulsing (needs attention), blue (idle). Hover to expand.

To put the CLI on your PATH:

```bash
sudo ln -sf "$(pwd)/.build/release/agentisland" /usr/local/bin/agentisland
```

## Connecting Claude Code

```bash
./scripts/install-claude-hooks.sh
```

This merges hook entries into `~/.claude/settings.json` so that Claude Code reports `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SessionEnd` to AgentIsland. Now every Claude Code session will appear in your pill while it works, turn orange when it's waiting for your approval, and disappear shortly after exit.

## Connecting Codex (OpenAI)

AgentIsland runs an OTLP/HTTP receiver on `127.0.0.1:4318/v1/logs` so Codex telemetry flows in with no hooks. Configure once:

```bash
./scripts/install-codex.sh
```

This appends an `[otel]` block to `~/.codex/config.toml` that points Codex's OTel exporter at the AgentIsland receiver (JSON protocol, logs only). Restart any running Codex sessions. They will show up in the pill with a `codex` icon (`</>`), track tool calls and approval requests, and clear on session end.

To verify the receiver is up: `curl http://127.0.0.1:4318/healthz` → `ok`.

If port 4318 is in use (e.g. you also run AgentNotch), AgentIsland logs the failure and runs without OTLP — hooks-based Claude Code reporting still works.

## Connecting anything else

Your script just needs to write a JSON file. Easiest way:

```bash
agentisland report \
  --id my-agent-1 \
  --kind custom \
  --name "Crawl filings" \
  --status running \
  --task "Downloading 10-Q PDFs..."

# When you need user input:
agentisland report --id my-agent-1 --status waiting_input --attention \
  --task "Approve download of 12 large PDFs?"

# When done:
agentisland report --id my-agent-1 --status done --task "12 PDFs saved"
```

Or in Python:

```python
import json, pathlib, time, datetime
p = pathlib.Path.home() / ".agentisland/state/my-agent.json"
p.parent.mkdir(parents=True, exist_ok=True)
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
p.write_text(json.dumps({
  "schema": 1, "agent_id": "my-agent", "kind": "python",
  "display_name": "Train model", "status": "running",
  "task": "Epoch 3/10", "started_at": now, "updated_at": now,
  "needs_attention": False, "tail": [], "ttl_seconds": 60,
}))
```

## State file schema (v1)

```json
{
  "schema": 1,
  "agent_id": "claude-7f3a",
  "kind": "claude-code",
  "display_name": "Refactor auth module",
  "status": "running",
  "task": "Editing src/auth/session.ts",
  "pid": 48211,
  "cwd": "/Users/me/proj/api",
  "started_at": "2026-05-23T10:12:03Z",
  "updated_at": "2026-05-23T10:14:51Z",
  "needs_attention": false,
  "tail": ["✓ Edit", "✓ Bash"],
  "ttl_seconds": 60
}
```

- `status`: `thinking` | `running` | `waiting_input` | `idle` | `done` | `error`
- `needs_attention`: lights the notch yellow + escalates the row. Use it for "user input required".
- `ttl_seconds`: if `updated_at` is older than this, the dot grays out as stale.

## Roadmap

- [x] P0 — SwiftUI notch UI + FS watcher + CLI
- [x] P1 — Claude Code hooks adapter
- [x] P2 — Codex via OTLP/HTTP receiver (port 4318, JSON protocol)
- [ ] P3 — In-notch approval / question answer / plan feedback (two-way protocol)
- [ ] P4 — Click-to-focus terminal (OSC 7 + AppleScript for Ghostty / iTerm2 / Terminal)
- [ ] P5 — Python / TS SDKs
- [ ] P6 — Quiet completion sound (optional, off by default)

**Explicitly not on the roadmap:** task history view, cloud sync / accounts, agent config management, any UI outside the notch.

## Contributing

Issues and PRs welcome. The protocol (`AgentState` in `Sources/AgentIslandCore/AgentState.swift`) is the load-bearing piece — discuss schema changes in an issue first.

## Support

If this saves you from losing track of a half-finished agent task, consider buying me a coffee: <https://buymeacoffee.com/> *(link TBD)*. No paid features, no telemetry, ever.

## License

MIT.
