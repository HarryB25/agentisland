import Foundation
import AgentIslandCore

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

    func start() {
        loadThreadNames()
        // First pass: catch up on anything written in the last 6h, then start polling.
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

            // On the very first pass, only catch up on the past 6 hours.
            // Old sessions are written-to-disk archives — replaying them would
            // spam the notch on startup.
            if initialCatchup && offsets[url.path] == nil && age > 6 * 3600 {
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
            let sid = (payload["id"] as? String) ?? UUID().uuidString
            let cwd = payload["cwd"] as? String
            let originator = payload["originator"] as? String ?? "Codex"
            meta[sessionFilePath] = CodexSessionMeta(sessionId: sid, cwd: cwd, originator: originator)
            // Create the initial state record so the agent shows up immediately.
            applyInitialState(for: sessionFilePath)
            return
        }

        guard let m = meta[sessionFilePath] else {
            // Records arriving before session_meta is processed — skip until we
            // have context for the file. Should not happen in practice.
            return
        }

        // ----- event_msg.* -----
        if recordType == "event_msg" {
            switch payloadType {
            case "task_started":
                update(for: m) { s in
                    s.status = .running
                    s.task = "Working on a turn"
                    s.needs_attention = false
                }
            case "user_message":
                let msg = (payload["message"] as? String) ?? ""
                update(for: m) { s in
                    s.status = .running
                    s.task = truncate(msg, 80)
                    s.needs_attention = false
                }
            case "agent_message":
                let msg = (payload["message"] as? String) ?? ""
                update(for: m) { s in
                    s.task = truncate(msg, 80)
                    s.tail = (s.tail + ["✓ replied"]).suffix(3).map { $0 }
                }
            case "task_complete":
                let last = (payload["last_agent_message"] as? String) ?? ""
                update(for: m) { s in
                    s.status = .idle
                    s.needs_attention = false
                    s.task = last.isEmpty ? "Idle" : truncate(last, 80)
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
                    s.task = truncate((payload["message"] as? String) ?? "error", 80)
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
                        s.task = "Thinking…"
                    }
                }
            case "function_call":
                let name = (payload["name"] as? String) ?? "tool"
                update(for: m) { s in
                    s.status = .running
                    s.task = "Using \(name)"
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
            ttl_seconds: 90
        )
        s.kind = "codex"
        s.display_name = displayName(for: m)
        s.cwd = m.cwd
        s.updated_at = Date()
        s.ttl_seconds = 90
        try? AgentStateIO.save(s)
    }

    private func update(for m: CodexSessionMeta, _ mutate: (inout AgentState) -> Void) {
        let id = "codex-\(String(m.sessionId.prefix(8)))"
        var s = AgentStateIO.load(id: id) ?? AgentState(
            agent_id: id, kind: "codex",
            display_name: displayName(for: m),
            status: .idle, cwd: m.cwd, ttl_seconds: 90
        )
        s.kind = "codex"
        s.display_name = displayName(for: m)
        s.cwd = m.cwd
        s.updated_at = Date()
        s.ttl_seconds = 90
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

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}

private struct CodexSessionMeta {
    let sessionId: String
    let cwd: String?
    let originator: String
}
