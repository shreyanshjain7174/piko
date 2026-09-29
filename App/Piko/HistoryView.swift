import SwiftUI
import UIKit
import PikoKit
import PikoUI

struct HistoryView: View {
    @State private var searchText = ""
    @State private var results: [CaptureResult] = []
    @State private var hasLoaded = false
    @State private var copiedID: UUID?
    private var skin: Skin { AppComposition.shared.channel.readState()?.skin ?? .cute }

    var body: some View {
        ZStack {
            AuroraBackground(phase: .idle, tint: skin.controlTint)
                .ignoresSafeArea()
            List {
                if !results.isEmpty {
                    Section {
                        ForEach(results) { result in
                            NavigationLink {
                                DictationDetailView(result: result)
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
                                .tint(skin.controlTint)
                            }
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(.white.opacity(0.07)))
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    } header: {
                        Text(searchText.isEmpty ? "Recent dictations" : "Search results")
                            .foregroundStyle(.white.opacity(0.5))
                    } footer: {
                        Text("Saved on this iPhone. Swipe right to copy, left to delete.")
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .overlay {
                if hasLoaded && results.isEmpty {
                    ContentUnavailableView {
                        Label(searchText.isEmpty ? "Your words, all here." : "No matching dictations",
                              systemImage: searchText.isEmpty ? "text.bubble" : "magnifyingglass")
                    } description: {
                        Text(searchText.isEmpty
                             ? "Your first dictation will appear here.\nStart one from Home or the Piko keyboard."
                             : "Try a different word or phrase.")
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
            .searchable(text: $searchText, prompt: "Search your words")
        }
        .navigationTitle("History")
        .preferredColorScheme(.dark)
        .refreshable { await reload() }
        .task(id: searchText) {
            if !searchText.isEmpty {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            }
            await reload()
        }
        .task {
            for await signal in AppComposition.shared.channel.signals where signal == .resultReady {
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
    }

    private func row(_ result: CaptureResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                if copiedID == result.id {
                    Label("Copied", systemImage: "checkmark")
                } else {
                    Text(result.profile.displayName)
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.5))

            Text(result.shipped.isEmpty ? "Empty dictation" : result.shipped)
                .font(.body)
                .foregroundStyle(.white)
                .lineLimit(3)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the full dictation.")
    }

    private func reload() async {
        let query = searchText
        let found = await AppComposition.shared.memory.search(query, limit: 100)
        guard !Task.isCancelled, query == searchText else { return }
        results = found
        hasLoaded = true
    }

    private func delete(_ result: CaptureResult) async {
        await AppComposition.shared.memory.delete(result.id)
        await reload()
    }
}

private struct DictationDetailView: View {
    let result: CaptureResult
    @State private var showCorrection = false
    @State private var copied = false
    @State private var savedCorrection = false

    var body: some View {
        let skinTint = AppComposition.shared.channel.readState()?.skin.controlTint ?? Color.cyan
        return ZStack {
            AuroraBackground(phase: .idle, tint: skinTint)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text(result.profile.displayName)
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))

                    Text(result.shipped)
                        .font(.system(size: 23, weight: .regular))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(22)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))

                    HStack(spacing: 16) {
                        Button {
                            UIPasteboard.general.string = result.shipped
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy text", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(skinTint)
                        .foregroundStyle(.black.opacity(0.85))
                        ShareLink(item: result.shipped) {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 44, height: 44)
                        }
                        .foregroundStyle(.white)
                        .accessibilityLabel("Share dictation")
                    }

                    if result.raw != result.shipped {
                        DisclosureGroup("Original transcript") {
                            Text(result.raw)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.6))
                                .textSelection(.enabled)
                                .padding(.top, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .tint(.white)
                    }

                    Button {
                        showCorrection = true
                    } label: {
                        Label(savedCorrection ? "Correction saved" : "Suggest a correction",
                              systemImage: savedCorrection ? "checkmark.circle" : "square.and.pencil")
                            .font(.subheadline)
                            .frame(minHeight: 44)
                    }
                    .foregroundStyle(savedCorrection ? .green : .white.opacity(0.8))
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Dictation")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showCorrection) {
            CorrectionView(result: result) { corrected in
                Task {
                    await AppComposition.shared.memory.recordEdit(
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
            .navigationTitle("Suggest a correction")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
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
