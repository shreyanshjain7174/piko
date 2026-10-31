import SwiftUI
import PikoKit
import PikoBrain

/// Presents only facts that the real memory store has returned. No history or companion
/// preferences are inferred to be saved personal knowledge.
@MainActor
final class PersonalMemorySettingsModel: ObservableObject {
    static let limit = 100

    @Published var query = ""
    @Published private(set) var facts: [MemoryFact] = []
    @Published private(set) var sourceDescriptions: [String: String] = [:]
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var isForgetting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var publishError: String?
    @Published private(set) var pendingFact: MemoryFact?
    @Published private(set) var editingFact: MemoryFact?
    @Published private(set) var isEditing = false
    #if DEBUG
    @Published private(set) var suggestionsCount = 0
    #endif

    private let memory: any Memory
    private var loadID = UUID()

    init(memory: any Memory) {
        self.memory = memory
    }

    var reachedLimit: Bool { facts.count == Self.limit }

    var limitMessage: String {
        reachedLimit
            ? "100 results shown. More may match; narrow your search."
            : "Showing up to 100 saved facts per search. Search to narrow the results."
    }

    func sourceDescription(for fact: MemoryFact) -> String {
        sourceDescriptions[fact.key] ?? "Original source is no longer available."
    }

    func load() async {
        guard !isForgetting, !isEditing else { return }
        let id = UUID()
        loadID = id
        let requestedQuery = query
        let search = requestedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        facts = []
        sourceDescriptions = [:]
        hasLoaded = false
        errorMessage = nil
        isLoading = true
        defer { if loadID == id { isLoading = false } }

        do {
            let found = try await memory.facts(matching: search.isEmpty ? nil : search,
                                               limit: Self.limit)
            var sources: [String: String] = [:]
            for fact in found {
                guard !Task.isCancelled, loadID == id, query == requestedQuery else { return }
                if let sourceTurn = fact.sourceTurn,
                   let turn = try await memory.turn(lsn: sourceTurn) {
                    sources[fact.key] = "Source: \(turn.text)"
                }
            }
            guard !Task.isCancelled, loadID == id, query == requestedQuery else { return }
            sourceDescriptions = sources
            facts = found
            hasLoaded = true
            if let publisher = memory as? PublishingMemory {
                publishError = await publisher.publishError
                errorMessage = publishError
                #if DEBUG
                suggestionsCount = await publisher.snapshotCount()
                #endif
            }
        } catch {
            guard !Task.isCancelled, loadID == id, query == requestedQuery else { return }
            print("Piko saved-facts read failed: \(error)")
            if case PersonalMemoryError.invalidQuery = error {
                errorMessage = "Search must be 256 bytes or fewer. Shorten your search and try again."
            } else {
                errorMessage = "Piko could not read saved facts from local storage. Try again; do not delete the app."
            }
            hasLoaded = true
        }
    }

    func selectForEdit(_ fact: MemoryFact) {
        guard !isLoading, !isForgetting, !isEditing, (errorMessage == nil || errorMessage == publishError),
              facts.contains(where: { $0.key == fact.key && $0.lsn == fact.lsn }) else { return }
        editingFact = fact
    }

    func cancelEdit() { editingFact = nil }

    func confirmEdit(_ value: String) async {
        guard !isEditing, let selected = editingFact else { return }
        editingFact = nil
        isEditing = true
        loadID = UUID()
        isLoading = false
        errorMessage = nil
        defer { isEditing = false }
        let label = String(selected.key.split(separator: "/").last ?? "fact")
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard try await memory.fact(forKey: selected.key)?.lsn == selected.lsn else {
                errorMessage = "This saved fact changed since you selected it. Refresh and review it before editing."
                return
            }
            let quote = "Update \(label) to \(value)"
            let turn = try await memory.appendTurn(session: UUID(), role: .user, text: quote, at: .now)
            let entityName: String?
            if let entityID = selected.entityID { entityName = try await memory.entity(id: entityID)?.name }
            else { entityName = nil }
            let proposal = ContextProposal(kind: .fact, entityName: entityName, key: selected.key,
                                           label: label, value: value, quote: quote, sourceTurn: turn)
            let organizer = ContextOrganizer(memory: memory)
            let staged = try await organizer.stage(proposal)
            guard case .conflict(_, let existing) = staged, existing.lsn == selected.lsn else {
                errorMessage = "This saved fact changed. Refresh and review it before editing."
                return
            }
            guard case .saved = try await organizer.resolve(.replace, on: staged, observedLSN: selected.lsn) else {
                errorMessage = "This saved fact changed. Refresh and review it before editing."
                return
            }
            isEditing = false
            await load()
        } catch ProposalGateError.sensitiveContent {
            errorMessage = "Piko does not save passwords, payment, codes or ID numbers."
        } catch PersonalMemoryError.factConflict {
            errorMessage = "This saved fact changed. Refresh and review it before editing."
        } catch {
            errorMessage = "Piko could not edit this saved fact. Refresh to check its current value."
        }
    }

    func selectForForget(_ fact: MemoryFact) {
        guard !isLoading, !isForgetting, (errorMessage == nil || errorMessage == publishError),
              facts.contains(where: { $0.key == fact.key && $0.lsn == fact.lsn }) else { return }
        pendingFact = fact
    }

    func cancelForget() {
        pendingFact = nil
    }

    func confirmForget() async {
        guard !isForgetting, let selected = pendingFact else { return }
        pendingFact = nil
        isForgetting = true
        // An in-flight search must not restore a row after the confirmed deletion.
        loadID = UUID()
        isLoading = false
        facts = []
        sourceDescriptions = [:]
        hasLoaded = false
        errorMessage = nil
        do {
            // Use the revision shown when this fact was selected; never re-read latest and
            // delete a different value without the owner's confirmation.
            try await memory.forgetFact(forKey: selected.key, ifLSN: selected.lsn)
            isForgetting = false
            await load()
        } catch {
            print("Piko saved-fact forget failed: \(error)")
            if case PersonalMemoryError.factConflict = error {
                errorMessage = "This saved fact changed since you selected it. Refresh and review it before forgetting."
            } else {
                errorMessage = "Piko could not forget this saved fact. Refresh to check whether it is still saved."
            }
            hasLoaded = true
            isForgetting = false
        }
    }
}

