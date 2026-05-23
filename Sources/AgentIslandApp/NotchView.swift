import SwiftUI
import AgentIslandCore

enum NotchUIState: Equatable {
    case compact   // hugged inside the hardware notch — visually invisible
    case peek      // narrow body hanging below the notch
    case expanded  // full agent list
}

// MARK: - Root view

struct NotchView: View {
    @ObservedObject var store: AgentStore
    let geometry: NotchGeometry
    let uiState: NotchUIState
    /// The hanging body's drawn size. Zero in compact.
    let bodySize: CGSize

    var body: some View {
        ZStack(alignment: .top) {
            // 1. Body — drawn FIRST so the notch piece overlaps & covers its top edge.
            //    The top corners of the body have a small radius that protrudes outward
            //    past the notch's vertical sides, forming the iconic DI shoulders.
            if uiState != .compact {
                bodyShape
                    .frame(width: bodySize.width, height: bodySize.height)
                    .padding(.top, geometry.notchHeight)
            } else {
                // Transparent hover catcher + optional static attention indicator
                compactBuffer
                    .frame(width: bodySize.width, height: bodySize.height)
                    .padding(.top, geometry.notchHeight)
            }

            // 2. Notch piece — sits flush with the screen top. On notched displays
            //    it lives inside the physical cutout and is visually invisible.
            //    On non-notched displays it's a small black rectangle that anchors
            //    the body and lets the rest of the menu bar remain clickable.
            notchPiece

            // 3. Content (only when body is visible)
            if uiState != .compact {
                content
                    .frame(width: bodySize.width, height: bodySize.height, alignment: .top)
                    .padding(.top, geometry.notchHeight)
                    .padding(.horizontal, contentHPad)
                    .padding(.vertical, 8)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: uiState)
        .animation(.easeInOut(duration: 0.18), value: store.agents)
    }

    /// Invisible-but-hoverable strip sitting directly below the hardware notch.
    /// If something needs attention, draws a small static orange capsule as a
    /// calm, motionless "you have a pending task" hint.
    private var compactBuffer: some View {
        ZStack {
            // Transparent hit area — Color.clear with explicit contentShape is hoverable.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
            if store.attentionAgent != nil {
                Capsule()
                    .fill(Color.orange)
                    .frame(width: 36, height: 3)
                    .shadow(color: .orange.opacity(0.35), radius: 2)
                    .padding(.top, 2)
            }
        }
    }

    private var notchPiece: some View {
        // Flush-top rectangle, no rounding on top, hardware notch hides it.
        Rectangle()
            .fill(Color.black)
            .frame(width: geometry.notchWidth,
                   // +1 to overlap the body cleanly (no hairline gap)
                   height: geometry.notchHeight + (uiState == .compact ? 0 : 1))
    }

    private var bodyShape: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: shoulderRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: shoulderRadius,
            style: .continuous
        )
        .fill(Color.black)
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)
    }

    /// Small radius on the body's top corners → they round OUTWARD past the
    /// notch's straight bottom edges, producing the convex DI shoulders.
    private var shoulderRadius: CGFloat {
        uiState == .peek ? 12 : 14
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
            PeekContent(store: store)
        case .expanded:
            ExpandedContent(store: store)
        }
    }
}

// MARK: - Peek

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
    }

    private var primaryRunning: AgentState? {
        store.agents.filter { !$0.isStale && $0.status == .running }
            .max { $0.updated_at < $1.updated_at }
    }

    private func attentionRow(_ a: AgentState) -> some View {
        HStack(spacing: 9) {
            AgentIcon(kind: a.kind, accent: .orange)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.display_name)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("needs your input")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(Color.orange.opacity(0.95))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            StatusDot(color: .orange)
        }
    }

    private func runningRow(_ a: AgentState) -> some View {
        HStack(spacing: 9) {
            AgentIcon(kind: a.kind, accent: .green)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.display_name)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let task = a.task {
                    Text(task)
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                ForEach(Array(store.agents.prefix(5)), id: \.agent_id) { a in
                    StatusDot(color: dotColor(for: a))
                }
            }
        }
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
                    agent.needs_attention ? Color.orange.opacity(0.4) : Color.white.opacity(0.05),
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
    if a.isStale { return Color(white: 0.5) }
    if a.needs_attention { return .orange }
    switch a.status {
    case .running:        return .green
    case .waiting_input:  return .orange
    case .idle:           return Color(red: 0.45, green: 0.65, blue: 1.0)
    case .done:           return Color(white: 0.5)
    case .error:          return .red
    }
}

/// A static colored dot with a subtle glow. No motion — calm by design.
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
