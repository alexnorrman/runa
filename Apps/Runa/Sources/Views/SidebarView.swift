import RunaCore
import RunaDesign
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Bindable var store: ProjectStore

    var body: some View {
        VStack(spacing: 0) {
            ProjectSwitcher(store: store)
                .padding(.horizontal, RunaSpacing.s)
                .padding(.top, RunaSpacing.xs)
                .padding(.bottom, RunaSpacing.s)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    row(.keys(.all), "All keys", icon: "list.bullet", count: store.count(.all))
                    row(.keys(.missing(nil)), "Missing", icon: "circle.dashed", count: store.count(.missing(nil)), tint: RunaColor.missing)
                    row(.review, "Review", icon: "checkmark.circle", count: store.reviewCount, tint: RunaColor.review)
                    row(.languages, "Languages", icon: "globe")
                    row(.activity, "Activity", icon: "clock.arrow.circlepath")
                    row(.importStrings, "Import", icon: "square.and.arrow.down")

                    if let snapshot = store.snapshot, !snapshot.settings.targetLocales.isEmpty {
                        header("Languages")
                        ForEach(snapshot.settings.locales, id: \.self) { locale in
                            let coverage = store.statusIndex.coverage(for: locale)
                            SidebarRow(locale.displayName(), isSelected: store.sidebar == .keys(.missing(locale))) {
                                store.sidebar = .keys(.missing(locale))
                            } leading: {
                                Text(locale.rawValue.uppercased())
                                    .font(RunaFont.font(size: 9.5, weight: .semibold))
                                    .foregroundStyle(RunaColor.textTertiary)
                                    .lineLimit(1)
                                    .fixedSize()
                            } trailing: {
                                if coverage.missing > 0 {
                                    Text("\(coverage.missing)").font(RunaFont.small).monospacedDigit().foregroundStyle(RunaColor.missing)
                                } else {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(RunaColor.approved)
                                }
                            }
                        }
                    }
                    if !store.allTags.isEmpty {
                        header("Tags")
                        ForEach(store.allTags, id: \.self) { tag in
                            row(.keys(.tag(tag)), tag, icon: "number", count: store.count(.tag(tag)))
                        }
                    }
                }
                .padding(.horizontal, RunaSpacing.s)
                .padding(.bottom, RunaSpacing.l)
            }
        }
        .background(RunaColor.panel)
    }

    func header(_ title: String) -> some View {
        Text(title)
            .font(RunaFont.font(size: 11.5, weight: .medium))
            .foregroundStyle(RunaColor.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, RunaSpacing.l)
            .padding(.bottom, 4)
    }

    func row(_ item: SidebarItem, _ title: String, icon: String, count: Int? = nil, tint: Color? = nil) -> some View {
        SidebarRow(title, isSelected: store.sidebar == item) {
            store.sidebar = item
        } leading: {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(store.sidebar == item ? RunaColor.textPrimary : RunaColor.textTertiary)
        } trailing: {
            if let count, count > 0 {
                Text("\(count)").font(RunaFont.small).monospacedDigit().foregroundStyle(tint ?? RunaColor.textTertiary)
            }
        }
    }
}

struct ProjectSwitcher: View {
    @Environment(AppModel.self) private var app
    let store: ProjectStore

    var body: some View {
        Menu {
            ForEach(app.projects) { project in
                Button {
                    app.selectedProjectID = project.id
                } label: {
                    if project.id == store.record.id { Label(project.name, systemImage: "checkmark") } else { Text(project.name) }
                }
            }
            Divider()
            Button("Add Project…") { app.isAddingProject = true }
            if let url = store.record.location.webURL {
                Button(store.record.location.kind == .googleSheets ? "Open Sheet in Browser" : "Show File in Finder") {
                    if url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
                }
            }
            Button("Project Settings…") { store.isEditingProject = true }
            Divider()
            Button("Remove \(store.record.name) from Runa…", role: .destructive) { store.isConfirmingRemoval = true }
        } label: {
            HStack(spacing: RunaSpacing.s) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [RunaColor.accentHover, RunaColor.accent], startPoint: .top, endPoint: .bottom))
                    .frame(width: 20, height: 20)
                    .overlay(Text(String(store.record.name.prefix(1)).uppercased()).font(RunaFont.font(size: 11, weight: .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.record.name).font(RunaFont.bodyMedium).foregroundStyle(RunaColor.textPrimary).lineLimit(1)
                    Text(store.record.location.kind.displayName).font(RunaFont.font(size: 11)).foregroundStyle(RunaColor.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(RunaColor.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .background(RoundedRectangle(cornerRadius: RunaRadius.control).fill(RunaColor.hover.opacity(0.6)))
        .sheet(isPresented: Binding(get: { store.isEditingProject }, set: { store.isEditingProject = $0 })) {
            ProjectSettingsSheet(store: store)
        }
        .confirmationDialog("Remove \(store.record.name) from Runa?", isPresented: Binding(get: { store.isConfirmingRemoval }, set: { store.isConfirmingRemoval = $0 })) {
            Button("Remove", role: .destructive) { app.remove(store.record) }
        } message: {
            Text("The strings stay in the \(store.record.location.kind == .googleSheets ? "sheet" : "file"). Only Runa's link to it is removed.")
        }
    }
}
