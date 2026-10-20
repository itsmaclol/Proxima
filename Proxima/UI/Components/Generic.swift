import SwiftUI

// MARK: Data-driven forms

/// One input of a `FormSheet`. Values are strings because that's what the Proxmox API takes.
struct FormField: Identifiable {
    enum Kind {
        case text, secure, number, toggle, multiline
        case choice([Choice])
        /// Several values joined with commas, e.g. storage content types.
        case multiChoice([Choice])
        /// A day as seconds since 1970, or "0" for never (expiry dates).
        case date
        /// Free text with a menu of common values, like the web UI's combo boxes (e.g. aliases for a firewall source).
        case suggested([Choice])
        /// Free text with a Scan button that asks the server for choices, given what's filled in so far (e.g. an NFS server's exports).
        case lookup(([String: String]) async throws -> [Choice])
        /// CPU flags as "+aes;-pcid": each one turned on, off, or left to the CPU type. Choices are the flag and its description.
        case flags([Choice])
    }

    struct Choice: Hashable {
        let value: String
        let label: String
        init(_ value: String, _ label: String? = nil) {
            self.value = value
            self.label = label ?? value
        }
    }

    let key: String
    let label: String
    var kind: Kind = .text
    var prompt = ""
    var help: String?
    var required = false
    /// Shown but not editable when changing an existing item (IDs, names).
    var lockedOnEdit = false

    var id: String { key }

    /// Rough row height, so sheets open tall enough for checklists and text areas.
    var estimatedHeight: CGFloat {
        let base: CGFloat = switch kind {
        case .multiline: 150
        case .multiChoice(let choices): max(46, CGFloat(choices.count) * 21 + 14)
        case .flags(let choices): CGFloat(choices.count) * 40 + 30
        default: 46
        }
        return base + (help == nil ? 0 : 18)
    }
}

/// A lookup that can't run yet, e.g. a scan before the server is filled in.
struct LookupNeeds: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// What a `FormSheet` hands back: every value, the ones to send, and optional fields the user cleared.
struct FormResult {
    let all: [String: String]
    let changed: [String: String]
    let cleared: [String]

    /// `changed` plus Proxmox's `delete=a,b` for cleared fields — the usual edit payload.
    var params: [String: String] {
        var params = changed
        if !cleared.isEmpty { params["delete"] = cleared.joined(separator: ",") }
        return params
    }

    subscript(key: String) -> String { all[key] ?? "" }
}

