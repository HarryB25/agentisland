import SwiftUI
import AppKit
import Darwin
import AgentIslandCore

enum NotchUIState: Equatable {
    case compact
    case peek
    case expanded
}

// MARK: - Constants

private let kTopR: CGFloat = 11
private let kCompactBottomR: CGFloat = 9
private let kExpandedBottomR: CGFloat = 20

// MARK: - Root view

struct NotchView: View {
    @ObservedObject var store: AgentStore
    let geometry: NotchGeometry
    @ObservedObject var presentation: NotchPresentation

    private var uiState: NotchUIState { presentation.uiState }
    private var bodySize: CGSize { presentation.bodySize }

    private var shapeWidth: CGFloat {
        bodySize.width + 2 * kTopR
    }

    private var shapeHeight: CGFloat {
        geometry.notchHeight + bodySize.height
    }

    private var bottomR: CGFloat {
        uiState == .compact ? kCompactBottomR : kExpandedBottomR
    }

    private var dominantAgent: AgentState? {
        store.attentionAgent
            ?? store.sentinelAgent
            ?? store.visibleAgents.first
    }

    private var accentColor: Color {
        dominantAgent.map(dotColor(for:)) ?? Color.white.opacity(0.18)
    }

    private var ambientGlowColor: Color {
        guard let agent = dominantAgent else { return .clear }
        if agent.status == .error { return .red }
        if agent.needs_attention || agent.status == .waiting_input {
            return AgentColors.yellow
        }
        return .clear
    }

    var body: some View {
        let shape = NotchShape(topR: kTopR, bottomR: bottomR)

        ZStack(alignment: .top) {
            IslandSurface(
                accentColor: accentColor,
                ambientGlowColor: ambientGlowColor,
                state: uiState
            )
            .frame(width: shapeWidth, height: shapeHeight)
            .mask(shape)
            .overlay {
                shape
                    .stroke(surfaceStrokeColor, lineWidth: 0.85)
            }
            .shadow(color: .black.opacity(uiState == .compact ? 0.22 : 0.40),
                    radius: uiState == .compact ? 10 : 24, y: uiState == .compact ? 5 : 14)
            .shadow(color: ambientGlowColor.opacity(uiState == .expanded ? 0.45 : 0.26),
                    radius: uiState == .expanded ? 24 : 14, y: 8)

            islandContent
                .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
                .contentShape(shape)
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.34), value: presentation.uiState)
        .animation(.smooth(duration: 0.34), value: presentation.bodySize)
    }

    private var surfaceStrokeColor: Color {
        switch uiState {
        case .compact:
            return Color.white.opacity(0.07)
        case .peek:
            return Color.white.opacity(0.08)
        case .expanded:
            return accentColor.opacity(0.22)
        }
    }

    @ViewBuilder
    private var islandContent: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: geometry.notchHeight)
            Group {
                switch uiState {
                case .compact:
                    CompactSentinel(
                        agent: store.sentinelAgent,
                        activeCount: store.visibleAgents.count
                    )
                case .peek:
                    CyclingPeekContent(store: store)
                case .expanded:
                    ExpandedContent(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, uiState == .compact ? 0 : kTopR + 6)
            .padding(.vertical, uiState == .compact ? 0 : 8)
        }
    }
}

private struct IslandSurface: View {
    let accentColor: Color
    let ambientGlowColor: Color
    let state: NotchUIState

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(baseBlackOpacity))

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(materialOpacity)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.12),
                    Color.white.opacity(0.035),
                    Color.black.opacity(0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    accentColor.opacity(accentOpacity),
                    accentColor.opacity(0.05),
                    .clear
                ],
                center: .init(x: 0.5, y: 0.12),
                startRadius: 4,
                endRadius: 220
            )

            if ambientGlowColor != .clear {
                RadialGradient(
                    colors: [
                        ambientGlowColor.opacity(state == .expanded ? 0.18 : 0.10),
                        .clear
                    ],
                    center: .init(x: 0.5, y: 0.10),
                    startRadius: 0,
                    endRadius: 180
                )
            }

            VStack(spacing: 0) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 1)
                Spacer()
            }
        }
    }

    private var baseBlackOpacity: CGFloat {
        switch state {
        case .compact: return 0.94
        case .peek: return 0.88
        case .expanded: return 0.84
        }
    }

    private var materialOpacity: CGFloat {
        switch state {
        case .compact: return 0.05
        case .peek: return 0.12
        case .expanded: return 0.18
        }
    }

    private var accentOpacity: CGFloat {
        switch state {
        case .compact: return 0.10
        case .peek: return 0.16
        case .expanded: return 0.22
        }
    }
}

