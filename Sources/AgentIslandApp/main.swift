import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: AgentStore!
    var host: NotchHostController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let store = AgentStore()
        self.store = store
        self.host = NotchHostController(store: store)
        self.host.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
