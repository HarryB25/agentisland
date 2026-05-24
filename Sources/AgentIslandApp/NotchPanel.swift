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

/// Static size limits for the panel. The panel is created at this size and
/// never resizes — only the SwiftUI island shape inside animates. This
/// eliminates the "pop-out a block" feel the user complained about, and
/// keeps the visible shape always anchored to the screen-top bezel.
enum IslandPanelLimits {
    /// Inner content area max width (i.e. body width between the two top
    /// anti-corners). Final shape width is this + 2× the largest top radius.
    static let maxContentWidth: CGFloat = 430
    static let maxBodyHeight: CGFloat = 430
    static let hitTestPadding: CGFloat = 4
    /// Delay before collapsing after the cursor leaves the hover zone.
    static let hoverExitDelay: TimeInterval = 0.08
    /// Vertical bump below the notch in compact state when at least one agent
    /// is active. Just enough room for a sentinel dot. Zero when fully idle.
    static let compactSentinelHeight: CGFloat = 11
    /// The largest top corner radius used by NotchView. Kept in sync with
    /// `kExpandedTopR` over there — the shape width must reserve room.
    static let topRadius: CGFloat = 11
}

/// Shared, observable presentation state for the notch UI. Changes here
/// flow into SwiftUI as published-property updates, which lets SwiftUI's
/// `.animation(...)` modifier interpolate the IslandShape smoothly between
/// states. (We used to rebuild the entire hosting view on every state
/// change, which broke animation identity and produced visible jank.)
@MainActor
final class NotchPresentation: ObservableObject {
    @Published var uiState: NotchUIState = .compact
    @Published var bodySize: CGSize = .zero
}

// MARK: - Panel

/// NSView that only accepts hits inside `hitRect`. Used so the panel's
/// transparent margins (panel is fixed wide; shape inside is narrow) pass
/// clicks through to whatever's beneath — including menu bar items.
final class IslandHitView: NSView {
    var hitRect: NSRect = .zero

    override var isFlipped: Bool { true }  // top-left origin, matches SwiftUI

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = self.convert(point, from: nil)
        guard hitRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

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
        // Default: clicks pass through so menu-bar items behind the panel
        // (which now spans much wider than the hardware notch) stay usable.
        // The host controller flips this to false only while expanded.
        self.ignoresMouseEvents = true
        self.contentView = rootView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Pin the panel to the screen top, centered horizontally on the hardware
    /// notch. Called once on show and on screen-parameter changes — never
    /// during state transitions.
    func pin(to geometry: NotchGeometry) {
        let w: CGFloat = IslandPanelLimits.maxContentWidth + 2 * IslandPanelLimits.topRadius + 40
        let h: CGFloat = geometry.notchHeight + IslandPanelLimits.maxBodyHeight + 20
        let x = geometry.centerX - w / 2
        let y = geometry.topY - h
        self.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
}

// MARK: - Host controller

@MainActor
final class NotchHostController {
    private let store: AgentStore
    private let presentation = NotchPresentation()
    private let panel: NotchPanel
    private var geometry: NotchGeometry
    private let rootContainer: IslandHitView
    private var hostingView: NSHostingView<AnyView>!

    private var uiState: NotchUIState {
        get { presentation.uiState }
        set {
            guard presentation.uiState != newValue else { return }
            presentation.uiState = newValue
            presentation.bodySize = bodySize(for: newValue)
            updateHitRect()
            refreshMouseEventForwarding()
        }
    }
    /// Manual hover is binary. `peek` is reserved for high-priority automatic
    /// reminders; pointer hover should not show a temporary intermediate UI.
    private enum HoverStage { case none, expanded }
    private var hoverStage: HoverStage = .none
    private var autoPeekUntil: Date = .distantPast

    private var cancellables: Set<AnyCancellable> = []
    private var tickTimer: Timer?

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var hoverExitTimer: Timer?
    private var lastMouseMoveUptime: TimeInterval = 0

    init(store: AgentStore) {
        self.store = store
        let screen = NSScreen.main ?? NSScreen.screens[0]
        self.geometry = NotchGeometry.current(for: screen)
        self.rootContainer = IslandHitView()
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

        presentation.bodySize = bodySize(for: .compact)
        installHostingView()
        setupMouseMonitoring()

        store.$autoPeekTick
            .filter { $0 > 0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.beginAutoPeek(duration: 8) }
            .store(in: &cancellables)

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recomputeState()
            }
        }

