import Foundation
import Combine
import AgentIslandCore

/// Watches ~/.agentisland/state/ and publishes the current list of agents.
@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var agents: [AgentState] = []

    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var pollTimer: Timer?

    init() {
        try? AgentStatePaths.ensureDirs()
        reload()
        startWatching()
        // Polling fallback (catches in-place atomic renames cleanly + refreshes stale flags)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        dirSource?.cancel()
        if dirFD >= 0 { close(dirFD) }
        pollTimer?.invalidate()
    }

    func reload() {
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
        if loaded != self.agents {
            self.agents = loaded
        } else {
            // force objectWillChange for stale flag re-evaluation
            self.objectWillChange.send()
        }
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
}
