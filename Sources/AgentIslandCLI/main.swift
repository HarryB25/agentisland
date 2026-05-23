import Foundation
import AgentIslandCore

// MARK: - CLI entry

let args = Array(CommandLine.arguments.dropFirst())

guard let cmd = args.first else {
    printUsage()
    exit(0)
}

switch cmd {
case "report":     try runReport(Array(args.dropFirst()))
case "hook":       try runHook(Array(args.dropFirst()))
case "list":       runList()
case "clear":      runClear(Array(args.dropFirst()))
case "demo":       try runDemo()
case "path":       print(AgentStatePaths.stateDir.path)
case "help", "-h", "--help": printUsage()
default:
    FileHandle.standardError.write(Data("unknown command: \(cmd)\n".utf8))
    printUsage()
    exit(2)
}

// MARK: - Commands

func printUsage() {
    print("""
    agentisland — status reporter for AgentIsland

    USAGE
      agentisland report --id <id> --kind <kind> --name <name> --status <status>
                        [--task <text>] [--attention] [--pid <pid>] [--cwd <path>]
                        [--tail <line>] [--ttl <seconds>]
      agentisland hook <event>           Read Claude Code hook JSON from stdin
                                         Events: SessionStart UserPromptSubmit
                                                 PreToolUse PostToolUse Notification
                                                 Stop SessionEnd
      agentisland list                   List current agents
      agentisland clear --id <id>        Remove a state file
      agentisland clear --all            Remove all state files
      agentisland demo                   Create demo agents (for testing UI)
      agentisland path                   Print state directory path

    STATUS values: running waiting_input idle done error
    """)
}

func argValue(_ key: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func argFlag(_ key: String, _ args: [String]) -> Bool {
    args.contains(key)
}

func argValues(_ key: String, _ args: [String]) -> [String] {
    var out: [String] = []
    var i = 0
    while i < args.count {
        if args[i] == key, i + 1 < args.count {
            out.append(args[i + 1]); i += 2
        } else { i += 1 }
    }
    return out
}

func runReport(_ args: [String]) throws {
    guard let id = argValue("--id", args) else { die("--id required") }
    let kind = argValue("--kind", args) ?? "custom"
    let name = argValue("--name", args) ?? id
    let statusStr = argValue("--status", args) ?? "running"
    guard let status = AgentState.Status(rawValue: statusStr) else {
        die("invalid --status: \(statusStr)")
    }
    let existing = AgentStateIO.load(id: id)
    var state = existing ?? AgentState(
        agent_id: id, kind: kind, display_name: name, status: status
    )
    state.kind = kind
    state.display_name = name
    state.status = status
    state.updated_at = Date()
    if let t = argValue("--task", args) { state.task = t }
    if argFlag("--attention", args) { state.needs_attention = true }
    if argFlag("--no-attention", args) { state.needs_attention = false }
    if let p = argValue("--pid", args), let pid = Int(p) { state.pid = pid }
    if let c = argValue("--cwd", args) { state.cwd = c }
    if let ttl = argValue("--ttl", args), let n = Int(ttl) { state.ttl_seconds = n }
    let newTails = argValues("--tail", args)
    if !newTails.isEmpty {
        state.tail = (state.tail + newTails).suffix(3).map { $0 }
    }
    try AgentStateIO.save(state)
}

func runList() {
    let agents = AgentStateIO.listAll()
    if agents.isEmpty { print("(no agents)"); return }
    for a in agents {
        let attn = a.needs_attention ? " ⚠" : ""
        let task = a.task.map { " — \($0)" } ?? ""
        print("\(a.agent_id)  \(a.kind)  [\(a.status.rawValue)]\(attn)  \(a.display_name)\(task)")
    }
}

func runClear(_ args: [String]) {
    if argFlag("--all", args) {
        for a in AgentStateIO.listAll() { AgentStateIO.delete(id: a.agent_id) }
        return
    }
    guard let id = argValue("--id", args) else { die("--id or --all required") }
    AgentStateIO.delete(id: id)
}

func runDemo() throws {
    let a = AgentState(
        agent_id: "demo-claude", kind: "claude-code",
        display_name: "Refactor auth module", status: .running,
        task: "Editing src/auth/session.ts", started_at: Date().addingTimeInterval(-120),
        tail: ["Edited session.ts", "Running tests..."], ttl_seconds: 600
    )
    let b = AgentState(
        agent_id: "demo-codex", kind: "codex",
        display_name: "Generate migration", status: .waiting_input,
        task: "Awaiting approval to write migrations/0042.sql",
        started_at: Date().addingTimeInterval(-45),
        needs_attention: true, ttl_seconds: 600
    )
    let c = AgentState(
        agent_id: "demo-hermes", kind: "hermes",
        display_name: "Crawl 10-Q filings", status: .idle,
        task: "Done. 12 PDFs in ~/Downloads/filings",
        started_at: Date().addingTimeInterval(-3600), ttl_seconds: 600
    )
    try AgentStateIO.save(a)
    try AgentStateIO.save(b)
    try AgentStateIO.save(c)
    print("demo agents written to \(AgentStatePaths.stateDir.path)")
}

// MARK: - Claude Code hook bridge

func runHook(_ args: [String]) throws {
    guard let event = args.first else { die("hook <event> required") }
    let data = FileHandle.standardInput.availableData
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        die("could not parse hook payload as JSON")
    }
    try handleHook(event: event, payload: json)
}

func handleHook(event: String, payload: [String: Any]) throws {
    let sessionId = (payload["session_id"] as? String) ?? "unknown"
    let id = "claude-\(sessionId.prefix(8))"
    let cwd = payload["cwd"] as? String
    let existing = AgentStateIO.load(id: id)
    var state = existing ?? AgentState(
        agent_id: id,
        kind: "claude-code",
        display_name: cwd.map { ($0 as NSString).lastPathComponent } ?? "Claude Code",
        status: .idle,
        cwd: cwd
    )
    state.updated_at = Date()
    state.ttl_seconds = 600
    if let c = cwd { state.cwd = c }

    switch event {
    case "SessionStart":
        state.status = .idle
        state.task = "Session started"
    case "UserPromptSubmit":
        let prompt = (payload["prompt"] as? String) ?? ""
        let firstLine = prompt.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        state.status = .running
        state.needs_attention = false
        state.task = firstLine.isEmpty ? "Working..." : truncate(firstLine, 80)
    case "PreToolUse":
        let tool = payload["tool_name"] as? String ?? "?"
        state.status = .running
        state.task = "Using \(tool)"
    case "PostToolUse":
        let tool = payload["tool_name"] as? String ?? "?"
        state.tail = (state.tail + ["✓ \(tool)"]).suffix(3).map { $0 }
    case "Notification":
        let msg = payload["message"] as? String ?? "needs input"
        state.status = .waiting_input
        state.needs_attention = true
        state.task = truncate(msg, 80)
    case "Stop", "SubagentStop":
        state.status = .idle
        state.needs_attention = false
        state.task = "Idle"
    case "SessionEnd":
        state.status = .done
        state.needs_attention = false
        state.task = "Session ended"
        // Keep file around briefly; UI will mark stale and fade.
        state.ttl_seconds = 30
    default:
        // unknown event — still bump updated_at as a heartbeat
        break
    }
    try AgentStateIO.save(state)
}

func truncate(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n - 1)) + "…"
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}
