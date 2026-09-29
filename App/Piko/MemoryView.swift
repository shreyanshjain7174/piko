import SwiftUI
import PikoKit
import PikoUI

/// "What Piko remembers" — the transparency contract made visible. Every entity in the
/// graph, hottest first, one swipe to forget (docs/MEMORY-ARCHITECTURE.md).
struct MemoryView: View {
    @State private var entities: [RememberedEntity] = []
    @State private var hasLoaded = false

    var body: some View {
        ZStack {
            AuroraBackground(phase: .idle, tint: AppComposition.shared.channel.readState()?.skin.controlTint ?? .cyan)
                .ignoresSafeArea()
            List {
                Section {
                    ForEach(entities) { entity in
                        HStack(spacing: 14) {
                            Image(systemName: entity.kind.symbolName)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 34, height: 34)
                                .background(.white.opacity(0.08), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entity.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.white)
                                Text("\(entity.hitCount) mention\(entity.hitCount == 1 ? "" : "s") · last seen \(relative(entity.lastSeen))")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    await AppComposition.shared.memory.forget(entity: entity.name)
                                    await reload()
                                }
                            } label: {
                                Label("Forget", systemImage: "memorychip")
                            }
                        }
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(.white.opacity(0.07)))
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                } header: {
                    Text("People, places and things from your dictations")
                        .foregroundStyle(.white.opacity(0.5))
                } footer: {
                    Text("Built on this iPhone. Swipe to forget — it happens immediately.")
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .overlay {
                if hasLoaded && entities.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing remembered yet", systemImage: "memorychip")
                    } description: {
                        Text("Dictate something with a person, place or thing in it and it shows up here.")
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .navigationTitle("What Piko remembers")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        entities = await AppComposition.shared.memory.rememberedEntities(limit: 200)
        hasLoaded = true
    }

    private func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
