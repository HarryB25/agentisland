import AppKit
import SwiftUI
import Combine

// MARK: - Geometry

struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let centerX: CGFloat       // physical notch's center on the screen
    let topY: CGFloat          // AppKit y-coord of screen's top edge (frame.maxY)
    let hasRealNotch: Bool
    let menuBarHeight: CGFloat

    static func current(for screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top
        let real = topInset > 0
        let menuBarH: CGFloat = real ? topInset : 24

        var notchW: CGFloat = 0
        var notchH: CGFloat = real ? topInset : 24
        if real,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            let gap = rightArea.minX - leftArea.maxX
            if gap > 100, gap < 400 { notchW = gap }
            notchH = max(notchH, leftArea.height)
        }
        if notchW == 0 {
            notchW = fallbackNotchWidth(forModel: hardwareModel(), hasRealNotch: real)
        }

        return NotchGeometry(
            screenFrame: frame,
            notchWidth: notchW,
            notchHeight: notchH,
            centerX: frame.midX,
            topY: frame.maxY,
            hasRealNotch: real,
            menuBarHeight: menuBarH
        )
    }
}

private func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var bytes = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &bytes, &size, nil, 0)
    return String(cString: bytes)
}

private func fallbackNotchWidth(forModel model: String, hasRealNotch: Bool) -> CGFloat {
    guard hasRealNotch else { return 180 }
    if model.hasPrefix("MacBookPro") { return 200 }
    if model.hasPrefix("MacBookAir") { return 175 }
    return 200
}

// MARK: - Panel

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
        self.acceptsMouseMovedEvents = false  // hover handled by global event monitor
        self.ignoresMouseEvents = true        // don't intercept clicks on the menu bar
        self.contentView = rootView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Place the window so the visible top edge is flush with the screen top.
    /// `centerXOffset` lets the window shift horizontally from the screen center
    /// (positive = right, negative = left) to make the wings asymmetric.
    func setFrame(geometry: NotchGeometry,
                  contentSize: CGSize,
                  centerXOffset: CGFloat,
                  animated: Bool) {
        let x = geometry.centerX + centerXOffset - contentSize.width / 2
        let y = geometry.topY - contentSize.height
        let rect = NSRect(x: x, y: y, width: contentSize.width, height: contentSize.height)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                // Matches the SwiftUI .timingCurve in NotchView. Single curve
                // for both window resize and content morph → no desync.
                ctx.duration = 0.42
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 1.0, 0.30, 1.0)
                self.animator().setFrame(rect, display: true)
            }
        } else {
            self.setFrame(rect, display: true)
        }
    }
}

// MARK: - Host controller

@MainActor
final class NotchHostController {
    private let store: AgentStore
    private let panel: NotchPanel
    private var geometry: NotchGeometry
    private let rootContainer: NSView
    private var hostingView: NSHostingView<AnyView>!

    private var uiState: NotchUIState = .compact {
        didSet {
            if oldValue != uiState {
                rebuildView()
                layout(animated: true)
            }
        }
    }
    private var hoverActive: Bool = false
    private var autoPeekUntil: Date = .distantPast

    private var cancellables: Set<AnyCancellable> = []
    private var tickTimer: Timer?
    private var lastLayoutContentSize: CGSize = .zero

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var hoverExitTimer: Timer?

    init(store: AgentStore) {
        self.store = store
        let screen = NSScreen.main ?? NSScreen.screens[0]
        self.geometry = NotchGeometry.current(for: screen)
        self.rootContainer = NSView()
        self.panel = NotchPanel(rootView: rootContainer)

        if ProcessInfo.processInfo.environment["AGENTISLAND_LOG"] != nil {
            FileHandle.standardError.write(Data("""
            [AgentIsland] geometry detected:
              hasRealNotch = \(geometry.hasRealNotch)
              notchWidth   = \(geometry.notchWidth)
              notchHeight  = \(geometry.notchHeight)
              menuBarH     = \(geometry.menuBarHeight)
              screen       = \(geometry.screenFrame)
              hw.model     = \(hardwareModel())

            """.utf8))
        }

        rebuildHostingView()
        setupMouseMonitoring()

        store.$attentionTick
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.beginAutoPeek(duration: 8) }
            .store(in: &cancellables)

