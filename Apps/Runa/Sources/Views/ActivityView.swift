import RunaCore
import RunaDesign
import SwiftUI

struct ActivityView: View {
    @Bindable var store: ProjectStore
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").runaTitle(RunaFont.title3)
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.runa(.ghost, size: .small))
            }
            .padding(.horizontal, RunaSpacing.l)
            .padding(.vertical, RunaSpacing.m)
            HairlineDivider()
            if loading && store.history.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.history.isEmpty {
                EmptyStateView(systemImage: "clock", title: "No activity yet", message: "Every change made through Runa, the CLI or the Figma plugin is recorded here.") { EmptyView() }
            } else {
                List {
                    ForEach(groupedByDay, id: \.day) { group in
                        Section(group.day.formatted(date: .complete, time: .omitted)) {
                            ForEach(group.entries) { entry in
                                HistoryRow(entry: entry, showKey: true)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        guard let id = entry.keyID, store.snapshot?[id: id] != nil else { return }
                                        store.sidebar = .keys(.all)
                                        store.selection = [id]
                                    }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .task { await reload() }
    }

    var groupedByDay: [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: store.history) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }

    func reload() async {
        loading = true
        _ = await store.loadHistory()
        loading = false
    }
}
