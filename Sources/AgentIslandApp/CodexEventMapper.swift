import Foundation
import AgentIslandCore

/// Parsed OTLP/JSON envelope (one POST /v1/logs payload may carry many records).
struct OTLPLogEnvelope {
    let records: [OTLPLogRecord]

    init(json data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OTLPError.malformed("root is not an object")
        }
        let resourceLogs = root["resourceLogs"] as? [[String: Any]] ?? []
        var out: [OTLPLogRecord] = []
        for rl in resourceLogs {
            let resourceAttrs = parseAttrs((rl["resource"] as? [String: Any])?["attributes"] as? [[String: Any]] ?? [])
            for sl in rl["scopeLogs"] as? [[String: Any]] ?? [] {
                let scopeName = ((sl["scope"] as? [String: Any])?["name"] as? String) ?? ""
                for rec in sl["logRecords"] as? [[String: Any]] ?? [] {
                    let body: String = {
                        if let b = rec["body"] as? [String: Any] {
                            return (b["stringValue"] as? String) ?? ""
                        }
                        return ""
                    }()
                    let attrs = parseAttrs(rec["attributes"] as? [[String: Any]] ?? [])
                    let severity = rec["severityText"] as? String ?? "INFO"
                    let merged = resourceAttrs.merging(attrs, uniquingKeysWith: { _, b in b })
                    out.append(OTLPLogRecord(
                        body: body, severity: severity, scopeName: scopeName, attributes: merged
                    ))
                }
            }
        }
        self.records = out
    }
}

struct OTLPLogRecord {
    let body: String
    let severity: String
    let scopeName: String
    let attributes: [String: String]

    func attr(_ keys: String...) -> String? {
        for k in keys { if let v = attributes[k] { return v } }
        return nil
    }
}

enum OTLPError: Error, LocalizedError {
    case malformed(String)
    var errorDescription: String? {
        switch self { case .malformed(let s): return "malformed OTLP: \(s)" }
    }
}

private func parseAttrs(_ raw: [[String: Any]]) -> [String: String] {
    var out: [String: String] = [:]
    for kv in raw {
        guard let key = kv["key"] as? String else { continue }
        guard let value = kv["value"] as? [String: Any] else { continue }
        if let s = value["stringValue"] as? String { out[key] = s; continue }
        if let n = value["intValue"]  { out[key] = "\(n)"; continue }
        if let n = value["doubleValue"] { out[key] = "\(n)"; continue }
        if let b = value["boolValue"] as? Bool { out[key] = "\(b)"; continue }
    }
    return out
}

// MARK: - Mapper

/// Translates OTel log records emitted by Codex (and other OTel-emitting agents)
/// into AgentState updates. Heuristic — exact event names depend on agent version,
/// so we match defensively on multiple candidate keys and fall through gracefully.
enum OTLPEventMapper {

    /// Apply an envelope of OTLP records to the on-disk state store.
    static func apply(_ envelope: OTLPLogEnvelope) {
        for record in envelope.records {
            apply(record)
        }
    }

    static func apply(_ record: OTLPLogRecord) {
        let serviceName = record.attr("service.name") ?? ""
        let kind = inferKind(serviceName: serviceName, scope: record.scopeName, body: record.body)
        guard !kind.isEmpty else { return }

        let sessionId = record.attr("session.id", "session_id", "codex.session_id",
                                    "claude_code.session.id", "service.instance.id") ?? "default"
        let id = "\(kind)-\(String(sessionId.prefix(8)))"
        let cwd = record.attr("cwd", "user.cwd", "codex.cwd", "claude_code.cwd")
        let existing = AgentStateIO.load(id: id)
        var state = existing ?? AgentState(
            agent_id: id,
            kind: kind,
            display_name: displayName(cwd: cwd, kind: kind),
            status: .idle,
            cwd: cwd
        )
        state.updated_at = Date()
        state.ttl_seconds = 600
        if let c = cwd { state.cwd = c }

        if AgentIslandLog.enabled {
            FileHandle.standardError.write(Data("[OTLP] kind=\(kind) sess=\(sessionId) sev=\(record.severity) body=\(record.body.prefix(120))\n".utf8))
        }

        applyEventLogic(kind: kind, record: record, into: &state)

        try? AgentStateIO.save(state)
    }

