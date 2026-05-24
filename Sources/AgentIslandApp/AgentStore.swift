import Foundation
import Combine
import AgentIslandCore

/// Watches ~/.agentisland/state/ and publishes the current list of agents.
@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var agents: [AgentState] = []

    /// Increments whenever an agent newly enters a state that should briefly
    /// surface itself without requiring hover: attention, error, or done.
    @Published private(set) var autoPeekTick: Int = 0

    private var stateDirSource: DispatchSourceFileSystemObject?
    private var stateFD: Int32 = -1
    private var pollTimer: Timer?

    private var previousAutoPeekKeys: Set<String> = []

    private enum DisplayPolicy {
        static let completedVisibleDuration: TimeInterval = 45
    }

    init() {
        try? AgentStatePaths.ensureDirs()
        reload(initial: true)
        startWatching()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        stateDirSource?.cancel()
        if stateFD >= 0 { close(stateFD) }
        pollTimer?.invalidate()
    }

    func reload(initial: Bool = false) {
        let dir = AgentStatePaths.stateDir
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            self.agents = []
            return
        }
        var loaded: [AgentState] = []
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f),
               let s = try? JSONDecoder.agentIsland.decode(AgentState.self, from: data) {
                loaded.append(s)
            }
        }
        loaded.sort { $0.started_at < $1.started_at }

        let visible = Self.displayableAgents(from: loaded)
        let shouldAutoPeek: Bool

        if !initial {
            shouldAutoPeek = updateTransitionSnapshot(newAgents: visible)
        } else {
            previousAutoPeekKeys = Set(visible.flatMap(Self.autoPeekKeys(for:)))
            shouldAutoPeek = false
        }

        if loaded != self.agents {
            self.agents = loaded
        } else {
            // refresh stale flag even when nothing else changed
            self.objectWillChange.send()
        }

        if shouldAutoPeek {
            autoPeekTick &+= 1
        }
    }

    private func updateTransitionSnapshot(newAgents: [AgentState]) -> Bool {
        let currentAutoPeek = Set(newAgents.flatMap(Self.autoPeekKeys(for:)))
        let newlyAutoPeek = currentAutoPeek.subtracting(previousAutoPeekKeys)
        previousAutoPeekKeys = currentAutoPeek
        return !newlyAutoPeek.isEmpty
    }

    private static func autoPeekKeys(for agent: AgentState) -> [String] {
        var keys: [String] = []
        if agent.needs_attention {
            keys.append("\(agent.agent_id):attention")
        }
        if agent.status == .waiting_input {
            keys.append("\(agent.agent_id):waiting_input")
        }
        if agent.status == .error {
            keys.append("\(agent.agent_id):error")
        }
        if agent.status == .done {
            keys.append("\(agent.agent_id):done")
        }
        return keys
    }

    var visibleAgents: [AgentState] {
        Self.displayableAgents(from: agents)
    }

    private static func displayableAgents(from agents: [AgentState], now: Date = Date()) -> [AgentState] {
        agents.filter { isDisplayable($0, now: now) }
    }

    private static func isDisplayable(_ agent: AgentState, now: Date) -> Bool {
        let age = now.timeIntervalSince(agent.updated_at)
        guard age <= Double(agent.ttl_seconds) else { return false }
        guard agent.status != .idle else { return false }

        // Completed transcript turns are useful as a short confirmation, but
        // should not look like live work for minutes after a session ended.
        if agent.status == .done, age > DisplayPolicy.completedVisibleDuration {
            return false
        }

        return true
    }

    private func startWatching() {
        let stateDir = AgentStatePaths.stateDir
        let sfd = open(stateDir.path, O_EVTONLY)
        if sfd >= 0 {
            self.stateFD = sfd
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: sfd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .main
            )
            src.setEventHandler { [weak self] in self?.reload() }
            src.resume()
            self.stateDirSource = src
        }
    }

    /// Single agent that "owns" the attention — the most recently updated one needing input.
    var attentionAgent: AgentState? {
        visibleAgents.filter { $0.needs_attention }.max { $0.updated_at < $1.updated_at }
    }

    /// The agent that should drive the compact sentinel dot color.
    /// Priority: errors → needs-you → thinking/running → done. Nil if none qualifies
    /// (all idle or stale), which keeps the notch invisible in compact.
    var sentinelAgent: AgentState? {
        let active = visibleAgents
        let priority: (AgentState) -> Int = { a in
            if a.status == .error { return 0 }
            if a.needs_attention || a.status == .waiting_input { return 1 }
            if a.status == .thinking || a.status == .running { return 2 }
            if a.status == .done { return 3 }
            return 4
        }
        return active.min { priority($0) < priority($1) }
    }
}