        store.$statusChangeTick
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.beginAutoPeek(duration: 2.5) }
            .store(in: &cancellables)

        // Re-evaluate state (auto-peek expiry, agent list changes) — but don't
        // call layout() on every tick. Layout runs only when the computed
        // content size actually differs from the last applied size.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recomputeState() }
        }

        store.$agents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeState() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshGeometry() }
        }
    }

    deinit {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor  { NSEvent.removeMonitor(m) }
        tickTimer?.invalidate()
        hoverExitTimer?.invalidate()
    }

    func show() {
        panel.orderFrontRegardless()
        layout(animated: false)
    }

    // MARK: state machine

    private func recomputeState() {
        let autoPeeking = Date() < autoPeekUntil
        let target: NotchUIState
        if hoverActive {
            target = .expanded
        } else if autoPeeking && !store.agents.isEmpty {
            target = .peek
        } else {
            target = .compact
        }
        if target != uiState {
            uiState = target
        } else {
            // Same state — but agent count might have changed expanded height.
            layoutIfSizeChanged()
        }
    }

    private func beginAutoPeek(duration: TimeInterval) {
        autoPeekUntil = Date().addingTimeInterval(duration)
        recomputeState()
    }

    // MARK: layout

    private func bodySize(for state: NotchUIState) -> CGSize {
        let g = geometry
        switch state {
        case .compact:
            return .zero
        case .peek:
            let w = max(g.notchWidth + 80, 340)
            return CGSize(width: w, height: 46)
        case .expanded:
            let n = store.agents.count
            let listH = n == 0 ? 30 : CGFloat(n) * 46 + 4
            let w = max(g.notchWidth + 200, 480)
            let h = 36 + listH + 16
            return CGSize(width: w, height: h)
        }
    }

    private func windowSize(for state: NotchUIState) -> CGSize {
        let g = geometry
        let notchPieceWidth = g.notchWidth + NotchWings.total
        let body = bodySize(for: state)
        let totalW = max(notchPieceWidth, body.width)
        let totalH = g.notchHeight + body.height
        return CGSize(width: totalW, height: totalH)
    }

    private func layout(animated: Bool) {
        let size = windowSize(for: uiState)
        panel.setFrame(
            geometry: geometry,
            contentSize: size,
            centerXOffset: -NotchWings.centerBias,  // shift window LEFT for left-biased wings
            animated: animated
        )
        lastLayoutContentSize = size
    }

    /// Re-layout only when the computed size differs from the last applied one.
    /// Stops the panel from "breathing" on every tick.
    private func layoutIfSizeChanged() {
        let newSize = windowSize(for: uiState)
        if newSize != lastLayoutContentSize {
            layout(animated: true)
        }
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

    // MARK: hosting

    private func rebuildHostingView() {
        let view = NotchView(store: store, geometry: geometry, uiState: uiState,
                             bodySize: bodySize(for: uiState))
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
            NotchView(store: store, geometry: geometry, uiState: uiState,
                      bodySize: bodySize(for: uiState))
        )
    }

    // MARK: hover detection (global event monitor — does not depend on view bounds)

    private func setupMouseMonitoring() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.handleMouseMoved() }
        }
        // Local monitor: catches movement when our own (accessory) app is frontmost,
        // which rarely happens but is harmless.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.handleMouseMoved() }
            return event
        }
    }

    private func handleMouseMoved() {
        let p = NSEvent.mouseLocation  // global screen coords (AppKit)
        let zone = currentHoverZone()
        let inZone = zone.contains(p)

        if inZone {
            hoverExitTimer?.invalidate()
            hoverExitTimer = nil
            if !hoverActive {
                hoverActive = true
                recomputeState()
            }
        } else if hoverActive {
            // Grace period before collapsing — survives brief excursions during
            // panel resize animation.
            if hoverExitTimer == nil {
                hoverExitTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.hoverExitTimer = nil
                        if !self.currentHoverZone().contains(NSEvent.mouseLocation) {
                            self.hoverActive = false
                            self.recomputeState()
                        }
                    }
                }
            }
        }
    }

    /// The zone where the cursor counts as hovering. Larger than the visible
    /// panel so the cursor can comfortably approach from below.
    private func currentHoverZone() -> NSRect {
        let g = geometry
        // Maximum lateral extent we ever want to be hoverable — use the WIDEST
        // possible body width so the cursor never "falls out" while the panel
        // is animating from compact to expanded.
        let bodyW = max(g.notchWidth + 200, 480)
        let bodyH: CGFloat = (uiState == .expanded
                              ? bodySize(for: .expanded).height
                              : (uiState == .peek ? bodySize(for: .peek).height : 26))
        let totalH = g.notchHeight + bodyH

        // Apply the same left-bias the window uses.
        let centerX = g.centerX - NotchWings.centerBias
        let x = centerX - bodyW / 2
        let y = g.topY - totalH
        return NSRect(x: x, y: y, width: bodyW, height: totalH).insetBy(dx: -8, dy: -8)
    }
}
