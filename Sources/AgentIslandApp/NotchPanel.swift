import AppKit
import SwiftUI

/// Borderless floating panel pinned just below the menu bar, top-center.
/// On notched MacBooks it appears as an extension of the notch.
final class NotchPanel: NSPanel {
    init(rootView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = true

        self.contentView = rootView
        reposition(width: 100, height: 28)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition(width: CGFloat, height: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.frame
        let menuBarHeight: CGFloat = NSApp.mainMenu?.menuBarHeight ?? 24
        // Position: horizontally centered, top edge flush with bottom of menu bar.
        let x = visibleFrame.midX - width / 2
        let y = visibleFrame.maxY - menuBarHeight - height
        self.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true, animate: false)
    }
}

/// Hosts the SwiftUI view, owns a hover-tracking NSView, drives panel resize.
@MainActor
final class NotchHostController {
    private let store: AgentStore
    private let panel: NotchPanel
    private var expanded: Bool = false
    private let rootContainer: HoverTrackingView
    private var hostingView: NSHostingView<AnyView>!
    private var expandedBinding: Binding<Bool>!

    init(store: AgentStore) {
        self.store = store
        self.rootContainer = HoverTrackingView()
        self.panel = NotchPanel(rootView: rootContainer)
        self.expandedBinding = Binding(
            get: { [weak self] in self?.expanded ?? false },
            set: { [weak self] newValue in self?.setExpanded(newValue) }
        )
        let view = NotchView(store: store, expanded: self.expandedBinding)
        self.hostingView = NSHostingView(rootView: AnyView(view))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
        ])

        rootContainer.onHoverChange = { [weak self] hovering in
            self?.setExpanded(hovering)
        }

        // Refresh size each tick to follow agent count changes.
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSize() }
        }
    }

    func show() {
        panel.orderFrontRegardless()
        refreshSize()
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        // Push update through SwiftUI binding by re-creating root.
        let view = NotchView(store: store, expanded: expandedBinding)
        hostingView.rootView = AnyView(view)
        refreshSize()
    }

    private func refreshSize() {
        let n = store.agents.count
        let width: CGFloat = expanded ? 380 : max(100, CGFloat(40 + n * 14))
        let height: CGFloat = expanded ? max(80, CGFloat(56 + n * 44)) : 28
        panel.reposition(width: width, height: height)
    }
}

/// NSView that reports mouse enter/exit. Used to expand the pill on hover.
final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var tracker: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracker { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(t)
        tracker = t
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}