/// Create or edit dialog built from fields. On edit only changed values are sent, and
/// cleared optional fields are reported so the caller can pass Proxmox's `delete` parameter.
struct FormSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var message: String?
    let fields: [FormField]
    var initial: [String: String] = [:]
    var isEdit = false
    var submitTitle = "Save"
    /// Red submit button, for forms that delete something.
    var destructive = false
    let submit: (FormResult) async -> Bool

    @State private var values: [String: String] = [:]
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold())
                if let message { Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 8)

            Form {
                ForEach(fields) { field in
                    FieldControl(field: field, values: $values)
                        .disabled(isEdit && field.lockedOnEdit)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                if let missing = missingRequired { Text("\(missing) is required").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                Button(submitTitle) { Task { await save() } }
                    .buttonStyle(.glassProminent)
                    .tint(destructive ? .red : nil)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || missingRequired != nil)
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 520)
        .frame(minHeight: 260, idealHeight: min(140 + messageHeight + fields.map(\.estimatedHeight).reduce(0, +), 680))
        .onAppear { values = initial }
    }

    /// Room for the message: about 70 characters fit on a line at this width.
    private var messageHeight: CGFloat {
        guard let message else { return 0 }
        return CGFloat(message.count / 70 + 1) * 18 + 12
    }

    private var missingRequired: String? {
        fields.first { $0.required && (values[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }?.label
    }

    private func save() async {
        busy = true
        defer { busy = false }
        var all: [String: String] = [:]
        var changed: [String: String] = [:]
        var cleared: [String] = []
        for field in fields {
            let value = (values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            all[field.key] = value
            let before = initial[field.key] ?? ""
            if isEdit {
                if field.lockedOnEdit || value == before { continue }
                if value.isEmpty { cleared.append(field.key) } else { changed[field.key] = value }
            } else if !value.isEmpty {
                changed[field.key] = value
            }
        }
        if await submit(FormResult(all: all, changed: changed, cleared: cleared)) { dismiss() }
    }
}

/// The control for one `FormField`, shared by form sheets and wizards.
struct FieldControl: View {
    let field: FormField
    @Binding var values: [String: String]
    @State private var scanning = false
    @State private var found: [FormField.Choice] = []
    @State private var scanError: String?
    @State private var showingFound = false

    var body: some View {
        let binding = Binding { values[field.key] ?? "" } set: { values[field.key] = $0 }
        Group {
            switch field.kind {
            case .text:
                TextField(text: binding, prompt: Text(field.prompt)) { label }
            case .number:
                TextField(text: binding, prompt: Text(field.prompt)) { label }
                    .monospacedDigit()
            case .secure:
                SecureField(text: binding, prompt: Text(field.prompt)) { label }
            case .multiline:
                VStack(alignment: .leading, spacing: 6) {
                    label
                    TextEditor(text: binding)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 6))
                }
            case .toggle:
                Toggle(isOn: Binding { jsonBool(values[field.key]) } set: { values[field.key] = $0 ? "1" : "0" }) { label }
            case .suggested(let choices):
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("", text: binding, prompt: Text(field.prompt))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        if !choices.isEmpty {
                            Menu {
                                ForEach(choices, id: \.self) { choice in Button(choice.label) { values[field.key] = choice.value } }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Pick from the list")
                            .accessibilityLabel("Choose \(field.label)")
                        }
                    }
                } label: { label }
            case .lookup(let fetch):
                VStack(alignment: .leading, spacing: 8) {
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("", text: binding, prompt: Text(field.prompt))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        Button {
                            Task {
                                scanning = true
                                defer { scanning = false }
                                do {
                                    found = try await fetch(values)
                                    scanError = nil
                                } catch {
                                    found = []
                                    scanError = error.localizedDescription
                                }
                                showingFound = true
                            }
                        } label: {
                            if scanning { ProgressView().controlSize(.mini) } else { Image(systemName: "magnifyingglass") }
                        }
                        .buttonStyle(.borderless)
                        .disabled(scanning)
                        .help("Scan for \(field.label.lowercased())")
                        .accessibilityLabel("Scan for \(field.label)")
                    }
                } label: { label }
                // Results stay in the form, like the networks list in Wi-Fi settings: easy to compare, and reachable with Tab.
                if showingFound { foundList }
                }
            case .flags(let choices):
                VStack(alignment: .leading, spacing: 10) {
                    label
                    ForEach(choices, id: \.self) { flag in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(flag.value).font(.body.monospaced())
                                if flag.label != flag.value {
                                    Text(flag.label).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 8)
                            Picker(flag.value, selection: flagState(flag.value)) {
                                Text("Off").tag("-")
                                Text("Default").tag("")
                                Text("On").tag("+")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
            case .date:
                let seconds = Int(values[field.key] ?? "") ?? 0
                LabeledContent {
                    HStack {
                        if seconds > 0 {
                            DatePicker("", selection: Binding { Date(timeIntervalSince1970: Double(seconds)) } set: {
                                values[field.key] = String(Int(Calendar.current.startOfDay(for: $0).timeIntervalSince1970))
                            }, displayedComponents: .date)
                            .labelsHidden()
                        }
                        Toggle("Never", isOn: Binding { seconds == 0 } set: { never in
                            // A month from today is a sensible first expiry date to adjust.
                            values[field.key] = never ? "0" : String(Int(Calendar.current.startOfDay(for: .now.addingTimeInterval(30 * 86_400)).timeIntervalSince1970))
                        })
                        .toggleStyle(.checkbox)
                    }
                } label: { label }
            case .choice(let choices):
                Picker(selection: binding) {
                    if !field.required { Text(field.prompt.isEmpty ? "Default" : field.prompt).tag("") }
                    ForEach(choices, id: \.self) { Text($0.label).tag($0.value) }
                    if let current = values[field.key], !current.isEmpty, !choices.contains(where: { $0.value == current }) {
                        Text(current).tag(current)
                    }
                } label: { label }
            case .multiChoice(let choices):
                LabeledContent {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(choices, id: \.self) { choice in
                            Toggle(choice.label, isOn: Binding {
                                selected.contains(choice.value)
                            } set: { on in
                                var set = selected
                                if on { set.append(choice.value) } else { set.removeAll { $0 == choice.value } }
                                values[field.key] = choices.map(\.value).filter(set.contains).joined(separator: ",")
                            })
                            .toggleStyle(.checkbox)
                        }
                    }
                } label: { label }
            }
        }
    }

    /// The field's name, with its help underneath as in System Settings (a tooltip alone would hide it).
    @ViewBuilder private var label: some View {
        if let help = field.help {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.label)
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(field.label)
        }
    }

    private var selected: [String] {
        (values[field.key] ?? "").split(separator: ",").map(String.init)
    }

    /// One flag of "+aes;-pcid" as "+", "-" or "" (not set), keeping the others in their order.
    private func flagState(_ name: String) -> Binding<String> {
        Binding {
            let entry = (values[field.key] ?? "").split(separator: ";").first { $0.dropFirst() == name }
            return entry.map { String($0.prefix(1)) } ?? ""
        } set: { state in
            var entries = (values[field.key] ?? "").split(separator: ";").map(String.init).filter { !$0.isEmpty && $0.dropFirst() != name }
            if !state.isEmpty { entries.append(state + name) }
            values[field.key] = entries.joined(separator: ";")
        }
    }

    /// What a scan found, under the field; picking one fills the field.
    @ViewBuilder private var foundList: some View {
        HStack(alignment: .top) {
            if let scanError {
                Label(scanError, systemImage: "exclamationmark.circle").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if found.isEmpty {
                Text("Nothing found").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(found, id: \.self) { choice in
                            PickRow(title: choice.label) {
                                values[field.key] = choice.value
                                showingFound = false
                            }
                        }
                    }
                    .padding(4)
                }
                .frame(height: min(CGFloat(found.count) * 26 + 8, 180))
                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
            }
            Spacer(minLength: 0)
            Button("Close", systemImage: "xmark.circle.fill") { showingFound = false }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Hide the results")
        }
        .font(.callout)
    }
}

