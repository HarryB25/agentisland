import AppKit
import SwiftUI
import Combine

/// Geometry of the notch (real on M1 Pro/Max+, synthesized on non-notched displays).
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let centerX: CGFloat
    let topY: CGFloat        // y-coordinate of screen's top edge (AppKit: maxY)
    let hasRealNotch: Bool

    static func current(for screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top  // > 0 on notched displays
        let real = topInset > 0

        let notchH: CGFloat = real ? topInset : 32
        let notchW: CGFloat
        if real {
            // The notch is the horizontal gap between the two auxiliary top areas.
            let leftMaxX = screen.auxiliaryTopLeftArea?.maxX ?? frame.midX - 100
            let rightMinX = screen.auxiliaryTopRightArea?.minX ?? frame.midX + 100
            notchW = max(160, rightMinX - leftMaxX)
        } else {
            notchW = 200
        }
        return NotchGeometry(
            screenFrame: frame,
            notchWidth: notchW,
            notchHeight: notchH,
            centerX: frame.midX,
            topY: frame.maxY,
            hasRealNotch: real
        )
    }
}

/// Borderless panel pinned flush with the top of the display, centered over the notch.
final class NotchPanel: NSPanel {
    init(rootView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.isMovable = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = true
        self.contentView = rootView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setFrameForGeometry(_ geo: NotchGeometry, contentWidth: CGFloat, contentHeight: CGFloat, animated: Bool) {
        let x = geo.centerX - contentWidth / 2
        let y = geo.topY - contentHeight
        let rect = NSRect(x: x, y: y, width: contentWidth, height: contentHeight)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.34
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1.0)
                self.animator().setFrame(rect, display: true)
            }
        } else {
            self.setFrame(rect, display: true)
        }
    }
}

/// Drives state transitions and hosts the SwiftUI content.
@MainActor
final class NotchHostController {
    private let store: AgentStore
    private let panel: NotchPanel
    private var geometry: NotchGeometry
    private let rootContainer: HoverTrackingView
    private var hostingView: NSHostingView<AnyView>!

    private var uiState: NotchUIState = .compact {
        didSet { if oldValue != uiState { rebuildView(); layout(animated: true) } }
    }
    private var hoverActive: Bool = false
    private var autoPeekUntil: Date = .distantPast

    private var cancellables: Set<AnyCancellable> = []
    private var tickTimer: Timer?

    init(store: AgentStore) {
        self.store = store
        self.geometry = NotchGeometry.current(for: NSScreen.main ?? NSScreen.screens[0])
        self.rootContainer = HoverTrackingView()
        self.panel = NotchPanel(rootView: rootContainer)

        rebuildHostingView()
        rootContainer.onHoverChange = { [weak self] hovering in
            self?.hoverActive = hovering
            self?.recomputeState()
        }

        // Trigger auto-peek when something newly needs attention.
        store.$attentionTick
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.beginAutoPeek(duration: 6) }
            .store(in: &cancellables)

        // Brief peek on any status change.
        store.$statusChangeTick
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.beginAutoPeek(duration: 2.5) }
            .store(in: &cancellables)

        // Tick to evaluate auto-peek expiry and refresh elapsed labels.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        // Re-evaluate when agents change (e.g. an attention clears).
        store.$agents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tick() }
            .store(in: &cancellables)

        // Re-detect geometry on display changes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshGeometry() }
        }
    }

    func show() {
        panel.orderFrontRegardless()
        layout(animated: false)
    }

    private func tick() {
        recomputeState()
        // Re-layout each tick so expanded height tracks agent count.
        layout(animated: true)
    }

    private func recomputeState() {
        let now = Date()
        let autoPeeking = now < autoPeekUntil
        let hasPending = store.attentionAgent != nil
        let hasRunning = store.agents.contains { !$0.isStale && $0.status == .running }

        let target: NotchUIState
        if hoverActive {
            target = .expanded
        } else if hasPending {
            target = .peek                       // attention always peeks until resolved
        } else if autoPeeking && (hasRunning || !store.agents.isEmpty) {
            target = .peek
        } else {
            target = .compact
        }
        if target != uiState { uiState = target }
    }

    private func beginAutoPeek(duration: TimeInterval) {
        autoPeekUntil = Date().addingTimeInterval(duration)
        recomputeState()
    }

    private func refreshGeometry() {
        guard let screen = NSScreen.main else { return }
        let g = NotchGeometry.current(for: screen)
        if g != geometry {
            geometry = g
            rebuildView()
            layout(animated: false)
        }
    }

    // MARK: layout

    private func contentSize(for state: NotchUIState) -> CGSize {
        let g = geometry
        switch state {
        case .compact:
            return CGSize(width: g.notchWidth, height: g.notchHeight)
        case .peek:
            let w = max(g.notchWidth + 80, 360)
            return CGSize(width: w, height: g.notchHeight + 22)
        case .expanded:
            let n = store.agents.count
            let listH = n == 0 ? 32 : CGFloat(n) * 46 + 4
            let w = max(g.notchWidth + 180, 460)
            let h = g.notchHeight + 40 /* header */ + listH + 16
            return CGSize(width: w, height: h)
        }
    }

    private func layout(animated: Bool) {
        let size = contentSize(for: uiState)
        panel.setFrameForGeometry(geometry,
                                  contentWidth: size.width,
                                  contentHeight: size.height,
                                  animated: animated)
    }

    private func rebuildHostingView() {
        let view = NotchView(store: store, geometry: geometry, uiState: uiState)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.subviews.forEach { $0.removeFromSuperview() }
        rootContainer.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
        ])
        self.hostingView = hosting
    }

    private func rebuildView() {
        hostingView.rootView = AnyView(
            NotchView(store: store, geometry: geometry, uiState: uiState)
        )
    }
}

/// NSView that reports mouse enter/exit with a tolerance margin so the
/// expand gesture feels generous (matches iOS Dynamic Island).
final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var tracker: NSTrackingArea?

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracker { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(t)
        tracker = t
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent)  { onHoverChange?(false) }
}
