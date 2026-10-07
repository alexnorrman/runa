import RunaCore
import RunaDesign
import SwiftUI
import UniformTypeIdentifiers

/// Import strings files: parse, compare with the backend, let the user settle conflicts, then apply.
struct ImportView: View {
    @Bindable var store: ProjectStore
    @State private var plan: ImportPlan?
    @State private var files: [String] = []
    @State private var warnings: [String] = []
    @State private var addLocales: Set<LocaleCode> = []
    @State private var kindFilter: ImportItemKind?
    @State private var dropping = false
    @State private var applying = false
    @State private var applied: String?
    @State private var choosing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Import").runaTitle(RunaFont.title3)
                Spacer()
                if plan != nil {
                    Button("Start Over") { reset() }.buttonStyle(.runa(.ghost, size: .small))
                }
                Button("Choose Files…") { choosing = true }.buttonStyle(.runaSecondary)
            }
            .padding(.horizontal, RunaSpacing.l)
            .padding(.vertical, RunaSpacing.m)
            HairlineDivider()
            if let plan {
                planView(plan)
            } else {
                dropZone
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { load(urls) }
        }
    }

    var dropZone: some View {
        VStack(spacing: RunaSpacing.l) {
            if let applied { Banner(.success, title: applied) { EmptyView() }.frame(maxWidth: 520) }
            VStack(spacing: RunaSpacing.m) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 30, weight: .light)).foregroundStyle(RunaColor.textTertiary)
                Text("Drop strings files or folders").font(RunaFont.title3).foregroundStyle(RunaColor.textPrimary)
                Text("Android strings.xml, iOS .strings, .stringsdict and .xcstrings, and web JSON (i18next or ICU). Languages are read from folder names like values-sv or sv.lproj.")
                    .font(RunaFont.body).foregroundStyle(RunaColor.textTertiary).multilineTextAlignment(.center).frame(maxWidth: 440)
                Text("Nothing is written until you review the changes.").font(RunaFont.small).foregroundStyle(RunaColor.textQuaternary)
            }
            .padding(RunaSpacing.xxl)
            .frame(maxWidth: 560)
            .background(RoundedRectangle(cornerRadius: RunaRadius.sheet)
                .strokeBorder(dropping ? RunaColor.accent : RunaColor.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6])))
            .background(RoundedRectangle(cornerRadius: RunaRadius.sheet).fill(dropping ? RunaColor.selected : .clear))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            load(urls)
            return true
        } isTargeted: { dropping = $0 }
    }

    func planView(_ plan: ImportPlan) -> some View {
        let summary = plan.summary
        let shown = plan.items.filter { kindFilter == nil ? $0.kind != .same : $0.kind == kindFilter }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: RunaSpacing.s) {
                Text(files.count == 1 ? files[0] : "\(files.count) files").font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
                HStack(spacing: RunaSpacing.s) {
                    filterChip(nil, "Changes", plan.items.filter { $0.kind != .same }.count)
                    ForEach(ImportItemKind.allCases, id: \.self) { kind in
                        if let count = summary[kind], count > 0 { filterChip(kind, label(kind), count) }
                    }
                    Spacer()
                    if (summary[.conflict] ?? 0) > 0 {
                        Menu("Resolve Conflicts") {
                            Button("Use File for All") { self.plan?.resolveConflicts(.useFile) }
                            Button("Keep Backend for All") { self.plan?.resolveConflicts(.keepBackend) }
                            Divider()
                            ForEach(Array(Set(plan.items(.conflict).map(\.locale))).sorted(), id: \.self) { locale in
                                Button("Use File for \(locale.displayName())") { self.plan?.resolveConflicts(.useFile, locale: locale) }
                            }
                        }
                        .fixedSize()
                    }
                }
                ForEach(plan.newLocales, id: \.self) { locale in
                    Toggle(isOn: Binding(get: { addLocales.contains(locale) }, set: { if $0 { addLocales.insert(locale) } else { addLocales.remove(locale) } })) {
                        Text("Add \(locale.displayName()) (\(locale.rawValue)) to the project; otherwise its strings are skipped").font(RunaFont.body)
                    }
                    .toggleStyle(.runaCheckbox)
                }
                ForEach(warnings.prefix(5), id: \.self) { warning in
                    Text(warning).font(RunaFont.small).foregroundStyle(RunaColor.review)
                }
            }
            .padding(RunaSpacing.l)
            HairlineDivider()
            List {
                ForEach(shown) { item in
                    ImportRow(item: item) { resolution in
                        guard let index = self.plan?.items.firstIndex(where: { $0.id == item.id }) else { return }
                        self.plan?.items[index].resolution = resolution
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            HairlineDivider()
            HStack {
                let changes = plan.changes(projectLocales: (store.snapshot?.settings.locales ?? []) + Array(addLocales))
                Text("\(changes.count) changes will be written. Each is recorded in history as an import.")
                    .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
                Spacer()
                Button(applying ? "Importing…" : "Import") { apply(plan) }
                    .buttonStyle(.runaPrimary).disabled(changes.isEmpty || applying)
            }
            .padding(RunaSpacing.l)
        }
    }

    func filterChip(_ kind: ImportItemKind?, _ title: String, _ count: Int) -> some View {
        Button { kindFilter = kind } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)").monospacedDigit().foregroundStyle(RunaColor.textTertiary)
            }
            .font(RunaFont.smallMedium)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: RunaRadius.control).fill(kindFilter == kind ? RunaColor.selected : RunaColor.hover))
        }
        .buttonStyle(.plain)
    }

    func label(_ kind: ImportItemKind) -> String {
        switch kind {
        case .newKey: "New keys"
        case .newTranslation: "New translations"
        case .same: "Identical"
        case .conflict: "Conflicts"
        case .mismatch: "Needs attention"
        }
    }

    func reset() {
        plan = nil
        files = []
        warnings = []
        addLocales = []
        kindFilter = nil
    }

    func load(_ urls: [URL]) {
        guard let snapshot = store.snapshot else { return }
        var paths: [String] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let file = enumerator?.nextObject() as? URL {
                    if file.path.contains("/node_modules/") || file.path.contains("/build/") { continue }
                    if isStringsFile(file) { paths.append(file.path) }
                }
            } else {
                paths.append(url.path)
            }
        }
        var entries: [ImportedEntry] = []
        var collected: [String] = []
        for path in paths.sorted() {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            do {
                let parsed = try FormatDetector.parse(path: path, data: data, defaultLocale: snapshot.settings.sourceLocale)
                entries += parsed.entries
                collected += parsed.warnings
            } catch {
                collected.append((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
        let plan = ImportPlanner.plan(entries, against: snapshot)
        self.plan = plan
        files = paths.map { ($0 as NSString).abbreviatingWithTildeInPath }
        warnings = collected + plan.warnings
        addLocales = Set(plan.newLocales)
        applied = nil
    }

    func isStringsFile(_ url: URL) -> Bool {
        switch url.pathExtension {
        case "xcstrings", "strings", "stringsdict": return true
        case "xml": return url.lastPathComponent == "strings.xml" && url.deletingLastPathComponent().lastPathComponent.hasPrefix("values")
        case "json": return FormatDetector.detect(path: url.path)?.locale != nil
        default: return false
        }
    }

    func apply(_ plan: ImportPlan) {
        applying = true
        let locales = addLocales.sorted()
        Task {
            for locale in locales {
                _ = await store.run { backend, context in try await backend.addLocale(locale, context: context) }
            }
            let changes = plan.changes(projectLocales: store.snapshot?.settings.locales ?? [])
            store.perform(changes)
            let note = "import " + Set(plan.items.map(\.file)).sorted().prefix(3).joined(separator: ", ")
            await store.push(note: note)
            applying = false
            applied = "Imported \(changes.count) changes."
            reset()
        }
    }
}

struct ImportRow: View {
    let item: ImportItem
    let resolve: (ImportResolution) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: RunaSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.keyName).font(RunaFont.keyName).foregroundStyle(RunaColor.textPrimary).lineLimit(1)
                Text("\(item.locale.displayName()) · \(item.file)").font(RunaFont.font(size: 11)).foregroundStyle(RunaColor.textQuaternary)
            }
            .frame(width: 220, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if let current = item.current, item.kind == .conflict || item.kind == .mismatch {
                    valueLine("Backend", current, struck: item.resolution == .useFile)
                }
                valueLine(item.kind == .conflict || item.kind == .mismatch ? "File" : "", item.imported, struck: item.resolution == .keepBackend && item.kind != .newKey && item.kind != .newTranslation)
                if let reason = item.reason { Text(reason).font(RunaFont.small).foregroundStyle(RunaColor.review) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch item.kind {
            case .conflict:
                Picker("", selection: Binding(get: { item.resolution == .useFile ? 1 : 0 }, set: { resolve($0 == 1 ? .useFile : .keepBackend) })) {
                    Text("Keep backend").tag(0)
                    Text("Use file").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            case .mismatch:
                Chip("fix in the editor", tint: RunaColor.review)
            case .newKey:
                Chip("new key", tint: RunaColor.accent)
            case .newTranslation:
                Chip("new", tint: RunaColor.approved)
            case .same:
                Chip("identical")
            }
        }
        .padding(.vertical, 6)
    }

    func valueLine(_ label: String, _ forms: [PluralCategory: String], struck: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !label.isEmpty { Text(label).font(RunaFont.font(size: 10.5, weight: .semibold)).foregroundStyle(RunaColor.textQuaternary).frame(width: 46, alignment: .leading) }
            Text(forms.count == 1 ? (forms.values.first ?? "") : forms.sorted { $0.key < $1.key }.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: "\n"))
                .font(RunaFont.body)
                .foregroundStyle(struck ? RunaColor.textQuaternary : RunaColor.textSecondary)
                .strikethrough(struck)
                .lineLimit(3)
        }
    }
}