// MARK: - Compact

private struct CompactSentinel: View {
    let agent: AgentState?
    let activeCount: Int

    var body: some View {
        Group {
            if let agent {
                HStack(spacing: 5) {
                    Circle()
                        .fill(dotColor(for: agent))
                        .frame(width: 5, height: 5)
                        .shadow(color: dotColor(for: agent).opacity(0.55), radius: 3)

                    if activeCount > 1 {
                        Text("\(activeCount)")
                            .font(.system(size: 7, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.72))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, activeCount > 1 ? 8 : 7)
                .padding(.vertical, 2.5)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.045))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
                        }
                )
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale))
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Shape

private struct NotchShape: Shape {
    var topR: CGFloat
    var bottomR: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topR, bottomR) }
        set { topR = newValue.first; bottomR = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        p.move(to: CGPoint(x: minX, y: minY))
        p.addQuadCurve(
            to: CGPoint(x: minX + topR, y: minY + topR),
            control: CGPoint(x: minX + topR, y: minY)
        )
        p.addLine(to: CGPoint(x: minX + topR, y: maxY - bottomR))
        p.addQuadCurve(
            to: CGPoint(x: minX + topR + bottomR, y: maxY),
            control: CGPoint(x: minX + topR, y: maxY)
        )
        p.addLine(to: CGPoint(x: maxX - topR - bottomR, y: maxY))
        p.addQuadCurve(
            to: CGPoint(x: maxX - topR, y: maxY - bottomR),
            control: CGPoint(x: maxX - topR, y: maxY)
        )
        p.addLine(to: CGPoint(x: maxX - topR, y: minY + topR))
        p.addQuadCurve(
            to: CGPoint(x: maxX, y: minY),
            control: CGPoint(x: maxX - topR, y: minY)
        )
        p.addLine(to: CGPoint(x: minX, y: minY))
        return p
    }
}

// MARK: - Peek

private struct CyclingPeekContent: View {
    @ObservedObject var store: AgentStore
    @State private var index: Int = 0
    @State private var cycleTimer: Timer?

    private var rotation: [AgentState] {
        let active = store.visibleAgents
        let attention = active.filter { $0.needs_attention || $0.status == .waiting_input }
        let thinking = active.filter {
            !$0.needs_attention && $0.status == .thinking
        }
        let running = active.filter {
            !$0.needs_attention && $0.status == .running
        }
        let other = active.filter {
            !$0.needs_attention && $0.status != .thinking && $0.status != .running
        }
        return attention + thinking + running + other
    }

    var body: some View {
        Group {
            if rotation.isEmpty {
                PeekIdleRow()
            } else {
                let current = rotation[index % max(rotation.count, 1)]
                AgentPeekRow(agent: current, totalCount: rotation.count)
                    .id(current.agent_id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onAppear { startCycleIfNeeded() }
        .onDisappear { stopCycle() }
        .onChange(of: rotation.map(\.agent_id)) { _ in
            if index >= rotation.count { index = 0 }
            startCycleIfNeeded()
        }
    }

    private func startCycleIfNeeded() {
        stopCycle()
        guard rotation.count > 1 else { return }
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 3.6, repeats: true) { _ in
            Task { @MainActor in
                guard rotation.count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.42)) {
                    index = (index + 1) % rotation.count
                }
            }
        }
    }

    private func stopCycle() {
        cycleTimer?.invalidate()
        cycleTimer = nil
    }
}

