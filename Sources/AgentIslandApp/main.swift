import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: AgentStore!
    var host: NotchHostController!
    var otlp: OTLPReceiver!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let store = AgentStore()
        self.store = store
        self.host = NotchHostController(store: store)
        self.host.show()

        // OTLP receiver: brings Codex (and OTel-emitting Claude Code) telemetry
        // in without requiring per-agent hooks.
        self.otlp = OTLPReceiver { envelope in
            DispatchQueue.global(qos: .utility).async {
                OTLPEventMapper.apply(envelope)
            }
        }
        self.otlp.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
