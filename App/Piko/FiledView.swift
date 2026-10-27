import SwiftUI
import PikoKit
import PikoUI

/// Notes and journal entries Piko filed from brain-dumps. Reminders live in Apple Reminders.
struct FiledView: View {
    let app: AppComposition
    @Environment(\.pikoTheme) private var theme
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
                PikoEmptyState(kind == .note ? "No notes yet" : "Your journal is waiting",
                               message: kind == .note
                                   ? "Say an idea out loud and Piko keeps it here."
                                   : "Tell Piko how today felt. It stays on this iPhone.")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.createdAt.formatted(.dateTime.weekday(.wide).day().month()))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(kind == .journal ? theme.accent : theme.ink2)
                        Text(item.text)
                            .font(kind == .journal ? .system(.title3, design: .serif) : .body)
                            .foregroundStyle(theme.ink)
                            .lineSpacing(kind == .journal ? 4 : 1)
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(theme.card)
                }
            }
        }
        .pikoForm()
        .animation(.easeInOut(duration: 0.25), value: kind)
        .navigationTitle("Filed")
        .task(id: kind) { items = await app.items.items(kind: kind, limit: 200) }
        .refreshable { items = await app.items.items(kind: kind, limit: 200) }
    }
}
