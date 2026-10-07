import RunaCore
import RunaDesign
import SwiftUI

struct ConflictsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.m) {
            HStack {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(RunaColor.review)
                Text("Someone else changed the same strings").runaTitle(RunaFont.title3)
            }
            Text("These edits were not saved because the backend changed since you last synced. Choose which version to keep.")
                .font(RunaFont.body).foregroundStyle(RunaColor.textTertiary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: RunaSpacing.s) {
                    ForEach(store.conflicts) { conflict in
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(conflict.keyName).font(RunaFont.keyName)
                                    if let locale = conflict.locale { Chip(locale.displayName()) }
                                    if let category = conflict.category, category != .other { Chip(category.rawValue) }
                                    Spacer()
                                    Text(describe(conflict.kind)).font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
                                }
                                if conflict.remote != nil || conflict.local != nil {
                                    line("Theirs", conflict.remote)
                                    line("Yours", conflict.local)
                                }
                                HStack {
                                    Spacer()
                                    Button("Keep Theirs") { store.resolve(conflict, keepMine: false) }.buttonStyle(.runa(.secondary, size: .small))
                                    if conflict.kind != .keyDeleted && conflict.kind != .unknownLocale && conflict.kind != .duplicateKey {
                                        Button("Keep Mine") { store.resolve(conflict, keepMine: true) }.buttonStyle(.runa(.primary, size: .small))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 420)
            HStack {
                Spacer()
                Button("Keep Theirs for All") {
                    for conflict in store.conflicts { store.resolve(conflict, keepMine: false) }
                    dismiss()
                }
                .buttonStyle(.runaSecondary)
            }
        }
        .padding(RunaSpacing.xl)
        .frame(width: 560)
        .background(RunaColor.elevated)
    }

    func line(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(RunaFont.font(size: 10.5, weight: .semibold)).foregroundStyle(RunaColor.textQuaternary).frame(width: 44, alignment: .leading)
            Text(value ?? "(empty)").font(RunaFont.body).foregroundStyle(value == nil ? RunaColor.textQuaternary : RunaColor.textSecondary)
        }
    }

    func describe(_ kind: ConflictKind) -> String {
        switch kind {
        case .valueChanged: "changed by someone else"
        case .metadataChanged: "details changed"
        case .contextsChanged: "Figma links changed"
        case .keyDeleted: "deleted by someone else"
        case .duplicateKey: "name already taken"
        case .keyModified: "edited before your delete"
        case .unknownLocale: "language not in the project"
        }
    }
}