private struct PeekIdleRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))

            VStack(alignment: .leading, spacing: 2) {
                Text("AgentIsland")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.78))
                Text("All calm. Your agents are out of the way.")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.52))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct AgentPeekRow: View {
    let agent: AgentState
    let totalCount: Int

    var body: some View {
        HStack(spacing: 10) {
            AgentIcon(kind: agent.kind, accent: dotColor(for: agent))
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.display_name)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let location = locationLabel(for: agent), location != agent.display_name {
                        MetaPill(text: location)
                    }
                }

                Text(peekSubtitle)
                    .font(.system(size: 9.5, weight: agent.needs_attention ? .semibold : .medium, design: .rounded))
                    .foregroundColor(agent.needs_attention ? AgentColors.yellow.opacity(0.98) : Color.white.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                StatusPill(
                    text: statusDisplayText(for: agent),
                    color: dotColor(for: agent),
                    emphasis: agent.needs_attention || agent.status == .error
                )
                HStack(spacing: 6) {
                    if totalCount > 1 {
                        CounterPill(count: totalCount)
                    }
                    Text(elapsedLabel(since: agent.started_at))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.42))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
                }
        )
    }

    private var peekSubtitle: String {
        agent.taskText ?? "\(kindLabel(for: agent.kind)) is active"
    }
}

// MARK: - Expanded

private struct ExpandedContent: View {
    @ObservedObject var store: AgentStore

    private var visibleAgents: [AgentState] {
        store.visibleAgents
            .sorted { agentPriority($0) < agentPriority($1) }
    }

    private var displayedAgents: [AgentState] {
        Array(visibleAgents.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ExpandedHeader(agents: visibleAgents)

            if let attentionAgent = store.attentionAgent, !attentionAgent.isStale {
                AttentionBanner(agent: attentionAgent)
            }

            if visibleAgents.isEmpty {
                EmptyExpandedState()
            } else {
                VStack(spacing: 8) {
                    ForEach(displayedAgents) { agent in
                        ExpandedAgentRow(agent: agent)
                    }
                }
                .padding(.bottom, 2)
                .clipped()
            }
        }
    }
}

private struct ExpandedHeader: View {
    let agents: [AgentState]

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "menubar.dock.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.68))

                VStack(alignment: .leading, spacing: 2) {
                    Text("AgentIsland")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.92))

                    Text(summary)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.52))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if !agents.isEmpty {
                CounterPill(count: agents.count, label: "LIVE")
            }
        }
    }

    private var summary: String {
        let attention = agents.filter { $0.needs_attention || $0.status == .waiting_input }.count
        let running = agents.filter { $0.status == .running }.count
        let thinking = agents.filter { $0.status == .thinking }.count
        let done = agents.filter { $0.status == .done }.count

        if attention > 0 {
            return "\(attention) waiting for you"
        }
        if running > 0 && thinking > 0 {
            return "\(running) running · \(thinking) thinking"
        }
        if running > 0 {
            return "\(running) running"
        }
        if thinking > 0 {
            return "\(thinking) thinking"
        }
        if done > 0 {
            return "\(done) completed"
        }
        return "All calm"
    }
}

private struct AttentionBanner: View {
    let agent: AgentState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(AgentColors.yellow.opacity(0.18))
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(AgentColors.yellow.opacity(0.95))
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(agent.display_name) needs your input")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)

                Text(agent.taskText ?? "Review the pending action.")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AgentColors.yellow.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AgentColors.yellow.opacity(0.22), lineWidth: 0.6)
                }
        )
    }
}

private struct EmptyExpandedState: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))

            VStack(alignment: .leading, spacing: 2) {
                Text("All calm")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.84))
                Text("AgentIsland will stay quiet until something changes.")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.52))
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
                }
        )
    }
}

private struct ExpandedAgentRow: View {
    let agent: AgentState