    private static func inferKind(serviceName: String, scope: String, body: String) -> String {
        let s = serviceName.lowercased()
        let sc = scope.lowercased()
        if s.contains("codex") || sc.contains("codex") { return "codex" }
        if s.contains("claude") || sc.contains("claude") { return "claude-code" }
        // Many OTel emitters don't set service.name. Fall back to scanning body / scope.
        if body.lowercased().contains("codex") { return "codex" }
        if body.lowercased().contains("claude") { return "claude-code" }
        return ""
    }

    private static func displayName(cwd: String?, kind: String) -> String {
        if let c = cwd, !c.isEmpty { return (c as NSString).lastPathComponent }
        return kind == "codex" ? "Codex" : kind
    }

    /// Map an event to a state update. Match against multiple candidate keys
    /// because event naming varies across versions.
    private static func applyEventLogic(kind: String, record: OTLPLogRecord, into state: inout AgentState) {
        // event.name is the OTel-canonical attribute Codex uses; some versions
        // pack the event type into the body string or a custom attribute.
        let event = (record.attr("event.name", "event", "codex.event", "claude_code.event") ?? "")
            .lowercased()
        let body = record.body.lowercased()

        // ---- Tool-call patterns ----
        if event.contains("tool") || event.contains("function_call")
            || body.contains("tool_call") || body.contains("function call") {
            let tool = record.attr("tool.name", "function.name", "codex.tool",
                                   "claude_code.tool_name") ?? "tool"
            state.status = .running
            state.task = "Using \(tool)"
            state.tail = (state.tail + ["→ \(tool)"]).suffix(3).map { $0 }
            return
        }

        // ---- Approval / permission required ----
        if event.contains("approval") || event.contains("permission")
            || body.contains("awaiting approval") || body.contains("permission request") {
            state.status = .waiting_input
            state.needs_attention = true
            let what = record.attr("tool.name", "command", "approval.target") ?? "input"
            state.task = "Approve \(what)?"
            return
        }

        // ---- User message / prompt ----
        if event.contains("user_message") || event.contains("user_prompt")
            || event.contains("prompt_submit") {
            let prompt = record.attr("user.prompt", "prompt", "user.message")
                ?? truncate(record.body, 80)
            state.status = .running
            state.needs_attention = false
            state.task = truncate(prompt, 80)
            return
        }

        // ---- Assistant response / turn end (idle but session still open) ----
        if event.contains("assistant_message") || event.contains("response_complete")
            || event.contains("turn_end") || event.contains("stop") {
            state.status = .idle
            state.needs_attention = false
            state.task = "Idle"
            return
        }

        // ---- Session lifecycle ----
        if event.contains("session_start") || body.contains("session started") {
            state.status = .idle
            state.task = "Session started"
            return
        }
        if event.contains("session_end") || body.contains("session ended") {
            state.status = .done
            state.needs_attention = false
            state.task = "Session ended"
            state.ttl_seconds = 30
            return
        }

        // ---- API request / inference in progress ----
        if event.contains("api_request") || event.contains("inference")
            || body.contains("calling model") || body.contains("api.request") {
            state.status = .running
            let model = record.attr("model", "model.name", "ai.model") ?? "model"
            state.task = "Thinking with \(model)"
            return
        }

        // ---- Errors ----
        if record.severity == "ERROR" || event.contains("error") {
            state.status = .error
            state.task = truncate(record.body.isEmpty ? "error" : record.body, 80)
            return
        }

        // ---- Fallback: heartbeat — keep prior status, just bump updated_at ----
        // (state.updated_at already set by caller)
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}

enum AgentIslandLog {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["AGENTISLAND_LOG"] != nil
    }
}
