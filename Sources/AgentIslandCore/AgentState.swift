import Foundation

/// On-disk state file format. Each agent writes one of these to
/// ~/.agentisland/state/<agent_id>.json
public struct AgentState: Codable, Identifiable, Equatable {
    public enum Status: String, Codable {
        case running, waiting_input, idle, done, error
    }

    public var schema: Int
    public var agent_id: String
    public var kind: String
    public var display_name: String
    public var status: Status
    public var task: String?
    public var pid: Int?
    public var cwd: String?
    public var started_at: Date
    public var updated_at: Date
    public var needs_attention: Bool
    public var tail: [String]
    public var ttl_seconds: Int

    public var id: String { agent_id }

    public var isStale: Bool {
        Date().timeIntervalSince(updated_at) > Double(ttl_seconds)
    }

    public init(
        schema: Int = 1,
        agent_id: String,
        kind: String,
        display_name: String,
        status: Status,
        task: String? = nil,
        pid: Int? = nil,
        cwd: String? = nil,
        started_at: Date = Date(),
        updated_at: Date = Date(),
        needs_attention: Bool = false,
        tail: [String] = [],
        ttl_seconds: Int = 60
    ) {
        self.schema = schema
        self.agent_id = agent_id
        self.kind = kind
        self.display_name = display_name
        self.status = status
        self.task = task
        self.pid = pid
        self.cwd = cwd
        self.started_at = started_at
        self.updated_at = updated_at
        self.needs_attention = needs_attention
        self.tail = tail
        self.ttl_seconds = ttl_seconds
    }
}

public enum AgentStatePaths {
    public static var root: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".agentisland", isDirectory: true)
    }
    public static var stateDir: URL { root.appendingPathComponent("state", isDirectory: true) }

    public static func ensureDirs() throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    public static func file(for id: String) -> URL {
        stateDir.appendingPathComponent("\(id).json")
    }
}

public extension JSONEncoder {
    static var agentIsland: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

public extension JSONDecoder {
    static var agentIsland: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Atomic load/save helpers.
public enum AgentStateIO {
    public static func load(id: String) -> AgentState? {
        let url = AgentStatePaths.file(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.agentIsland.decode(AgentState.self, from: data)
    }

    public static func save(_ state: AgentState) throws {
        try AgentStatePaths.ensureDirs()
        let url = AgentStatePaths.file(for: state.agent_id)
        let tmp = url.appendingPathExtension("tmp")
        let data = try JSONEncoder.agentIsland.encode(state)
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    public static func delete(id: String) {
        try? FileManager.default.removeItem(at: AgentStatePaths.file(for: id))
    }

    public static func listAll() -> [AgentState] {
        let dir = AgentStatePaths.stateDir
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [AgentState] = []
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f),
               let s = try? JSONDecoder.agentIsland.decode(AgentState.self, from: data) {
                out.append(s)
            }
        }
        return out.sorted { $0.started_at < $1.started_at }
    }
}
