import Foundation
import Combine
import AgentIslandCore

/// Watches ~/.agentisland/state/ and publishes the current list of agents.
@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var agents: [AgentState] = []

    /// Increments whenever an agent newly enters the "needs attention" state.
    /// UI subscribes to drive an auto-peek attention attractor.
    @Published private(set) var attentionTick: Int = 0

    /// Increments whenever any agent transitions to a different status.
    /// Used for short status-change peeks.
    @Published private(set) var statusChangeTick: Int = 0

    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var pollTimer: Timer?

    private var previousAttentionIDs: Set<String> = []
    private var previousStatuses: [String: AgentState.Status] = [:]

    init() {
        try? AgentStatePaths.ensureDirs()
        reload(initial: true)
        startWatching()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        dirSource?.cancel()
        if dirFD >= 0 { close(dirFD) }
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

        if !initial {
            detectTransitions(newAgents: loaded)
        } else {
            previousAttentionIDs = Set(loaded.filter { $0.needs_attention }.map(\.agent_id))
            previousStatuses = Dictionary(uniqueKeysWithValues: loaded.map { ($0.agent_id, $0.status) })
        }

        if loaded != self.agents {
            self.agents = loaded
        } else {
            // refresh stale flag even when nothing else changed
            self.objectWillChange.send()
        }
    }

    private func detectTransitions(newAgents: [AgentState]) {
        // Newly-attention-needing agents trigger the attractor.
        let currentAttention = Set(newAgents.filter { $0.needs_attention }.map(\.agent_id))
        let newlyAttention = currentAttention.subtracting(previousAttentionIDs)
        if !newlyAttention.isEmpty {
            attentionTick &+= 1
        }
        previousAttentionIDs = currentAttention

        // General status change → brief peek.
        let newStatuses = Dictionary(uniqueKeysWithValues: newAgents.map { ($0.agent_id, $0.status) })
        var anyChanged = newlyAttention.isEmpty == false
        for (id, status) in newStatuses {
            if previousStatuses[id] != status { anyChanged = true; break }
        }
        // New agents appearing also counts.
        if !anyChanged {
            let oldIDs = Set(previousStatuses.keys)
            let newIDs = Set(newStatuses.keys)
            if !newIDs.subtracting(oldIDs).isEmpty { anyChanged = true }
        }
        if anyChanged { statusChangeTick &+= 1 }
        previousStatuses = newStatuses
    }

    private func startWatching() {
        let dir = AgentStatePaths.stateDir
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.dirFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.reload()
        }
        src.resume()
        self.dirSource = src
    }

    /// Single agent that "owns" the attention — the most recently updated one needing input.
    var attentionAgent: AgentState? {
        agents.filter { $0.needs_attention }.max { $0.updated_at < $1.updated_at }
    }
}
