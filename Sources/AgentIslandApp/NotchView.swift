import SwiftUI
import AgentIslandCore

enum NotchUIState: Equatable {
    case compact
    case peek
    case expanded
}

// MARK: - Constants

/// Horizontal asymmetric extension of the visible "wings" beyond the hardware notch.
/// Tweak here to taste. Keep small so we don't cover menu-bar items.
enum NotchWings {
    static let left: CGFloat = 28
    static let right: CGFloat = 16
    static var total: CGFloat { left + right }
    /// Window-center horizontal bias so the wings come out asymmetric.
    /// Positive = window shifts LEFT (more wing on the left).
    static var centerBias: CGFloat { (left - right) / 2 }
}

/// Approximate radius of the physical notch's bottom corners on M-series MBPs.
private let kHardwareNotchBottomRadius: CGFloat = 9

// MARK: - Root view

struct NotchView: View {
    @ObservedObject var store: AgentStore
    let geometry: NotchGeometry
    let uiState: NotchUIState
    let bodySize: CGSize

    var body: some View {
        ZStack(alignment: .top) {
            // Body (peek/expanded only) — wider piece hanging below the notch.
            if uiState != .compact {
                bodyShape
                    .frame(width: bodySize.width, height: bodySize.height)
                    .padding(.top, geometry.notchHeight - 1)  // -1 for clean overlap
            }

            // Notch piece — always present, rounded bottom corners match hardware.
            notchPiece

            // Content for peek/expanded
            if uiState != .compact {
                content
                    .frame(width: bodySize.width, height: bodySize.height, alignment: .top)
                    .padding(.top, geometry.notchHeight)
                    .padding(.horizontal, contentHPad)
                    .padding(.vertical, 8)
            }
        }
        // Single transition animation, only on state changes. No periodic animations.
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: uiState)
    }

    // MARK: notch piece (always)

    private var notchPiece: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: kHardwareNotchBottomRadius,
            bottomTrailingRadius: kHardwareNotchBottomRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
        return shape
            .fill(Color.black)
            // Ambient outline glow — only present when something demands attention.
            // Calm state = no glow at all. Silence is default.
            .overlay(
                shape
                    .stroke(ambientGlowColor, lineWidth: 1.2)
                    .blur(radius: 3)
                    .opacity(ambientGlowColor == .clear ? 0 : 1)
            )
            .shadow(color: ambientGlowColor.opacity(0.55), radius: 9, x: 0, y: 1)
            .frame(width: geometry.notchWidth + NotchWings.total,
                   height: geometry.notchHeight)
    }

    /// The single color of the notch's outline glow.
    /// Priority: error > needs-you > calm. Running / thinking do NOT glow —
    /// they are normal states that should not draw the user's eye.
    private var ambientGlowColor: Color {
        let active = store.agents.filter { !$0.isStale }
        if active.contains(where: { $0.status == .error }) { return .red }
        if active.contains(where: { $0.needs_attention || $0.status == .waiting_input }) {
            return AgentColors.yellow
        }
        return .clear
    }

    // MARK: body

    private var bodyShape: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 12,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: 12,
            style: .continuous
        )
        .fill(Color.black)
        .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 8)
    }

    private var bottomRadius: CGFloat {
        uiState == .peek ? 18 : 22
    }

    private var contentHPad: CGFloat {
        uiState == .peek ? 14 : 16
    }

    @ViewBuilder
    private var content: some View {
        switch uiState {
        case .compact:
            EmptyView()
        case .peek:
            CyclingPeekContent(store: store)
        case .expanded:
            ExpandedContent(store: store)
        }
    }
}

// MARK: - Peek (cycles between agents)

private struct CyclingPeekContent: View {
    @ObservedObject var store: AgentStore
    @State private var index: Int = 0
    @State private var cycleTimer: Timer? = nil

    /// Stable rotation order: attention → running → others, all non-stale.
    private var rotation: [AgentState] {
        let active = store.agents.filter { !$0.isStale }
        let attn  = active.filter { $0.needs_attention }
        let run   = active.filter { !$0.needs_attention && $0.status == .running }
        let other = active.filter { !$0.needs_attention && $0.status != .running }
        return attn + run + other
    }