        store.$agents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.recomputeState()
                // Refresh current state's bodySize too — compact sentinel may
                // appear/disappear, expanded row count may change.
                self.presentation.bodySize = self.bodySize(for: self.uiState)
                self.updateHitRect()
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshGeometry()
            }
        }
    }

    deinit {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor  { NSEvent.removeMonitor(m) }
        tickTimer?.invalidate()
        hoverExitTimer?.invalidate()
    }

    func show() {
        panel.pin(to: geometry)
        panel.orderFrontRegardless()
        updateHitRect()
        refreshMouseEventForwarding()
    }

    private func refreshMouseEventForwarding() {
        panel.ignoresMouseEvents = (uiState == .compact)
    }

    /// Restrict click acceptance to a rect tightly bounding the visible
    /// island shape. Outside this rect the panel passes events through to
    /// whatever's beneath (e.g. menu bar items).
    private func updateHitRect() {
        let body = presentation.bodySize
        let shapeW = body.width + 2 * IslandPanelLimits.topRadius
        let shapeH = geometry.notchHeight + body.height
        let panelW = IslandPanelLimits.maxContentWidth + 2 * IslandPanelLimits.topRadius + 40
        let x = (panelW - shapeW) / 2
        let rect = NSRect(x: x, y: 0, width: shapeW, height: shapeH)
            .insetBy(dx: -IslandPanelLimits.hitTestPadding,
                     dy: -IslandPanelLimits.hitTestPadding)
        rootContainer.hitRect = rect
    }

    // MARK: state machine

    private func recomputeState() {
        let autoPeeking = Date() < autoPeekUntil
        let target: NotchUIState
        switch hoverStage {
        case .expanded:
            target = .expanded
        case .none:
            if autoPeeking && !store.visibleAgents.isEmpty {
                target = .peek
            } else {
                target = .compact
            }
        }
        uiState = target  // setter is no-op if unchanged
    }

    private func beginAutoPeek(duration: TimeInterval) {
        autoPeekUntil = Date().addingTimeInterval(duration)
        if hoverStage == .none {
            uiState = .peek
        } else {
            recomputeState()
        }
    }

    // MARK: sizing

    func bodySize(for state: NotchUIState) -> CGSize {
        let g = geometry
        switch state {
        case .compact:
            // Compact: shape matches the hardware notch silhouette. When any
            // agent is active, add a small vertical bump so a sentinel dot has
            // room to sit just below the notch — the always-on "live activity"
            // tell. When fully idle, height stays 0 and the notch is invisible.
            let h: CGFloat = (store.sentinelAgent != nil) ? IslandPanelLimits.compactSentinelHeight : 0
            return CGSize(width: g.notchWidth, height: h)
        case .peek:
            let w = max(g.notchWidth + 86, 320)
            return CGSize(width: min(w, IslandPanelLimits.maxContentWidth), height: 60)
        case .expanded:
            let visibleAgents = store.visibleAgents
            let visibleCount = min(visibleAgents.count, 4)
            let listH: CGFloat = visibleCount == 0 ? 54 : CGFloat(visibleCount) * 88 + CGFloat(max(visibleCount - 1, 0)) * 8
            let bannerH: CGFloat = store.attentionAgent == nil ? 0 : 46
            let w = max(g.notchWidth + 170, 370)
            let h = 40 + bannerH + listH + 18
            return CGSize(
                width: min(w, IslandPanelLimits.maxContentWidth),
                height: min(h, IslandPanelLimits.maxBodyHeight)
            )
        }
    }

    private func refreshGeometry() {
        guard let screen = NSScreen.main else { return }
        let g = NotchGeometry.current(for: screen)
        if g != geometry {
            geometry = g
            panel.pin(to: geometry)
            presentation.bodySize = bodySize(for: uiState)
        }
    }

    // MARK: hosting

    private func installHostingView() {
        let view = NotchView(
            store: store,
            geometry: geometry,
            presentation: presentation
        )
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

    // MARK: hover detection

    private func setupMouseMonitoring() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMouseMoved()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .mouseMoved:
                Task { @MainActor [weak self] in
                    self?.handleMouseMoved()
                }
                return event
            case .scrollWheel:
                return self.shouldSuppressScroll(event) ? nil : event
            default:
                return event
            }
        }
    }

    private func handleMouseMoved() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMouseMoveUptime >= 1.0 / 90.0 else { return }
        lastMouseMoveUptime = now

        let p = NSEvent.mouseLocation
        let zone = currentHoverZone()
        let inZone = zone.contains(p)

        if inZone {
            hoverExitTimer?.invalidate()
            hoverExitTimer = nil
            if hoverStage != .expanded {
                hoverStage = .expanded
                recomputeState()
            }
        } else if hoverStage != .none {
            if hoverExitTimer == nil {
                hoverExitTimer = Timer.scheduledTimer(
                    withTimeInterval: IslandPanelLimits.hoverExitDelay,
                    repeats: false
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.hoverExitTimer = nil
                        if !self.currentHoverZone().contains(NSEvent.mouseLocation) {
                            self.hoverStage = .none
                            self.recomputeState()
                        }
                    }
                }
            }
        }
    }

    /// The zone where the cursor counts as hovering. Sized to the currently
    /// visible island shape (plus a small grace inset). Crucially: in
    /// compact state, this is exactly the hardware-notch silhouette — so the
    /// user must actually touch the notch to expand, not just hover near it.
    private func currentHoverZone() -> NSRect {
        let g = geometry
        let body = bodySize(for: uiState)
        let shapeW = max(body.width, g.notchWidth)
        let shapeH = g.notchHeight + body.height
        let x = g.centerX - shapeW / 2
        let y = g.topY - shapeH
        return NSRect(x: x, y: y, width: shapeW, height: shapeH)
            .insetBy(dx: -IslandPanelLimits.hitTestPadding,
                     dy: -IslandPanelLimits.hitTestPadding)
    }

    private func shouldSuppressScroll(_ event: NSEvent) -> Bool {
        guard uiState != .compact else { return false }
        guard currentHoverZone().contains(NSEvent.mouseLocation) else { return false }
        return true
    }
}
