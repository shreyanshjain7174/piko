import SwiftUI
import PikoKit

/// Notes and journal entries Piko filed from brain-dumps. Reminders live in Apple Reminders.
struct FiledView: View {
    let app: AppComposition
    @State private var kind: DumpItem.Kind = .note
    @State private var items: [DumpItem] = []

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $kind) {
                    Text("Notes").tag(DumpItem.Kind.note)
                    Text("Journal").tag(DumpItem.Kind.journal)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            if items.isEmpty {
                ContentUnavailableView(
                    kind == .note ? "No notes yet" : "No journal entries yet",
                    systemImage: kind == .note ? "note.text" : "heart.text.square",
                    description: Text("Tap Talk to Piko and say what’s on your mind."))
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Filed")
        .task(id: kind) { items = await app.items.items(kind: kind, limit: 200) }
        .refreshable { items = await app.items.items(kind: kind, limit: 200) }
    }
}
