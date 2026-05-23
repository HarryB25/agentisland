import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: AgentStore!
    var host: NotchHostController!
    var otlp: OTLPReceiver!
    var codexReader: CodexTranscriptReader!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let store = AgentStore()
        self.store = store
        self.host = NotchHostController(store: store)
        self.host.show()

        // OTLP receiver: catches anything that emits OpenTelemetry (newer
        // Codex CLI, OTel-instrumented Claude Code, custom agents).
        self.otlp = OTLPReceiver { envelope in
            DispatchQueue.global(qos: .utility).async {
                OTLPEventMapper.apply(envelope)
            }
        }
        self.otlp.start()

        // Codex transcript reader: covers the Codex Desktop app and CLI
        // versions that don't emit OTel. Tails ~/.codex/sessions/.../*.jsonl
        // and maps task_started / reasoning / function_call / task_complete
        // to AgentState updates.
        self.codexReader = CodexTranscriptReader()
        self.codexReader.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
