import SwiftUI
import PikoBrain
import PikoKit

struct ProposalCard: Equatable {
    enum Status: Equatable { case pending, saved, conflict, failed(String) }
    struct Item: Identifiable, Equatable {
        let id: UUID
        var staged: ContextOrganizer.Staged
        var observedLSN: Int64?
        var status: Status
        var changed = false

        init(staged: ContextOrganizer.Staged, id: UUID = UUID()) {
            self.id = id
            self.staged = staged
            switch staged {
            case .new: observedLSN = nil; status = .pending
            case .conflict(_, let existing): observedLSN = existing.lsn; status = .conflict
            case .unchanged(_, let existing): observedLSN = existing.lsn; status = .saved
            }
        }
        var proposal: ContextProposal {
            switch staged {
            case .new(let proposal), .unchanged(let proposal, _), .conflict(let proposal, _): proposal
            }
        }
        var existing: MemoryFact? {
            switch staged {
            case .new: nil
            case .unchanged(_, let existing), .conflict(_, let existing): existing
            }
        }
    }
    let id: UUID
    let session: UUID?
    var items: [Item]
    init(session: UUID?, items: [Item]) {
        self.id = UUID()
        self.session = session
        self.items = items
    }
}

struct ContextProposalCard: View {
    let card: ProposalCard
    let onSaveAll: @MainActor (UUID) async -> Void
    let onSave: @MainActor (UUID, UUID) async -> Void
    let onResolve: @MainActor (UUID, UUID, ContextOrganizer.Resolution) async -> Void
    let onDismiss: @MainActor (UUID) -> Void
    @State private var selectedConflict: ProposalCard.Item?
    @State private var awaitingRestage: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save these things?").font(.headline)
            ForEach(card.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(String(describing: item.proposal.kind)) · \(item.proposal.label): \(item.proposal.value)")
                    Text("You said: \"\(item.proposal.quote)\"").font(.caption)
                    if case .failed(let reason) = item.status { Text(reason).foregroundStyle(.red) }
                    if item.changed { Text("This changed since you saw it.").foregroundStyle(.orange) }
                    switch item.status {
                    case .pending:
                        Button("Save") { Task { await onSave(card.id, item.id) } }
                    case .conflict:
                        Button("Review change") { selectedConflict = item }
                    case .saved: Label("Saved", systemImage: "checkmark")
                    case .failed: EmptyView()
                    }
                }
                .accessibilityElement(children: .contain)
            }
            HStack {
                Button("Save all") { Task { await onSaveAll(card.id) } }
                    .disabled(!card.items.contains { $0.status == .pending })
                Button("Dismiss") { onDismiss(card.id) }
            }
        }
        .sheet(item: $selectedConflict) { selected in
            VStack(spacing: 16) {
                Text("Review change").font(.headline)
                if selected.changed { Text("This changed since you saw it.") }
                Text("Saved: \(selected.existing?.value ?? "Unknown")")
                Text("New: \(selected.proposal.value)")
                HStack {
                    switch selected.status {
                    case .pending:
                        Button("Not now") { selectedConflict = nil }
                        Button("Save") {
                            selectedConflict = nil
                            Task { await onSave(card.id, selected.id) }
                        }
                    case .conflict:
                        Button("Keep") {
                            selectedConflict = nil
                            Task { await onResolve(card.id, selected.id, .keep) }
                        }
                        Button("Replace") {
                            awaitingRestage = selected.id
                            selectedConflict = nil
                            Task { await onResolve(card.id, selected.id, .replace) }
                        }
                    case .saved, .failed:
                        Button("Done") { selectedConflict = nil }
                    }
                }
            }.padding()
        }
        .onChange(of: card) { _, next in
            if let awaitingRestage,
               let updated = next.items.first(where: { $0.id == awaitingRestage }), updated.changed {
                selectedConflict = updated
                self.awaitingRestage = nil
            } else if let selectedConflict,
                      let updated = next.items.first(where: { $0.id == selectedConflict.id }) {
                self.selectedConflict = updated
            }
        }
    }
}
