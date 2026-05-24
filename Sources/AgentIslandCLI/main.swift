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
case "reply":      try runReply(Array(args.dropFirst()))
case "wait":       try runWait(Array(args.dropFirst()))
case "replies":    runReplies(Array(args.dropFirst()))
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
                        [--task <text>] [--attention] [--pid <pid>]
                        [--focus-pid <pid>] [--cwd <path>]
                        [--request <request-id>]
                        [--phase <text>] [--progress <0...1>]
                        [--action <id:label:role>] [--tail <line>]
                        [--ttl <seconds>]
      agentisland wait --id <id>       Wait for and consume the next UI reply
                        [--request <request-id>] [--timeout <seconds>]
      agentisland reply --id <id>      Write a UI-style reply manually
                        --action <id> --label <text> --role <role>
                        [--request <request-id>] [--value <text>]
      agentisland replies --id <id>    List pending replies without consuming
      agentisland hook <event>           Read Claude Code hook JSON from stdin
                                         Events: SessionStart UserPromptSubmit
                                                 PreToolUse PostToolUse Notification
                                                 Stop SessionEnd
      agentisland list                   List current agents
      agentisland clear --id <id>        Remove a state file
      agentisland clear --all            Remove all state files
      agentisland demo                   Create demo agents (for testing UI)
      agentisland path                   Print state directory path

    STATUS values: thinking running waiting_input idle done error

    NOTES
      --focus-pid is the PID the notch will activate when the user clicks
      this agent (typically the parent terminal app's PID). If omitted, the
      notch falls back to --pid.
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
    if let requestID = argValue("--request", args) { state.request_id = requestID }
    if let phase = argValue("--phase", args) { state.phase_title = phase }
    if let t = argValue("--task", args) { state.task = t }
    if let progress = argValue("--progress", args), let value = Double(progress) {
        state.progress = min(max(value, 0), 1)
    }
    if argFlag("--attention", args) { state.needs_attention = true }
    if argFlag("--no-attention", args) { state.needs_attention = false }
    if let p = argValue("--pid", args), let pid = Int(p) { state.pid = pid }
    if let fp = argValue("--focus-pid", args), let pid = Int(fp) { state.focus_pid = pid }
    if let c = argValue("--cwd", args) { state.cwd = c }
    if let ttl = argValue("--ttl", args), let n = Int(ttl) { state.ttl_seconds = n }
    let newTails = argValues("--tail", args)
    if !newTails.isEmpty {
        state.tail = (state.tail + newTails).suffix(3).map { $0 }
    }
    let actionValues = argValues("--action", args)
    if !actionValues.isEmpty {
        state.actions = actionValues.compactMap(parseAction)
    }
    try AgentStateIO.save(state)
}

func runReply(_ args: [String]) throws {
    guard let id = argValue("--id", args) else { die("--id required") }
    guard let actionID = argValue("--action", args) else { die("--action required") }
    let label = argValue("--label", args) ?? actionID
    let roleText = argValue("--role", args) ?? "option"
    guard let role = AgentState.Action.Role(rawValue: roleText) else {
        die("invalid --role: \(roleText)")
    }
    let reply = AgentReply(
        agent_id: id,
        request_id: argValue("--request", args),
        action_id: actionID,
        action_label: label,
        role: role,
        value: argValue("--value", args)
    )
    try AgentReplyIO.save(reply)
    printReply(reply)
}

func runWait(_ args: [String]) throws {
    guard let id = argValue("--id", args) else { die("--id required") }
    let timeout = argValue("--timeout", args).flatMap(Double.init) ?? 3600
    guard let reply = AgentReplyIO.wait(
        agentID: id,
        requestID: argValue("--request", args),
        timeout: timeout
    ) else {
        exit(1)
    }
    printReply(reply)
}

func runReplies(_ args: [String]) {
    guard let id = argValue("--id", args) else { die("--id required") }
    let replies = AgentReplyIO.list(agentID: id, requestID: argValue("--request", args))
    if replies.isEmpty { print("(no replies)"); return }
    for reply in replies {
        printReply(reply)
    }
}

