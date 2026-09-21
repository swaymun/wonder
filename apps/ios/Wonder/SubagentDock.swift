import SwiftUI
import WonderPairing

/// Small, value-only surface: opening the roster never replaces the parent route.
struct SubagentDock: View {
    let agents: [SubagentSummary]
    let available: Bool
    let avatarShape: ScienceAvatarShape
    let avatarPalette: ScienceAvatarPalette
    @Binding var isPresented: Bool
    let open: (SubagentSummary) -> Void

    private var active: [SubagentSummary] { agents.filter { !$0.isFinished } }
    private var completed: [SubagentSummary] { agents.filter(\.isFinished) }
    private var label: String {
        let running = agents.filter { ["active", "running", "inProgress"].contains($0.status) }.count
        let count = available && running > 0 ? running : agents.count
        return "\(count) \(count == 1 ? "agent" : "agents")" + (available && running > 0 ? " running" : "")
    }

    var body: some View {
        if !agents.isEmpty {
            HStack(alignment: .bottom) {
                Spacer(minLength: 0)
                Button { isPresented.toggle() } label: {
                    HStack(spacing: 6) {
                        familyIcon
                        Text(label).fixedSize(horizontal: false, vertical: true)
                    }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                        .frame(minHeight: 44, alignment: .bottom)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("subagent-status-pill")
                .accessibilityLabel(label)
                .accessibilityValue(isPresented ? "Expanded" : "Collapsed")
                .accessibilityHint("Show running and completed agent tasks")
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            section("Running", agents: active)
                            section("Completed", agents: completed)
                        }.padding()
                    }
                    .frame(idealWidth: 320, maxWidth: 360, idealHeight: 280, maxHeight: 360)
                    .presentationCompactAdaptation(.popover)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func section(_ title: String, agents: [SubagentSummary]) -> some View {
        if !agents.isEmpty {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(agents) { agent in
                Button { open(agent) } label: {
                    HStack(spacing: 10) {
                        familyIcon
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.title).foregroundStyle(.primary)
                            Text(available ? agent.statusLabel : "Last known: " + agent.statusLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("subagent-roster:" + agent.id)
                .accessibilityLabel(agent.title + ", " + (available ? agent.statusLabel : "Last known: " + agent.statusLabel))
                .accessibilityHint("Open read-only agent task")
            }
        }
    }

    private var familyIcon: some View {
        ScienceAvatarGroup(shape: avatarShape, palette: avatarPalette)
            .accessibilityHidden(true)
    }
}