struct PersonalMemoryView: View {
    @StateObject private var model: PersonalMemorySettingsModel
    @State private var showForget = false
    @State private var showEdit = false
    @State private var editValue = ""
    @Environment(\.pikoTheme) private var theme

    init(memory: any Memory) {
        _model = StateObject(wrappedValue: PersonalMemorySettingsModel(memory: memory))
    }

    var body: some View {
        Form {
            Section {
                Text("Only facts you explicitly asked Piko to remember and confirmed are saved here. Forgetting a fact does not delete the original dictation or conversation history.")
                    .foregroundStyle(theme.ink2)
                Text(model.limitMessage)
                    .font(.footnote)
                    .foregroundStyle(theme.ink2)
            }

            #if DEBUG
            Text("Suggestions: \(model.suggestionsCount)")
                .accessibilityIdentifier("suggestions-count")
            #endif

            if model.isLoading || model.isForgetting || model.isEditing {
                Section {
                    ProgressView(model.isForgetting ? "Forgetting saved fact…" : model.isEditing ? "Editing saved fact…" : "Loading saved facts…")
                }
            }

            if let warning = model.publishError {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(theme.ink)
                }
            }
            if let error = model.errorMessage, error != model.publishError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(theme.ink)
                    Button("Refresh saved facts") {
                        Task { await model.load() }
                    }
                }
            } else if model.hasLoaded && model.facts.isEmpty {
                Section {
                    Text(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "No saved facts yet. Ask Piko to remember something and confirm it before it appears here."
                         : "No saved facts match this search. Try another word or phrase.")
                        .foregroundStyle(theme.ink2)
                }
            } else if !model.facts.isEmpty {
                Section {
                    ForEach(model.facts, id: \.key) { fact in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(fact.key).font(.headline).foregroundStyle(theme.ink)
                            Text(fact.value).foregroundStyle(theme.ink)
                            Text(model.sourceDescription(for: fact))
                                .font(.footnote)
                                .foregroundStyle(theme.ink2)
                            Button("Edit saved fact") {
                                model.selectForEdit(fact)
                                if model.editingFact != nil { editValue = fact.value; showEdit = true }
                            }
                            .accessibilityIdentifier("settings.edit.\(fact.key)")
                            .disabled(model.isLoading || model.isForgetting || model.isEditing)
                            Button(role: .destructive) {
                                model.selectForForget(fact)
                                showForget = model.pendingFact != nil
                            } label: {
                                Label("Forget saved fact", systemImage: "trash")
                            }
                            .accessibilityIdentifier("settings.forget.\(fact.key)")
                            .disabled(model.isLoading || model.isForgetting)
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("settings.fact.\(fact.key)")
                    }
                } header: {
                    Text("Saved facts")
                }
            }
        }
        .pikoForm()
        .navigationTitle("What Piko knows")
        .searchable(text: $model.query, prompt: "Search saved facts")
        .refreshable { await model.load() }
        .task(id: model.query) {
            if !model.query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            }
            await model.load()
        }
        .sheet(isPresented: $showEdit, onDismiss: { model.cancelEdit() }) {
            NavigationStack {
                Form {
                    TextField("New value", text: $editValue)
                        .accessibilityIdentifier("settings.editValue")
                }
                .navigationTitle("Edit saved fact")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showEdit = false }
                            .accessibilityIdentifier("settings.editCancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save change") {
                            let value = editValue
                            Task { await model.confirmEdit(value); showEdit = false }
                        }
                        .accessibilityIdentifier("settings.editSave")
                    }
                }
            }
        }
        .alert("Forget this saved fact?", isPresented: $showForget) {
            Button("Forget saved fact", role: .destructive) {
                Task { await model.confirmForget() }
            }
            Button("Cancel", role: .cancel) { model.cancelForget() }
        } message: {
            if let selected = model.pendingFact {
                Text("Remove “\(selected.key)” (saved as “\(selected.value)”) from personal memory? Your original dictation and conversation history remain.")
            }
        }
    }
}
