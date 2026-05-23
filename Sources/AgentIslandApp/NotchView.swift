import SwiftUI
import AgentIslandCore

enum NotchUIState: Equatable {
    case compact   // notch-shaped, near-invisible idle pill
    case peek      // narrow horizontal capsule, summary
    case expanded  // full agent list
}

// MARK: - Root view

struct NotchView: View {
    @ObservedObject var store: AgentStore
    let geometry: NotchGeometry
    let uiState: NotchUIState

    private var bottomRadius: CGFloat {
        switch uiState {
        case .compact:  return geometry.hasRealNotch ? 12 : 12
        case .peek:     return 18
        case .expanded: return 22
        }
    }

    private var topRadius: CGFloat {
        // On real notch, the top edge is hidden by the physical cutout.
        // On non-notched displays we round both ends for a "fake notch" feel.
        geometry.hasRealNotch ? 0 : (uiState == .compact ? 0 : 8)
    }

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: topRadius,
                bottomLeadingRadius: bottomRadius,
                bottomTrailingRadius: bottomRadius,
                topTrailingRadius: topRadius,
                style: .continuous
            )
            .fill(Color.black)
            .shadow(color: .black.opacity(uiState == .compact ? 0 : 0.45),
                    radius: uiState == .compact ? 0 : 10,
                    x: 0, y: 4)

            // Hairline highlight along bottom curve for premium feel (only when extended)
            if uiState != .compact {
                UnevenRoundedRectangle(
                    topLeadingRadius: topRadius,
                    bottomLeadingRadius: bottomRadius,
                    bottomTrailingRadius: bottomRadius,
                    topTrailingRadius: topRadius,
                    style: .continuous
                )
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.10), .white.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
            }

            content
                .padding(.top, geometry.notchHeight) // skip the notch zone, draw below
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: uiState)
        .animation(.spring(response: 0.30, dampingFraction: 0.85), value: store.agents)
    }

    @ViewBuilder
    private var content: some View {
        switch uiState {
        case .compact:
            CompactContent(store: store)
        case .peek:
            PeekContent(store: store)
        case .expanded:
            ExpandedContent(store: store)
        }
    }
}

// MARK: - Compact (idle, sits over the notch)

private struct CompactContent: View {
    @ObservedObject var store: AgentStore
    var body: some View {
        // Almost invisible against the notch — a single tiny accent dot if anything is running.
        HStack(spacing: 4) {
            if store.agents.first(where: { !$0.isStale && $0.status == .running }) != nil {
                Circle().fill(Color.green).frame(width: 5, height: 5)
                    .modifier(BreathingDot())
            }
            if store.attentionAgent != nil {
                Circle().fill(Color.orange).frame(width: 5, height: 5)
                    .modifier(BreathingDot())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }
}

// MARK: - Peek (summary)

private struct PeekContent: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        HStack(spacing: 10) {
            if let attn = store.attentionAgent {
                attentionRow(attn)
            } else if let running = primaryRunning {
                runningRow(running)
            } else {
                idleRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var primaryRunning: AgentState? {
        store.agents.filter { !$0.isStale && $0.status == .running }
            .max { $0.updated_at < $1.updated_at }
    }

    private func attentionRow(_ a: AgentState) -> some View {
        HStack(spacing: 8) {
            AgentIcon(kind: a.kind, accent: .orange)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(a.display_name)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("needs your input")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            PulseDot(color: .orange, pulse: true)
        }
    }

    private func runningRow(_ a: AgentState) -> some View {
        HStack(spacing: 8) {
            AgentIcon(kind: a.kind, accent: .green)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(a.display_name)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let task = a.task {
                    Text(task)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                let dots = store.agents.prefix(5)
                ForEach(Array(dots), id: \.agent_id) { a in
                    PulseDot(color: dotColor(for: a),
                             pulse: !a.isStale && (a.status == .running || a.needs_attention))
                }
            }
        }
    }

    private var idleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
            Text("AgentIsland")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Expanded (full list)

private struct ExpandedContent: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider().background(Color.white.opacity(0.08))
            if store.agents.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(store.agents) { agent in
                        ExpandedAgentRow(agent: agent)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.dotted.and.circle")
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
                PulseDot(color: accentColor,
                         pulse: !agent.isStale && (agent.status == .running || agent.needs_attention))
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
                .strokeBorder(agent.needs_attention ? Color.orange.opacity(0.35) : Color.white.opacity(0.05),
                              lineWidth: 0.5)
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

// MARK: - Shared bits

func dotColor(for a: AgentState) -> Color {
    if a.isStale { return .gray }
    if a.needs_attention { return .orange }
    switch a.status {
    case .running:        return .green
    case .waiting_input:  return .orange
    case .idle:           return Color(red: 0.45, green: 0.65, blue: 1.0)
    case .done:           return .gray
    case .error:          return .red
    }
}

struct PulseDot: View {
    let color: Color
    let pulse: Bool
    @State private var ring = false

    var body: some View {
        ZStack {
            if pulse {
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: 2)
                    .scaleEffect(ring ? 2.4 : 1.0)
                    .opacity(ring ? 0 : 1)
            }
            Circle().fill(color)
                .shadow(color: color.opacity(0.55), radius: 3)
        }
        .frame(width: 8, height: 8)
        .onAppear {
            if pulse {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    ring = true
                }
            }
        }
    }
}

struct BreathingDot: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1.0 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

struct AgentIcon: View {
    let kind: String
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(
                    colors: [accent.opacity(0.35), accent.opacity(0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(accent.opacity(0.5), lineWidth: 0.5)
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