/// A row in a list of found values that highlights like a menu item.
private struct PickRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(hovering ? Color.white : Color.primary)
                .background(hovering ? Color.accentColor : .clear, in: .rect(cornerRadius: 5))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}

// MARK: Live API tables

struct APIColumn: Identifiable {
    let title: String
    var width: CGFloat = 120
    var monospaced = false
    let value: (JSONObject) -> String

    var id: String { title }

    init(_ title: String, width: CGFloat = 120, monospaced: Bool = false, _ value: @escaping (JSONObject) -> String) {
        self.title = title
        self.width = width
        self.monospaced = monospaced
        self.value = value
    }

    init(_ title: String, key: String, width: CGFloat = 120, monospaced: Bool = false) {
        self.init(title, width: width, monospaced: monospaced) { $0.string(key) ?? "" }
    }
}

/// How a list deletes one of its rows; the action asks for confirmation itself.
struct Deletion {
    var title = "Delete…"
    let run: () -> Void
}

extension FocusedValues {
    /// Deleting the selected row of the list that has keyboard focus, for the toolbar's trash button.
    @Entry var deletion: Deletion?
}

/// A table bound to one API list endpoint; reloads whenever something changes on the server.
struct ResourceList<Menu: View>: View {
    @Environment(Session.self) private var session
    let path: String
    var query: [String: String] = [:]
    let id: (JSONObject) -> String
    let columns: [APIColumn]
    var emptyTitle = "Nothing here yet"
    var emptySymbol = "tray"
    var emptyMessage: String?
    var transform: ([JSONObject]) -> [JSONObject] = { $0 }
    var open: ((Row) -> Void)?
    @ViewBuilder var menu: (Row) -> Menu
    /// Deleting a row, or nil for rows that can't be deleted: ends the context menu, and runs from the Delete key,
    /// Edit → Delete and the toolbar's trash button.
    var delete: ((Row) -> Deletion?)?

    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var selection: Row.ID?

    var body: some View {
        let deletion = rows.first { $0.id == selection }.flatMap { delete?($0) }
        Loadable(loading: !loaded, error: error, isEmpty: rows.isEmpty, emptyTitle: emptyTitle, emptySymbol: emptySymbol,
                 emptyMessage: emptyMessage, retry: { Task { await load() } }) {
            Table(rows, selection: $selection) {
                TableColumnForEach(columns) { column in
                    TableColumn(column.title) { row in
                        Text(column.value(row.json))
                            .fontDesign(column.monospaced ? .monospaced : .default)
                            .lineLimit(1)
                            .help(column.value(row.json))
                    }
                    .width(min: 40, ideal: column.width)
                }
            }
            .contextMenu(forSelectionType: Row.ID.self) { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    menu(row)
                    if let deletion = delete?(row) {
                        // A menu holding only this item would otherwise open on a separator.
                        if Menu.self != EmptyView.self { Divider() }
                        Button(deletion.title, role: .destructive, action: deletion.run)
                    }
                }
            } primaryAction: { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) { open?(row) }
            }
            .onDeleteCommand(perform: deletion?.run)
            .focusedValue(\.deletion, deletion)
        }
        .task(id: "\(path)\(query)\(session.revision)") { await load() }
    }

    private func load() async {
        do {
            let list = transform(try await session.client.list(path, query))
            rows = list.map { Row(id: id($0), json: $0) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// A page with a hero header and a toolbar, wrapping a list.
struct AdminPage<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    var colors: [Color] = [.indigo, .blue]
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Hero(title: title, subtitle: subtitle, symbol: symbol, colors: colors) { EmptyView() } trailing: {
                HStack(spacing: 8) { actions }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

extension View {
    /// Visual checks: launching with PROXIMA_DEBUG_ACTION=<one of ids> runs `open` once the server's resources have loaded. Debug builds only.
    func debugAction(_ ids: String..., open: @escaping () -> Void) -> some View {
        #if DEBUG
        modifier(DebugAction(ids: ids, open: open))
        #else
        self
        #endif
    }
}

#if DEBUG
private struct DebugAction: ViewModifier {
    @Environment(Session.self) private var session
    let ids: [String]
    let open: () -> Void

    func body(content: Content) -> some View {
        content.task(id: session.loaded) {
            if session.loaded, ids.contains(ProcessInfo.processInfo.environment["PROXIMA_DEBUG_ACTION"] ?? "") { open() }
        }
    }
}
#endif

/// "Remove x?" confirmation that runs a DELETE.
extension Session {
    func confirmDelete(_ title: String, message: String = "This can't be undone.", path: String, params: [String: String] = [:]) {
        confirmation = Confirmation(title: title, message: message, actionTitle: "Remove", destructive: true) { [self] in
            await run(title.replacingOccurrences(of: "?", with: ""), .delete, path, params)
        }
    }
}