func runList() {
    let agents = AgentStateIO.listAll()
    if agents.isEmpty { print("(no agents)"); return }
    for a in agents {
        let attn = a.needs_attention ? " ⚠" : ""
        let phase = a.phase_title.map { " \($0)" } ?? ""
        let progress = a.progress.map { " \(Int((min(max($0, 0), 1) * 100).rounded()))%" } ?? ""
        let task = a.task.map { " — \($0)" } ?? ""
        print("\(a.agent_id)  \(a.kind)  [\(a.status.rawValue)\(phase)\(progress)]\(attn)  \(a.display_name)\(task)")
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
        agent_id: "demo-airjelly", kind: "custom",
        display_name: "AirJelly", status: .thinking,
        phase_title: "thinking",
        task: "分析 trading_engine.rs 架构...",
        started_at: Date().addingTimeInterval(-80),
        ttl_seconds: 600
    )
    let b = AgentState(
        agent_id: "demo-hermes", kind: "hermes",
        display_name: "Hermes", status: .running,
        phase_title: "running",
        task: "重构 OrderBook 模块",
        progress: 0.43,
        started_at: Date().addingTimeInterval(-45),
        ttl_seconds: 600
    )
    let c = AgentState(
        agent_id: "demo-claude", kind: "claude-code",
        display_name: "Claude Code", status: .waiting_input,
        request_id: "demo-approval-1",
        phase_title: "waiting",
        task: "需要批准：写入 auth/middleware.ts",
        started_at: Date().addingTimeInterval(-28),
        needs_attention: true,
        actions: [
            AgentState.Action(id: "allow", label: "Allow", role: .approve),
            AgentState.Action(id: "deny", label: "Deny", role: .deny),
        ],
        ttl_seconds: 600
    )
    let d = AgentState(
        agent_id: "demo-codex", kind: "codex",
        display_name: "Codex", status: .done,
        phase_title: "done",
        task: "调研报告完成 · 点击查看",
        progress: 1,
        started_at: Date().addingTimeInterval(-300),
        ttl_seconds: 600
    )
    try AgentStateIO.save(a)
    try AgentStateIO.save(b)
    try AgentStateIO.save(c)
    try AgentStateIO.save(d)
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
    // Walk up the hook process's ancestors to find the terminal app — used
    // by the notch's click-to-focus action.
    if state.focus_pid == nil, let pid = ancestorAppPID() {
        state.focus_pid = Int(pid)
    }

    switch event {
    case "SessionStart":
        state.status = .idle
        state.phase_title = nil
        state.task = "Session started"
        state.progress = nil
        state.actions = nil
    case "UserPromptSubmit":
        let prompt = (payload["prompt"] as? String) ?? ""
        let firstLine = prompt.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        state.status = .running
        state.phase_title = "running"
        state.needs_attention = false
        state.task = firstLine.isEmpty ? "Working..." : truncate(firstLine, 80)
        state.progress = nil
        state.actions = nil
    case "PreToolUse":
        let tool = payload["tool_name"] as? String ?? "?"
        state.status = .running
        state.phase_title = "running"
        state.task = "Using \(tool)"
        state.progress = nil
        state.actions = nil
    case "PostToolUse":
        let tool = payload["tool_name"] as? String ?? "?"
        state.tail = (state.tail + ["✓ \(tool)"]).suffix(3).map { $0 }
    case "Notification":
        let msg = payload["message"] as? String ?? "needs input"
        state.status = .waiting_input
        state.phase_title = "waiting"
        state.needs_attention = true
        state.task = truncate(msg, 80)
        state.progress = nil
        state.actions = [
            AgentState.Action(id: "allow", label: "Allow", role: .approve),
            AgentState.Action(id: "deny", label: "Deny", role: .deny),
        ]
    case "Stop", "SubagentStop":
        state.status = .done
        state.phase_title = "done"
        state.needs_attention = false
        state.task = "Completed"
        state.progress = 1
        state.actions = nil
        state.ttl_seconds = 300
    case "SessionEnd":
        state.status = .done
        state.phase_title = "done"
        state.needs_attention = false
        state.task = "Session ended"
        state.progress = 1
        state.actions = nil
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

func parseAction(_ value: String) -> AgentState.Action? {
    let parts = value.split(separator: ":", maxSplits: 2).map(String.init)
    guard parts.count == 3, let role = AgentState.Action.Role(rawValue: parts[2]) else {
        return nil
    }
    return AgentState.Action(id: parts[0], label: parts[1], role: role)
}

func printReply(_ reply: AgentReply) {
    guard let data = try? JSONEncoder.agentIsland.encode(reply),
          let text = String(data: data, encoding: .utf8) else {
        return
    }
    print(text)
}

// MARK: - Utilities

/// Walk the current process's ancestor chain looking for a PID that belongs
/// to a regular macOS app (typically the terminal that hosts this hook).
/// Returns nil if nothing focusable is found within a reasonable depth.
func ancestorAppPID() -> pid_t? {
    var pid = getppid()  // start from parent, not self (we ARE the hook CLI)
    for _ in 0..<12 {
        if pid <= 1 { return nil }
        if isAppPID(pid) { return pid }
        let parent = parentPID(of: pid)
        if parent == pid { return nil }
        pid = parent
    }
    return nil
}

/// True when `pid` corresponds to a regular Cocoa app (has a bundle).
/// Uses libproc to check the BSD info bit `PROC_FLAG_LP64` is not sufficient;
/// instead we shell out to `ps` to read the process's comm + check that it
/// resolves to an .app via `lsappinfo`-style heuristics. Cheap and reliable:
/// we just try `NSRunningApplication(processIdentifier:)` indirectly by
/// reading the bundle path via libproc's proc_pidpath.
func isAppPID(_ pid: pid_t) -> Bool {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return false }
    let path = String(cString: buf)
    // Heuristic: real apps live inside an .app bundle.
    return path.contains(".app/Contents/MacOS/")
}

func parentPID(of pid: pid_t) -> pid_t {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let r = mib.withUnsafeMutableBufferPointer { ptr -> Int32 in
        sysctl(ptr.baseAddress, u_int(ptr.count), &info, &size, nil, 0)
    }
    if r != 0 || size == 0 { return 0 }
    return info.kp_eproc.e_ppid
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}