    var body: some View {
        rowContent
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture { focusAgent(agent) }
        .help(focusHelpText)
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            mainRow

            if let progress = progressValue {
                TaskProgressBar(progress: progress, color: accentColor)
                    .padding(.leading, 40)
            }

            if !displayActions.isEmpty {
                AgentActionBar(actions: displayActions, agent: agent)
                    .padding(.leading, 40)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(agent.needs_attention ? 0.09 : 0.055),
                            accentColor.opacity(agent.needs_attention || agent.status == .error ? 0.16 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            accentColor.opacity(agent.needs_attention || agent.status == .error ? 0.36 : 0.16),
                            lineWidth: 0.75
                        )
                }
        )
    }

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentIcon(kind: agent.kind, accent: accentColor)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(agent.display_name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    StatusPill(
                        text: statusDisplayText(for: agent),
                        color: accentColor,
                        emphasis: agent.needs_attention || agent.status == .error
                    )
                }

                if let detail = detailText {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.66))
                        .lineLimit(2)
                }

                metadataRow
            }
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 6) {
            MetaPill(text: kindLabel(for: agent.kind))

            if let location = locationLabel(for: agent), location != agent.display_name {
                MetaPill(text: location)
            }

            if let tail = tailLabel(for: agent) {
                MetaPill(text: tail)
            }

            Spacer(minLength: 4)

            Text(elapsedLabel(since: agent.started_at))
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.44))
        }
    }

    private var detailText: String? {
        agent.taskText ?? tailLabel(for: agent)
    }

    private var progressValue: Double? {
        guard let progress = agent.progress else { return nil }
        return min(max(progress, 0), 1)
    }

    private var displayActions: [AgentState.Action] {
        agent.actions ?? []
    }

    private var accentColor: Color { dotColor(for: agent) }

    private var canFocus: Bool {
        agent.focus_pid != nil || agent.pid != nil
    }

    private var focusHelpText: String {
        if canFocus {
            return "Click to bring \(agent.display_name) to the front"
        }
        return agent.display_name
    }
}

private struct TaskProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
                Capsule(style: .continuous)
                    .fill(color.opacity(0.88))
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 5)
    }
}

private struct AgentActionBar: View {
    let actions: [AgentState.Action]
    let agent: AgentState
    @State private var sentActionID: String?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(actions) { action in
                Button(action: { send(action) }) {
                    Text(action.label)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(actionForeground(for: action))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(actionBackground(for: action))
                        )
                }
                .buttonStyle(.plain)
                .disabled(sentActionID != nil)
                .opacity(sentActionID == nil || sentActionID == action.id ? 1 : 0.42)
                .help("Send \(action.label) to \(agent.display_name)")
            }
        }
    }

    private func send(_ action: AgentState.Action) {
        if sendReply(action, for: agent) {
            sentActionID = action.id
        }
    }

    private func actionBackground(for action: AgentState.Action) -> Color {
        switch action.role {
        case .approve:
            return Color.green.opacity(0.23)
        case .deny:
            return Color.red.opacity(0.23)
        case .option:
            return AgentColors.blue.opacity(0.20)
        case .open:
            return AgentColors.blue.opacity(0.20)
        case .dismiss:
            return Color.white.opacity(0.07)
        }
    }

    private func actionForeground(for action: AgentState.Action) -> Color {
        switch action.role {
        case .approve:
            return Color.green.opacity(0.95)
        case .deny:
            return Color.red.opacity(0.95)
        case .option:
            return AgentColors.blue.opacity(0.95)
        case .open:
            return AgentColors.blue.opacity(0.95)
        case .dismiss:
            return Color.white.opacity(0.78)
        }
    }
}

// MARK: - Shared

private struct StatusPill: View {
    let text: String
    let color: Color
    var emphasis: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .tracking(0.5)
            .foregroundColor(.white.opacity(0.94))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(emphasis ? 0.22 : 0.14))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(color.opacity(emphasis ? 0.42 : 0.26), lineWidth: 0.6)
                    }
            )
    }
}

private struct CounterPill: View {
    let count: Int
    var label: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if let label {
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.4)
            }
        }
        .foregroundColor(.white.opacity(0.82))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                }
        )
    }
}

private struct MetaPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.64))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.45), radius: 2.5)
    }
}

struct AgentIcon: View {
    let kind: String
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.05))
            Circle()
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.34), accent.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
            Circle()
                .strokeBorder(accent.opacity(0.26), lineWidth: 0.6)
                .padding(1.2)

            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
        }
    }

    private var symbol: String {
        switch kind {
        case "claude-code", "claude": return "sparkles"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "hermes": return "wand.and.stars"
        case "openclaw": return "pawprint.fill"
        case "python": return "terminal"
        default: return "circle.dotted"
        }
    }
}

private func agentPriority(_ agent: AgentState) -> Int {
    if agent.status == .error { return 0 }
    if agent.needs_attention || agent.status == .waiting_input { return 1 }
    if agent.status == .thinking { return 2 }
    if agent.status == .running { return 3 }
    if agent.status == .done { return 4 }
    return 5
}

