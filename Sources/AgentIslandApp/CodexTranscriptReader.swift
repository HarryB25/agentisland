import Foundation
import AppKit
import AgentIslandCore

/// Bundle IDs we treat as "the Codex app you want to focus when you click
/// a codex agent in the notch". First hit wins.
private let codexBundleIDs: [String] = [
    "com.openai.codex",
    "com.openai.chatgpt",  // ChatGPT Desktop ships Codex inside it
]

private func codexAppPID() -> pid_t? {
    for bid in codexBundleIDs {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            return app.processIdentifier
        }
    }
    return nil
}


/// Tails Codex session transcripts at `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
///
/// Both the Codex CLI and Codex Desktop app write the same JSONL format here
/// (session_meta, event_msg, response_item, turn_context records). This
/// reader watches the directory tree, opens any file modified recently,
/// reads new bytes since last seen, and maps each record to an AgentState
/// update.
///
/// Why not OTLP? Codex CLI <= 0.36 has no OTel exporter. The newer `[otel]`
/// config block is v0.79+ only. Codex Desktop appears to skip OTel entirely.
/// The transcript path is the lowest-friction way to cover every Codex
/// variant the user might have installed.
final class CodexTranscriptReader {

    private let sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)
    private let indexFile: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/session_index.jsonl", isDirectory: false)

    /// path → next byte offset to read from
    private var offsets: [String: UInt64] = [:]
    /// path → session meta we extracted from the first session_meta record
    private var meta: [String: CodexSessionMeta] = [:]
    /// session_id → thread_name (display label), populated from session_index.jsonl
    private var threadNames: [String: String] = [:]

    private var timer: Timer?
    private let queue = DispatchQueue(label: "agentisland.codex", qos: .utility)
    private let initialCatchupWindow: TimeInterval = 90

    func start() {
        loadThreadNames()
        // First pass: catch up only on files that were touched very recently,
        // then tail new bytes. Replaying hours of archived transcripts on app
        // launch makes old Codex conversations look like live island tasks.
        // We poll because FSEvents on a deep tree with nightly-rotated dirs adds
        // complexity without enough benefit for files that write < 50 events/sec.
        queue.async { [weak self] in
            self?.scanOnce(initialCatchup: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.queue.async { self?.scanOnce(initialCatchup: false) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: scanning

    /// Walk recent session files, process whatever is new.
    private func scanOnce(initialCatchup: Bool) {
        loadThreadNames()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sessionsRoot,
                                             includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                             options: [.skipsHiddenFiles]) else { return }
        let now = Date()
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate,
                  let size = values.fileSize else { continue }
            let age = now.timeIntervalSince(mtime)

            // On the very first pass, only replay the active tail. Older
            // session files are archives; preload their metadata so future
            // appended records can still be interpreted, but do not emit UI
            // state for their historical contents.
            if initialCatchup && offsets[url.path] == nil && age > initialCatchupWindow {
                preloadSessionMeta(at: url)
                offsets[url.path] = UInt64(size)  // mark as fully consumed
                continue
            }
            // On subsequent passes, skip files we've already fully consumed and
            // that haven't changed.
            let lastOffset = offsets[url.path] ?? 0
            guard UInt64(size) > lastOffset else { continue }
            processFile(at: url, from: lastOffset)
        }
    }

    /// Read `[fromOffset, EOF)`, split into JSON lines, dispatch each. Updates the offset.
    private func processFile(at url: URL, from fromOffset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: fromOffset)
        } catch {
            offsets[url.path] = 0
            return
        }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        let endsWithNL = data.last == 0x0a
        var components = data.split(separator: 0x0a, omittingEmptySubsequences: false)
        // If the file doesn't end with a newline, the last component is a
        // partial line — leave it for the next pass.
        var incompleteTail: Data = Data()
        if !endsWithNL, let tail = components.last {
            incompleteTail = Data(tail)
            components.removeLast()
        }
        var consumedBytes: UInt64 = 0
        for component in components {
            consumedBytes += UInt64(component.count) + 1   // +1 for \n
            if component.isEmpty { continue }
            interpret(Data(component), sessionFilePath: url.path)
        }
        offsets[url.path] = fromOffset + consumedBytes
        _ = incompleteTail
    }

    private func preloadSessionMeta(at url: URL) {
        guard meta[url.path] == nil,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 256 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { return }

        for line in text.split(separator: "\n").prefix(80) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let recordType = obj["type"] as? String,
                  recordType == "session_meta",
                  let payload = obj["payload"] as? [String: Any] else { continue }
            meta[url.path] = sessionMeta(from: payload)
            return
        }
    }

    /// Quick refresh of session_id → thread_name from session_index.jsonl.
    private func loadThreadNames() {
        guard let data = try? Data(contentsOf: indexFile),
              let str = String(data: data, encoding: .utf8) else { return }
        for line in str.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? String else { continue }
            if let name = obj["thread_name"] as? String, !name.isEmpty {
                threadNames[id] = name
            }
        }
    }

    // MARK: interpret one record

    private func interpret(_ recordData: Data, sessionFilePath: String) {
        guard let rec = try? JSONSerialization.jsonObject(with: recordData) as? [String: Any] else { return }
        let recordType = rec["type"] as? String ?? ""
        let payload = rec["payload"] as? [String: Any] ?? [:]
        let payloadType = payload["type"] as? String ?? ""

        // ----- session_meta: capture metadata for this file -----
        if recordType == "session_meta" {
            let sessionMeta = sessionMeta(from: payload)
            meta[sessionFilePath] = sessionMeta
            guard !sessionMeta.isInternal else { return }
            // Create the initial state record so the agent shows up immediately.
            applyInitialState(for: sessionFilePath)
            return
        }

        guard let m = meta[sessionFilePath] else {
            // Records arriving before session_meta is processed — skip until we
            // have context for the file. Should not happen in practice.
            return
        }
        guard !m.isInternal else { return }

        // ----- event_msg.* -----
        if recordType == "event_msg" {
            switch payloadType {
            case "task_started":
                update(for: m) { s in
                    s.status = .running
                    s.phase_title = "running"
                    s.task = "Working on a turn"
                    s.progress = nil
                    s.actions = nil
                    s.needs_attention = false
                }
            case "user_message":
                let msg = (payload["message"] as? String) ?? ""
                update(for: m) { s in
                    s.status = .running
                    s.phase_title = "running"
                    s.task = truncate(msg, 80)
                    s.progress = nil
                    s.actions = nil
                    s.needs_attention = false
                }
            case "agent_message":
                let msg = (payload["message"] as? String) ?? ""
                update(for: m) { s in
                    s.task = displayTask(msg, fallback: s.task ?? "Replied")
                    s.tail = (s.tail + ["✓ replied"]).suffix(3).map { $0 }
                }
            case "task_complete":
                let last = (payload["last_agent_message"] as? String) ?? ""
                update(for: m) { s in
                    s.status = .done
                    s.phase_title = "done"
                    s.needs_attention = false
                    s.task = displayTask(last, fallback: "Completed")
                    s.progress = 1
                    s.actions = nil
                    s.ttl_seconds = 45
                }
            case "token_count":
                // Just a heartbeat — refresh updated_at, nothing else.
                update(for: m) { _ in }
            case "web_search_end":
                update(for: m) { s in
                    s.tail = (s.tail + ["✓ web search"]).suffix(3).map { $0 }
                }
            case "error":
                update(for: m) { s in
                    s.status = .error
                    s.phase_title = "error"
                    s.task = displayTask((payload["message"] as? String) ?? "", fallback: "Error")
                    s.progress = nil
                    s.actions = nil
                }
            default:
                update(for: m) { _ in }
            }
            return
        }

        // ----- response_item.* -----
        if recordType == "response_item" {
            switch payloadType {
            case "reasoning":
                update(for: m) { s in
                    if s.status != .waiting_input {
                        s.status = .thinking
                        s.phase_title = "thinking"
                        s.task = "Thinking…"
                        s.progress = nil
                        s.actions = nil
                    }
                }
            case "function_call":
                let name = (payload["name"] as? String) ?? "tool"
                update(for: m) { s in
                    s.status = .running
                    s.phase_title = "running"
                    s.task = "Using \(name)"
                    s.progress = nil
                    s.actions = nil
                }
            case "function_call_output":
                update(for: m) { s in
                    s.tail = (s.tail + ["✓ tool"]).suffix(3).map { $0 }
                }
            default:
                update(for: m) { _ in }
            }
            return
        }
    }

    // MARK: state plumbing

    private func applyInitialState(for path: String) {
        guard let m = meta[path] else { return }
        let id = "codex-\(String(m.sessionId.prefix(8)))"
        let existing = AgentStateIO.load(id: id)
        var s = existing ?? AgentState(
            agent_id: id,
            kind: "codex",
            display_name: displayName(for: m),
            status: .idle,
            cwd: m.cwd,
            ttl_seconds: 180
        )
        s.kind = "codex"
        s.display_name = displayName(for: m)
        s.cwd = m.cwd
        s.updated_at = Date()
        s.ttl_seconds = 180
        if s.focus_pid == nil, let pid = codexAppPID() {
            s.focus_pid = Int(pid)
        }
        try? AgentStateIO.save(s)
    }

    private func update(for m: CodexSessionMeta, _ mutate: (inout AgentState) -> Void) {
        let id = "codex-\(String(m.sessionId.prefix(8)))"
        var s = AgentStateIO.load(id: id) ?? AgentState(
            agent_id: id, kind: "codex",
            display_name: displayName(for: m),
            status: .idle, cwd: m.cwd, ttl_seconds: 180
        )
        s.kind = "codex"
        s.display_name = displayName(for: m)
        s.cwd = m.cwd
        s.updated_at = Date()
        s.ttl_seconds = 180
        mutate(&s)
        try? AgentStateIO.save(s)
    }

    private func displayName(for m: CodexSessionMeta) -> String {
        if let name = threadNames[m.sessionId], !name.isEmpty {
            return truncate(name, 40)
        }
        if let cwd = m.cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return m.originator
    }

    private func sessionMeta(from payload: [String: Any]) -> CodexSessionMeta {
        let sid = (payload["id"] as? String) ?? UUID().uuidString
        let cwd = payload["cwd"] as? String
        let originator = payload["originator"] as? String ?? "Codex"
        let threadSource = payload["thread_source"] as? String
        let source = payload["source"] as? [String: Any]
        let isInternal = threadSource == "subagent" || source?["subagent"] != nil
        return CodexSessionMeta(sessionId: sid, cwd: cwd, originator: originator, isInternal: isInternal)
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    private func displayTask(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if looksStructuredPayload(trimmed) {
            if trimmed.contains("\"outcome\"") || trimmed.contains("\"user_authorization\"") {
                return "Approval decision recorded"
            }
            return fallback
        }
        return truncate(trimmed, 80)
    }

    private func looksStructuredPayload(_ value: String) -> Bool {
        (value.hasPrefix("{") && value.hasSuffix("}"))
            || (value.hasPrefix("[") && value.hasSuffix("]"))
    }
}

private struct CodexSessionMeta {
    let sessionId: String
    let cwd: String?
    let originator: String
    let isInternal: Bool
}
