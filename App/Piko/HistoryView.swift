import SwiftUI
import UIKit
import PikoKit
import PikoUI

struct HistoryView: View {
    let app: AppComposition
    @Environment(\.pikoTheme) private var theme
    @State private var searchText = ""
    @State private var results: [CaptureResult] = []
    @State private var hasLoaded = false
    @State private var copiedID: UUID?

    var body: some View {
        List {
            if !results.isEmpty {
                Section {
                    ForEach(results) { result in
                        NavigationLink {
                            DictationDetailView(result: result, app: app)
                        } label: {
                            row(result)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await delete(result) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                UIPasteboard.general.string = result.shipped
                                copiedID = result.id
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .tint(theme.accent)
                        }
                        .listRowBackground(theme.card)
                    }
                } header: {
                    Text(searchText.isEmpty ? "Recent dictations" : "Search results")
                } footer: {
                    Text("Saved on this iPhone. Swipe right to copy, left to delete.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .pikoForm()
        .overlay {
            if hasLoaded && results.isEmpty {
                PikoEmptyState(searchText.isEmpty ? "Your words, all here" : "Nothing matches that",
                               message: searchText.isEmpty
                                   ? "Everything you tell Piko lands here, newest first."
                                   : "Try a different word or phrase.")
            }
        }
        .searchable(text: $searchText, prompt: "Search your words")
        .navigationTitle("History")
        .refreshable { await reload() }
        .task(id: searchText) {
            if !searchText.isEmpty {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            }
            await reload()
        }
        .task {
            for await signal in app.channel.signals where signal == .resultReady {
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
    }

    private func row(_ result: CaptureResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(result.shipped.isEmpty ? "Empty dictation" : result.shipped)
                .font(.body)
                .foregroundStyle(theme.ink)
                .lineLimit(3)

            HStack {
                Text(result.createdAt.formatted(.relative(presentation: .named)))
                Spacer()
                if copiedID == result.id {
                    Label("Copied", systemImage: "checkmark")
                        .foregroundStyle(theme.accent)
                }
            }
            .font(.subheadline)
            .foregroundStyle(theme.ink2)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the full dictation.")
    }

    private func reload() async {
        let query = searchText
        let found = await app.memory.search(query, limit: 100)
        guard !Task.isCancelled, query == searchText else { return }
        results = found
        hasLoaded = true
    }

    private func delete(_ result: CaptureResult) async {
        await app.memory.delete(result.id)
        await reload()
    }
}

private struct DictationDetailView: View {
    let result: CaptureResult
    let app: AppComposition
    @Environment(\.pikoTheme) private var theme
    @State private var showCorrection = false
    @State private var copied = false
    @State private var savedCorrection = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(result.createdAt.formatted(date: .complete, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(theme.ink2)

                Text(result.shipped)
                    .font(.system(size: 24, weight: .regular, design: .rounded))
                    .foregroundStyle(theme.ink)
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .bubble(from: .you, fill: theme.wash)

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = result.shipped
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy text", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.piko)
                    ShareLink(item: result.shipped) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.pikoQuiet)
                    .accessibilityLabel("Share dictation")
                }

                if result.raw != result.shipped {
                    DisclosureGroup("Original transcript") {
                        Text(result.raw)
                            .font(.body)
                            .foregroundStyle(theme.ink2)
                            .textSelection(.enabled)
                            .padding(.top, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.ink)
                }

                Button {
                    showCorrection = true
                } label: {
                    Label(savedCorrection ? "Correction saved" : "Suggest a correction",
                          systemImage: savedCorrection ? "checkmark.circle" : "square.and.pencil")
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
            }
            .padding(20)
        }
        .background(theme.ground)
        .toolbarBackground(theme.ground, for: .navigationBar)
        .navigationTitle("Dictation")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCorrection) {
            CorrectionView(result: result) { corrected in
                Task {
                    await app.memory.recordEdit(
                        EditPair(raw: result.raw, shipped: result.shipped, final: corrected, profile: result.profile))
                    savedCorrection = true
                }
            }
        }
    }
}

struct CorrectionView: View {
    let result: CaptureResult
    let onSave: (String) -> Void
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss

    init(result: CaptureResult, onSave: @escaping (String) -> Void) {
        self.result = result
        self.onSave = onSave
        _draft = State(initialValue: result.shipped)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 160)
                        .font(.body)
                } header: {
                    Text("How you would say it")
                } footer: {
                    Text("Saved as a local correction example. The original history entry is kept.")
                }
                Section("Original transcript") {
                    Text(result.raw).foregroundStyle(.secondary)
                }
            }
            .pikoForm()
            .navigationTitle("Suggest a correction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(draft == result.shipped || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