func dotColor(for agent: AgentState) -> Color {
    if agent.isStale { return Color(white: 0.5) }
    if agent.status == .error { return .red }
    if agent.needs_attention || agent.status == .waiting_input { return AgentColors.yellow }
    switch agent.status {
    case .thinking: return AgentColors.purple
    case .running: return .green
    case .waiting_input: return AgentColors.yellow
    case .idle: return Color(white: 0.5)
    case .done: return AgentColors.blue
    case .error: return .red
    }
}

enum AgentColors {
    static let purple = Color(red: 0.70, green: 0.55, blue: 0.95)
    static let yellow = Color(red: 1.00, green: 0.82, blue: 0.15)
    static let blue = Color(red: 0.45, green: 0.72, blue: 1.00)
}

private func statusLabel(for agent: AgentState) -> String {
    if agent.isStale { return "stale" }
    switch agent.status {
    case .thinking: return "thinking"
    case .running: return "running"
    case .waiting_input: return "needs you"
    case .idle: return "idle"
    case .done: return "done"
    case .error: return "error"
    }
}

private func statusDisplayText(for agent: AgentState) -> String {
    let label = agent.phase_title?.isEmpty == false ? agent.phase_title! : statusLabel(for: agent)
    guard agent.status == .running, let progress = agent.progress else { return label }
    let percent = Int((min(max(progress, 0), 1) * 100).rounded())
    return "\(label) · \(percent)%"
}

@discardableResult
private func sendReply(_ action: AgentState.Action, for agent: AgentState) -> Bool {
    let reply = AgentReply(
        agent_id: agent.agent_id,
        request_id: agent.request_id,
        action_id: action.id,
        action_label: action.label,
        role: action.role,
        value: action.id
    )
    do {
        try AgentReplyIO.save(reply)
        if action.role == .open {
            focusAgent(agent)
        }
        return true
    } catch {
        NSSound.beep()
        return false
    }
}

private func kindLabel(for kind: String) -> String {
    switch kind {
    case "claude-code", "claude":
        return "Claude"
    case "codex":
        return "Codex"
    case "hermes":
        return "Hermes"
    case "openclaw":
        return "OpenClaw"
    case "python":
        return "Python"
    case "custom":
        return "Custom"
    default:
        return kind.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

private func locationLabel(for agent: AgentState) -> String? {
    guard let cwd = agent.cwd, !cwd.isEmpty else { return nil }
    return URL(fileURLWithPath: cwd).lastPathComponent
}

private func tailLabel(for agent: AgentState) -> String? {
    guard let tail = agent.tail.last, !tail.isEmpty else { return nil }
    if tail == agent.taskText { return nil }
    return tail
}

private func elapsedLabel(since date: Date) -> String {
    let elapsed = max(0, Int(Date().timeIntervalSince(date)))
    if elapsed < 60 { return "\(elapsed)s" }
    if elapsed < 3600 { return "\(elapsed / 60)m" }
    return "\(elapsed / 3600)h"
}

private extension AgentState {
    var taskText: String? {
        guard let task, !task.isEmpty else { return nil }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            return nil
        }
        return task
    }
}

/// Bring the agent's terminal/window to the foreground.
/// Tries `focus_pid` first, then falls back to `pid`, then walks up the
/// process tree until it finds a focusable app.
private func focusAgent(_ agent: AgentState) {
    let candidates: [pid_t] = [agent.focus_pid, agent.pid]
        .compactMap { $0 }
        .map { pid_t($0) }
    for pid in candidates {
        if activate(pid: pid) { return }
        var cur = pid
        for _ in 0..<8 {
            let parent = parentPID(of: cur)
            if parent <= 1 { break }
            if activate(pid: parent) { return }
            cur = parent
        }
    }
    NSSound.beep()
}

private func activate(pid: pid_t) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
    return app.activate(options: [.activateIgnoringOtherApps])
}

private func parentPID(of pid: pid_t) -> pid_t {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let result = mib.withUnsafeMutableBufferPointer { ptr -> Int32 in
        sysctl(ptr.baseAddress, u_int(ptr.count), &info, &size, nil, 0)
    }
    if result != 0 || size == 0 { return 0 }
    return info.kp_eproc.e_ppid
}
