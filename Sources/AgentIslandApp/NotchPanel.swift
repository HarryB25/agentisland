import AppKit
import SwiftUI
import Combine

/// Geometry of the notch (real on M1 Pro/Max+, synthesized on non-notched displays).
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let centerX: CGFloat
    let topY: CGFloat        // AppKit y-coord of screen's top edge (== frame.maxY)
    let hasRealNotch: Bool
    let menuBarHeight: CGFloat

    static func current(for screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top
        let real = topInset > 0

        // Height of the menu-bar band. On notched displays it equals the notch height
        // (the menu bar wraps around the notch and is its full height).
        // On non-notched displays we use ~24pt (standard macOS menu bar) for the gap.
        let menuBarH: CGFloat = real ? topInset : 24

        // Try to read the actual notch width from the auxiliary top areas.
        // auxiliaryTopLeftArea is the menu-bar region LEFT of the notch;
        // auxiliaryTopRightArea is RIGHT of it. The gap between them is the notch.
        var notchW: CGFloat = 0
        var notchH: CGFloat = real ? topInset : 24
        if real,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            let gap = rightArea.minX - leftArea.maxX
            if gap > 100, gap < 400 {
                notchW = gap
            }
            // The auxiliary areas' height equals the menu bar/notch height; trust it.
            notchH = max(notchH, leftArea.height)
        }

        // Fallback by hardware model when auxiliary areas don't yield a width.
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

/// `sysctlbyname("hw.model")` → e.g. "MacBookPro18,3", "Mac14,7".
private func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var bytes = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &bytes, &size, nil, 0)
    return String(cString: bytes)
}

/// Hard-coded fallback widths in case auxiliary areas don't report.
/// Reference: real measurements at default scaling.
private func fallbackNotchWidth(forModel model: String, hasRealNotch: Bool) -> CGFloat {
    guard hasRealNotch else { return 180 }
    // 14"/16" MBP M1 Pro/Max, M2/M3/M4 Pro/Max — notch ≈ 200pt wide
    if model.hasPrefix("MacBookPro") { return 200 }
    // MacBookAir M2/M3 13"/15" — notch ≈ 175pt wide (smaller)
    if model.hasPrefix("MacBookAir") { return 175 }
    // Newer "Mac14,*" / "Mac15,*" identifiers — generic safe value
    return 200
}

// MARK: - Panel

/// Borderless panel pinned flush with the top of the display.
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

    func setFrameForGeometry(_ geo: NotchGeometry,
                             contentWidth: CGFloat,
                             contentHeight: CGFloat,
                             animated: Bool) {
        let x = geo.centerX - contentWidth / 2
        let y = geo.topY - contentHeight
        let rect = NSRect(x: x, y: y, width: contentWidth, height: contentHeight)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.34
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.85, 0.25, 1.0)
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
        let screen = NSScreen.main ?? NSScreen.screens[0]
        self.geometry = NotchGeometry.current(for: screen)
        self.rootContainer = HoverTrackingView()
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
        rootContainer.onHoverChange = { [weak self] hovering in
            self?.hoverActive = hovering
            self?.recomputeState()
        }

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

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        store.$agents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tick() }
            .store(in: &cancellables)

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
        layout(animated: true)
    }

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

    private func bodySize(for state: NotchUIState) -> CGSize {
        let g = geometry
        switch state {
        case .compact:
            // Body is invisible but still 12pt tall so the hover area
            // extends below the hardware notch and can catch the cursor.
            // Also gives room for a small static indicator when attention is pending.
            return CGSize(width: g.notchWidth, height: 12)
        case .peek:
            let w = max(g.notchWidth + 60, 320)
            return CGSize(width: w, height: 46)
        case .expanded:
            let n = store.agents.count
            let listH = n == 0 ? 30 : CGFloat(n) * 46 + 4
            let w = max(g.notchWidth + 180, 460)
            let h = 36 /* header */ + listH + 16
            return CGSize(width: w, height: h)
        }
    }

    private func windowSize(for state: NotchUIState) -> CGSize {
        let g = geometry
        let body = bodySize(for: state)
        let totalW = max(g.notchWidth, body.width)
        let totalH = g.notchHeight + body.height
        return CGSize(width: totalW, height: totalH)
    }

    private func layout(animated: Bool) {
        let size = windowSize(for: uiState)
        panel.setFrameForGeometry(geometry,
                                  contentWidth: size.width,
                                  contentHeight: size.height,
                                  animated: animated)
    }

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
}

/// Tracks hover with no margin — entrance is the visible blob region.
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
