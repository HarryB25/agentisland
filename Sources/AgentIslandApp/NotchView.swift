import SwiftUI
import AgentIslandCore

struct NotchView: View {
    @ObservedObject var store: AgentStore
    @Binding var expanded: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 2)

            if expanded {
                expandedContent
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                collapsedContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .frame(
            width: expanded ? 380 : pillWidth,
            height: expanded ? max(64, CGFloat(40 + store.agents.count * 44)) : 28
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: expanded)
        .animation(.easeInOut(duration: 0.15), value: store.agents)
    }

    // collapsed pill: dots + counts
    private var collapsedContent: some View {
        HStack(spacing: 8) {
            if store.agents.isEmpty {
                Text("AgentIsland")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
            } else {
                ForEach(store.agents) { a in
                    StatusDot(state: a)
                }
                if attentionCount > 0 {
                    Text("\(attentionCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange))
                }
            }
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AgentIsland")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Text("\(store.agents.count) agent\(store.agents.count == 1 ? "" : "s")")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
            }
            Divider().background(Color.white.opacity(0.08))
            if store.agents.isEmpty {
                Text("No agents reporting. Try `agentisland demo`.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } else {
                ForEach(store.agents) { a in
                    AgentRow(state: a)
                }
            }
        }
    }

    private var pillWidth: CGFloat {
        let n = store.agents.count
        if n == 0 { return 100 }
        return CGFloat(24 + n * 14 + (attentionCount > 0 ? 22 : 0))
    }

    private var attentionCount: Int {
        store.agents.filter { $0.needs_attention }.count
    }
}

struct StatusDot: View {
    let state: AgentState
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.6), lineWidth: pulse ? 4 : 0)
                    .scaleEffect(pulse ? 2.0 : 1.0)
                    .opacity(pulse ? 0 : 1)
            )
            .onAppear {
                if shouldPulse {
                    withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                        pulse = true
                    }
                }
            }
    }

    private var color: Color {
        if state.isStale { return .gray }
        if state.needs_attention { return .orange }
        switch state.status {
        case .running: return .green
        case .waiting_input: return .orange
        case .idle: return .blue
        case .done: return .gray
        case .error: return .red
        }
    }

    private var shouldPulse: Bool {
        state.needs_attention || state.status == .running
    }
}

struct AgentRow: View {
    let state: AgentState

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: state)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(state.display_name)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(state.kind)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
                }
                if let task = state.task, !task.isEmpty {
                    Text(task)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(elapsedString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.vertical, 4)
    }

    private var elapsedString: String {
        let elapsed = Int(Date().timeIntervalSince(state.started_at))
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        return "\(elapsed / 3600)h"
    }
}