    var body: some View {
        Group {
            if rotation.isEmpty {
                idleRow
            } else {
                let current = rotation[index % max(rotation.count, 1)]
                AgentPeekRow(agent: current)
                    .id(current.agent_id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onAppear { startCycle() }
        .onDisappear { stopCycle() }
        .onChange(of: rotation.map(\.agent_id)) { _ in
            // If the set of agents changes, reset to the first to avoid index drift.
            if index >= rotation.count { index = 0 }
        }
    }

    private func startCycle() {
        stopCycle()
        guard rotation.count > 1 else { return }
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { _ in
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

    private var idleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
            Text("AgentIsland")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
            Spacer()
        }
    }
}

private struct AgentPeekRow: View {
    let agent: AgentState

    var body: some View {
        HStack(spacing: 9) {
            AgentIcon(kind: agent.kind, accent: dotColor(for: agent))
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.display_name)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(secondaryLabel)
                    .font(.system(size: 9.5, weight: agent.needs_attention ? .medium : .regular,
                                  design: .rounded))
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            StatusDot(color: dotColor(for: agent))
        }
        .frame(maxWidth: .infinity)
    }

    private var secondaryLabel: String {
        if agent.needs_attention {
            return agent.task ?? "needs your input"
        }
        return agent.task ?? agent.status.rawValue
    }

    private var secondaryColor: Color {
        agent.needs_attention ? AgentColors.yellow.opacity(0.95) : Color.white.opacity(0.55)
    }
}

// MARK: - Expanded

private struct ExpandedContent: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider().background(Color.white.opacity(0.08))
            if store.agents.isEmpty {
                emptyState
            } else {
                VStack(spacing: 6) {
                    ForEach(store.agents) { agent in
                        ExpandedAgentRow(agent: agent)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
            Text("AgentIsland")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.75))
            Spacer()
            Text(summary)
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private var summary: String {
        let n = store.agents.count
        let attn = store.agents.filter { $0.needs_attention }.count
        if attn > 0 { return "\(n) agent\(n == 1 ? "" : "s") · \(attn) need\(attn == 1 ? "s" : "") you" }
        return "\(n) agent\(n == 1 ? "" : "s")"
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dotted")
                .foregroundColor(.white.opacity(0.4))
            Text("No agents reporting yet.")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.vertical, 6)
    }
}

private struct ExpandedAgentRow: View {
    let agent: AgentState

    var body: some View {
        HStack(spacing: 10) {
            AgentIcon(kind: agent.kind, accent: accentColor)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(agent.display_name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    statusChip
                }
                if let task = agent.task, !task.isEmpty {
                    Text(task)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                StatusDot(color: accentColor)
                Text(elapsed)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(agent.needs_attention ? 0.07 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    agent.needs_attention ? AgentColors.yellow.opacity(0.45) : Color.white.opacity(0.05),
                    lineWidth: 0.5
                )
        )
    }

    private var statusChip: some View {
        Text(statusLabel.uppercased())
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .tracking(0.5)
            .foregroundColor(.black)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(accentColor.opacity(0.85)))
    }

    private var statusLabel: String {
        if agent.isStale { return "stale" }
        switch agent.status {
        case .thinking:       return "thinking"
        case .running:        return "running"
        case .waiting_input:  return "needs you"
        case .idle:           return "idle"
        case .done:           return "done"
        case .error:          return "error"
        }
    }

    private var accentColor: Color { dotColor(for: agent) }

    private var elapsed: String {
        let e = Int(Date().timeIntervalSince(agent.started_at))
        if e < 60   { return "\(e)s" }
        if e < 3600 { return "\(e / 60)m" }
        return "\(e / 3600)h"
    }
}

// MARK: - Shared

// MARK: - Color language (fixed across the product)
//
//   purple → thinking (reasoning, awaiting model output)
//   green  → running  (executing a tool)
//   yellow → needs you (approval, question, plan review)
//   blue   → done     (finished, awaiting your dismissal)
//   red    → error
//   gray   → idle / stale

func dotColor(for a: AgentState) -> Color {
    if a.isStale { return Color(white: 0.5) }
    if a.status == .error { return .red }
    if a.needs_attention || a.status == .waiting_input { return AgentColors.yellow }
    switch a.status {
    case .thinking:       return AgentColors.purple
    case .running:        return .green
    case .waiting_input:  return AgentColors.yellow   // (unreachable; handled above)
    case .idle:           return Color(white: 0.5)
    case .done:           return AgentColors.blue
    case .error:          return .red                 // (unreachable; handled above)
    }
}

enum AgentColors {
    static let purple = Color(red: 0.70, green: 0.55, blue: 0.95)
    static let yellow = Color(red: 1.00, green: 0.82, blue: 0.15)
    static let blue   = Color(red: 0.45, green: 0.72, blue: 1.00)
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
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(
                    colors: [accent.opacity(0.32), accent.opacity(0.10)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(accent.opacity(0.45), lineWidth: 0.5)
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var symbol: String {
        switch kind {
        case "claude-code", "claude": return "sparkles"
        case "codex":                 return "chevron.left.forwardslash.chevron.right"
        case "hermes":                return "wand.and.stars"
        case "openclaw":              return "pawprint.fill"
        case "python":                return "p.circle"
        default:                      return "circle.dotted"
        }
    }
}
