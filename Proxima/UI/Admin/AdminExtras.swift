import AppKit
import SwiftUI

/// A small toolbar row above a list: action buttons on the left, a hint on the right.
private struct ActionBar<Content: View>: View {
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
            Spacer()
            if let hint { Text(hint).font(.callout).foregroundStyle(.secondary) }
        }
        .buttonStyle(.glass)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 6)
    }
}

// MARK: Notifications

/// `disable=1`, or clearing it, for anything with an enabled switch.
private func flipDisable(_ row: Row) -> [String: String] {
    row.json.bool("disable") ? ["delete": "disable"] : ["disable": "1"]
}

/// Notification targets (sendmail, SMTP, Gotify) and the matchers that route events to them.
struct NotificationsSection: View {
    @Environment(Session.self) private var session
    @State private var target: TargetEdit?
    @State private var matcher: SimpleEdit?

    var body: some View {
        VStack(spacing: 0) {
            ActionBar(hint: "Targets deliver notifications; matchers decide which events go where.") {
                Menu("Add Target", systemImage: "plus") {
                    ForEach(TargetEdit.kinds, id: \.key) { kind in
                        Button("\(kind.title)…") { target = TargetEdit(kind: kind.key) }
                    }
                }
                .fixedSize()
                Button("Add Matcher", systemImage: "line.3.horizontal.decrease") { matcher = SimpleEdit(row: nil) }
            }
            SectionTitle(text: "Targets")
            ResourceList(path: "/cluster/notifications/targets", id: { $0.string("name") ?? "" },
                         columns: [APIColumn("Name", key: "name", width: 160),
                                   APIColumn("Type", width: 100) { row in TargetEdit.kinds.first { $0.key == row.string("type") }?.title ?? row.string("type") ?? "" },
                                   APIColumn("Enabled", width: 70) { $0.bool("disable") ? "No" : "Yes" },
                                   APIColumn("Origin", width: 120) { ["builtin": "Built-in", "user-created": "Custom", "modified-builtin": "Modified built-in"][$0.string("origin") ?? ""] ?? $0.string("origin") ?? "" }, APIColumn("Comment", key: "comment", width: 260)],
                         emptyTitle: "No notification targets", emptySymbol: "bell", open: edit) { row in
                if TargetEdit.kinds.contains(where: { $0.key == row["type"] }) { Button("Edit…") { edit(row) } }
                Button("Send Test Notification") { Task { await session.run("Send a test to \(row.id)", .post, "/cluster/notifications/targets/\(row.id.enc)/test") } }
                Button(row.json.bool("disable") ? "Enable" : "Disable") {
                    Task { await session.run("\(row.json.bool("disable") ? "Enable" : "Disable") \(row.id)", .put, Self.path(row), flipDisable(row)) }
                }
                if row["origin"] != "builtin" {
                    Divider()
                    Button("Delete…", role: .destructive) { session.confirmDelete("Delete target \(row.id)?", path: Self.path(row)) }
                }
            }
            SectionTitle(text: "Matchers")
            ResourceList(path: "/cluster/notifications/matchers", id: { $0.string("name") ?? "" },
                         columns: [APIColumn("Name", key: "name", width: 160), APIColumn("Targets", width: 200) { $0.strings("target").joined(separator: ", ") },
                                   APIColumn("Severities", width: 160) { $0.strings("match-severity").joined(separator: ", ") },
                                   APIColumn("Enabled", width: 70) { $0.bool("disable") ? "No" : "Yes" }, APIColumn("Comment", key: "comment", width: 220)],
                         emptyTitle: "No matchers", emptySymbol: "line.3.horizontal.decrease", open: { matcher = SimpleEdit(row: $0) }) { row in
                Button("Edit…") { matcher = SimpleEdit(row: row) }
                Button(row.json.bool("disable") ? "Enable" : "Disable") {
                    Task { await session.run("\(row.json.bool("disable") ? "Enable" : "Disable") \(row.id)", .put, "/cluster/notifications/matchers/\(row.id.enc)", flipDisable(row)) }
                }
                if row["origin"] != "builtin" {
                    Divider()
                    Button("Delete…", role: .destructive) { session.confirmDelete("Delete matcher \(row.id)?", path: "/cluster/notifications/matchers/\(row.id.enc)") }
                }
            }
        }
        .debugAction("add-smtp") { target = TargetEdit(kind: "smtp") }
        .debugAction("add-webhook") { target = TargetEdit(kind: "webhook") }
        .debugAction("add-matcher") { matcher = SimpleEdit(row: nil) }
        .debugAction("edit-matcher") { matcher = SimpleEdit(row: Row(id: "default-matcher", json: [:])) }
        .sheet(item: $target) { TargetEditor(edit: $0) }
        .sheet(item: $matcher) { MatcherEditor(name: $0.row?.id) }
    }

    private func edit(_ row: Row) {
        if let kind = row["type"], TargetEdit.kinds.contains(where: { $0.key == kind }) { target = TargetEdit(kind: kind, name: row.id) }
    }

    private static func path(_ row: Row) -> String { "/cluster/notifications/endpoints/\((row["type"] ?? "").enc)/\(row.id.enc)" }
}

struct TargetEdit: Identifiable {
    static let kinds = [(key: "sendmail", title: "Sendmail"), (key: "smtp", title: "SMTP"), (key: "gotify", title: "Gotify"), (key: "webhook", title: "Webhook")]
    let kind: String
    var name: String?
    var id: String { "\(kind)/\(name ?? "")" }
}

/// Adds or edits a sendmail, SMTP, Gotify or webhook target. A saved password, token or secret stays unless a new one is typed.
struct TargetEditor: View {
    @Environment(Session.self) private var session
    let edit: TargetEdit

    private var path: String { "/cluster/notifications/endpoints/\(edit.kind)" + (edit.name.map { "/\($0.enc)" } ?? "") }

    var body: some View {
        Prepared(load: { edit.name == nil ? [:] : ((try? await session.client.object(path)) ?? [:]) }) { config in
            FormSheet(title: edit.name.map { "Edit \($0)" } ?? "Add \(TargetEdit.kinds.first { $0.key == edit.kind }?.title ?? edit.kind) target",
                      message: Self.messages[edit.kind],
                      fields: fields, initial: initial(config), isEdit: edit.name != nil, submitTitle: edit.name == nil ? "Add" : "Save") { result in
                var params = edit.name == nil ? result.changed : result.params
                for key in ["mailto", "mailto-user"] {
                    params[key] = params[key].map { $0.split(whereSeparator: { ", ;".contains($0) }).joined(separator: "\0") }
                }
                // Webhook headers and secrets are "name: value" lines; Proxmox wants name=…,value=<base64> items and a base64 body.
                for key in ["header", "secret"] { params[key] = params[key].map(Self.encodePairs) }
                params["body"] = params["body"].map { Data($0.utf8).base64EncodedString() }
                if let name = edit.name { return await session.run("Save \(name)", .put, path, params) }
                return await session.run("Add target \(result["name"])", .post, path, params)
            }
        }
    }

    private static let messages = ["sendmail": "Separate several recipients with commas.", "smtp": "Separate several recipients with commas.",
                                   "webhook": "Use {{ title }}, {{ message }}, {{ severity }} and {{ secrets.name }} in the URL, headers and body."]

    private func initial(_ config: JSONObject) -> [String: String] {
        guard let name = edit.name else {
            return ["mailto-user": "root@pam", "method": "post"].merging(edit.kind == "smtp" ? ["mode": "starttls", "port": "587"] : [:]) { $1 }
        }
        var values = ["name": name]
        for field in fields where field.key != "name" {
            switch field.key {
            case "mailto", "mailto-user": values[field.key] = config.strings(field.key).joined(separator: ", ")
            case "header", "secret": values[field.key] = Self.decodePairs(config.strings(field.key))
            case "body": values[field.key] = Data(base64Encoded: config.string("body") ?? "").flatMap { String(data: $0, encoding: .utf8) } ?? ""
            default: values[field.key] = config.string(field.key) ?? ""
            }
        }
        return values
    }

    /// "Name: value" lines to Proxmox's `name=Name,value=<base64>` items, NUL-separated. A line without a value keeps the saved secret.
    static func encodePairs(_ text: String) -> String {
        text.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { return nil }
            let value = parts.count > 1 ? parts[1] : ""
            return value.isEmpty ? "name=\(name)" : "name=\(name),value=\(Data(value.utf8).base64EncodedString())"
        }
        .joined(separator: "\0")
    }

    static func decodePairs(_ items: [String]) -> String {
        items.map { item in
            let pair = PropertyString(item)
            let value = Data(base64Encoded: pair["value"] ?? "").flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return "\(pair["name"] ?? ""): \(value)"
        }
        .joined(separator: "\n")
    }

    private var fields: [FormField] {
        let secretHelp = edit.name == nil ? nil : "Leave empty to keep the saved one"
        var fields = [FormField(key: "name", label: "Name", prompt: ["gotify": "gotify", "webhook": "ntfy"][edit.kind] ?? "admin-mail", required: true, lockedOnEdit: true)]
        switch edit.kind {
        case "smtp":
            fields += [FormField(key: "server", label: "Server", prompt: "smtp.example.com", required: true),
                       FormField(key: "port", label: "Port", kind: .number),
                       FormField(key: "mode", label: "Encryption", kind: .choice([.init("starttls", "STARTTLS"), .init("tls", "TLS"), .init("insecure", "None")])),
                       FormField(key: "username", label: "Username"),
                       FormField(key: "password", label: "Password", kind: .secure, prompt: secretHelp ?? ""),
                       FormField(key: "from-address", label: "From", prompt: "pve@example.com", required: true),
                       FormField(key: "mailto", label: "To (addresses)", prompt: "admin@example.com"),
                       FormField(key: "mailto-user", label: "To (users)", prompt: "root@pam")]
        case "gotify":
            fields += [FormField(key: "server", label: "Server URL", prompt: "https://gotify.example.com", required: true),
                       FormField(key: "token", label: "App token", kind: .secure, prompt: secretHelp ?? "", required: edit.name == nil)]
        case "webhook":
            fields += [FormField(key: "method", label: "Method", kind: .choice([.init("post", "POST"), .init("put", "PUT"), .init("get", "GET")]), required: true),
                       FormField(key: "url", label: "URL", prompt: "https://ntfy.sh/proxmox", required: true),
                       FormField(key: "header", label: "Headers, one \"Name: value\" per line", kind: .multiline),
                       FormField(key: "body", label: "Body", kind: .multiline),
                       FormField(key: "secret", label: "Secrets, one \"name: value\" per line", kind: .multiline,
                                 help: "Saved secrets show only their names. Leave a value empty to keep it.")]
        default:
            fields += [FormField(key: "mailto", label: "To (addresses)", prompt: "admin@example.com"),
                       FormField(key: "mailto-user", label: "To (users)", prompt: "root@pam"),
                       FormField(key: "from-address", label: "From", prompt: "Default")]
        }
        fields.append(FormField(key: "comment", label: "Comment"))
        return fields
    }
}

/// Adds or edits a matcher: which events, by severity or field, go to which targets.
private struct MatcherEditor: View {
    @Environment(Session.self) private var session
    let name: String?

    private static let severities = [("error", "Errors"), ("warning", "Warnings"), ("notice", "Notices"), ("info", "Info"), ("unknown", "Unknown")]
        .map { FormField.Choice($0.0, $0.1) }

    var body: some View {
        Prepared(load: {
            let targets = ((try? await session.client.list("/cluster/notifications/targets")) ?? []).compactMap { $0.text("name") }
            var config: JSONObject = [:]
            if let name { config = (try? await session.client.object("/cluster/notifications/matchers/\(name.enc)")) ?? [:] }
            return (targets, config)
        }) { loaded in
            let (targets, config) = loaded
            FormSheet(title: name.map { "Edit \($0)" } ?? "Add matcher", message: "Send matching events to the chosen targets. Leave the filters empty to match everything.", fields: [
                FormField(key: "name", label: "Name", prompt: "backup-failures", required: true, lockedOnEdit: true),
                FormField(key: "target", label: "Targets", kind: .multiChoice(targets.map { FormField.Choice($0) }), required: true),
                FormField(key: "match-severity", label: "Severities", kind: .multiChoice(Self.severities)),
                FormField(key: "match-field", label: "Field filters", prompt: "exact:type=vzdump; regex:hostname=^pve"),
                FormField(key: "mode", label: "Match", kind: .choice([.init("any", "Any filter")]), prompt: "All filters"),
                FormField(key: "comment", label: "Comment"),
            ], initial: name == nil ? ["target": targets.first ?? "", "match-severity": "error"] : [
                "name": name ?? "", "target": config.strings("target").joined(separator: ","),
                "match-severity": config.strings("match-severity").joined(separator: ","),
                "match-field": config.strings("match-field").joined(separator: "; "),
                "mode": config.string("mode") == "any" ? "any" : "", "comment": config.string("comment") ?? "",
            ], isEdit: name != nil, submitTitle: name == nil ? "Add" : "Save") { result in
                var params = name == nil ? result.changed : result.params
                for key in ["target", "match-severity"] { params[key] = params[key]?.replacingOccurrences(of: ",", with: "\0") }
                params["match-field"] = params["match-field"].map { filters in
                    filters.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\0")
                }
                if let name { return await session.run("Save \(name)", .put, "/cluster/notifications/matchers/\(name.enc)", params) }
                return await session.run("Add matcher \(result["name"])", .post, "/cluster/notifications/matchers", params)
            }
        }
    }
}

// MARK: HA rules (PVE 9) and groups (PVE 8)

struct HARulesSection: View {
    @Environment(Session.self) private var session
    @State private var useGroups = false
    @State private var editing: SimpleEdit?

    var body: some View {
        VStack(spacing: 0) {
            ActionBar(hint: useGroups ? "Groups limit which nodes a guest may run on." : "Rules pin guests to nodes, or keep guests together or apart.") {
                Button(useGroups ? "Add Group" : "Add Rule", systemImage: "plus") { editing = SimpleEdit(row: nil) }
            }
            if useGroups {
                ResourceList(path: "/cluster/ha/groups", id: { $0.string("group") ?? "" },
                             columns: [APIColumn("Group", key: "group", width: 140), APIColumn("Nodes", key: "nodes", width: 260),
                                       APIColumn("Restricted", width: 80) { $0.bool("restricted") ? "Yes" : "No" },
                                       APIColumn("No failback", width: 90) { $0.bool("nofailback") ? "Yes" : "No" }, APIColumn("Comment", key: "comment", width: 200)],
                             emptyTitle: "No HA groups", emptySymbol: "list.bullet.indent", open: { editing = SimpleEdit(row: $0) }) { row in
                    Button("Edit…") { editing = SimpleEdit(row: row) }
                    Divider()
                    Button("Delete…", role: .destructive) { session.confirmDelete("Delete HA group \(row.id)?", path: "/cluster/ha/groups/\(row.id.enc)") }
                }
            } else {
                ResourceList(path: "/cluster/ha/rules", id: { $0.string("rule") ?? "" },
                             columns: [APIColumn("Rule", key: "rule", width: 140),
                                       APIColumn("Type", width: 130) { ["node-affinity": "Node affinity", "resource-affinity": "Resource affinity"][$0.string("type") ?? ""] ?? $0.string("type") ?? "" },
                                       APIColumn("Resources", key: "resources", width: 200), APIColumn("Nodes / affinity", width: 200) { $0.string("nodes") ?? $0.string("affinity") ?? "" },
                                       APIColumn("Strict", width: 60) { $0.bool("strict") ? "Yes" : "" },
                                       APIColumn("Enabled", width: 70) { $0.bool("disable") ? "No" : "Yes" }, APIColumn("Comment", key: "comment", width: 200)],
                             emptyTitle: "No HA rules", emptySymbol: "list.bullet.indent",
                             emptyMessage: "Rules pin guests to preferred nodes or keep them together or apart.", open: { editing = SimpleEdit(row: $0) }) { row in
                    Button("Edit…") { editing = SimpleEdit(row: row) }
                    Button(row.json.bool("disable") ? "Enable" : "Disable") {
                        // Proxmox needs the rule type on every update.
                        let params = flipDisable(row).merging(["type": row["type"] ?? ""]) { $1 }
                        Task { await session.run("\(row.json.bool("disable") ? "Enable" : "Disable") \(row.id)", .put, "/cluster/ha/rules/\(row.id.enc)", params) }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { session.confirmDelete("Delete HA rule \(row.id)?", path: "/cluster/ha/rules/\(row.id.enc)") }
                }
            }
        }
        .task {
            do { _ = try await session.client.get("/cluster/ha/rules") } catch { useGroups = true }
        }
        .debugAction("add-ha-rule") { editing = SimpleEdit(row: nil) }
        .sheet(item: $editing) { edit in
            if useGroups { HAGroupEditor(row: edit.row) } else { HARuleEditor(row: edit.row) }
        }
    }
}

private struct HARuleEditor: View {
    @Environment(Session.self) private var session
    let row: Row?

    var body: some View {
        let guests = session.guests.filter { !$0.isTemplate }.map { FormField.Choice("\($0.kind == .qemu ? "vm" : "ct"):\($0.vmid)", "\($0.vmid) \($0.displayName)") }
        FormSheet(title: row.map { "Edit \($0.id)" } ?? "Add HA rule",
                  message: "Node affinity: run guests on these nodes (pve1:2 prefers pve1). Resource affinity: keep guests together (positive) or apart (negative).", fields: [
            FormField(key: "rule", label: "Name", prompt: "db-on-pve1", required: true, lockedOnEdit: true),
            FormField(key: "type", label: "Type", kind: .choice([.init("node-affinity", "Node affinity"), .init("resource-affinity", "Resource affinity")]), required: true, lockedOnEdit: true),
            FormField(key: "resources", label: "Guests", kind: .multiChoice(guests), required: true),
            FormField(key: "nodes", label: "Nodes (node affinity)", prompt: session.nodes.map { "\($0.node):1" }.joined(separator: ",")),
            FormField(key: "affinity", label: "Affinity (resource affinity)", kind: .choice([.init("positive", "Keep together"), .init("negative", "Keep apart")])),
            FormField(key: "strict", label: "Strict", kind: .toggle),
            FormField(key: "comment", label: "Comment"),
        ], initial: row.map { row in
            ["rule": row.id, "type": row["type"] ?? "", "resources": row["resources"] ?? "", "nodes": row["nodes"] ?? "",
             "affinity": row["affinity"] ?? "", "strict": row.json.bool("strict") ? "1" : "0", "comment": row["comment"] ?? ""]
        } ?? ["type": "node-affinity"], isEdit: row != nil, submitTitle: row == nil ? "Add" : "Save") { result in
            var params = row == nil ? result.changed : result.params
            if row == nil, params["strict"] == "0" { params["strict"] = nil }
            if result["type"] == "node-affinity" { params["affinity"] = nil } else { params["nodes"] = nil }
            guard let row else { return await session.run("Add HA rule \(result["rule"])", .post, "/cluster/ha/rules", params) }
            params["type"] = result["type"]
            return await session.run("Save \(row.id)", .put, "/cluster/ha/rules/\(row.id.enc)", params)
        }
    }
}

private struct HAGroupEditor: View {
    @Environment(Session.self) private var session
    let row: Row?

    var body: some View {
        FormSheet(title: row.map { "Edit \($0.id)" } ?? "Add HA group", fields: [
            FormField(key: "group", label: "Name", prompt: "prefer-pve1", required: true, lockedOnEdit: true),
            FormField(key: "nodes", label: "Nodes", prompt: session.nodes.map { "\($0.node):1" }.joined(separator: ","), help: "Higher numbers are preferred", required: true),
            FormField(key: "restricted", label: "Only run on these nodes", kind: .toggle),
            FormField(key: "nofailback", label: "Don't move back after recovery", kind: .toggle),
            FormField(key: "comment", label: "Comment"),
        ], initial: row.map { row in
            ["group": row.id, "nodes": row["nodes"] ?? "", "restricted": row.json.bool("restricted") ? "1" : "0",
             "nofailback": row.json.bool("nofailback") ? "1" : "0", "comment": row["comment"] ?? ""]
        } ?? [:], isEdit: row != nil, submitTitle: row == nil ? "Add" : "Save") { result in
            var params = row == nil ? result.changed : result.params
            if row == nil { for key in ["restricted", "nofailback"] where params[key] == "0" { params[key] = nil } }
            guard let row else { return await session.run("Add HA group \(result["group"])", .post, "/cluster/ha/groups", params) }
            return await session.run("Save \(row.id)", .put, "/cluster/ha/groups/\(row.id.enc)", params)
        }
    }
}

// MARK: Resource mappings

struct MappingsSection: View {
    @Environment(Session.self) private var session
    @State private var editing: MappingEdit?

    var body: some View {
        VStack(spacing: 0) {
            ActionBar(hint: "Mappings name host devices and folders so guests can use them on any node.") {
                Button("Add PCI Mapping", systemImage: "plus") { editing = MappingEdit(kind: "pci") }
                Button("Add USB Mapping", systemImage: "plus") { editing = MappingEdit(kind: "usb") }
                Button("Add Directory Mapping", systemImage: "plus") { editing = MappingEdit(kind: "dir") }
            }
            ForEach(["pci", "usb", "dir"], id: \.self) { kind in
                SectionTitle(text: ["pci": "PCI devices", "usb": "USB devices", "dir": "Directories (virtiofs)"][kind] ?? kind)
                ResourceList(path: "/cluster/mapping/\(kind)", id: { $0.string("id") ?? "" },
                             columns: [APIColumn("ID", key: "id", width: 140), APIColumn("Description", key: "description", width: 240),
                                       // "node=pve1,path=0000:01:00,id=10de:2531" reads as "pve1: 0000:01:00".
                                       APIColumn(kind == "dir" ? "Folders" : "Devices", width: 360) { row in
                                           row.strings("map").map { entry in
                                               let map = PropertyString(entry)
                                               return "\(map["node"] ?? "?"): \(map["path"] ?? map["id"] ?? entry)"
                                           }.joined(separator: ", ")
                                       }],
                             emptyTitle: kind == "dir" ? "No directory mappings" : "No \(kind.uppercased()) mappings",
                             emptySymbol: ["pci": "rectangle.connected.to.line.below", "usb": "cable.connector"][kind] ?? "folder",
                             open: { editing = MappingEdit(kind: kind, row: $0) }) { row in
                    Button("Edit…") { editing = MappingEdit(kind: kind, row: row) }
                    Divider()
                    Button("Delete…", role: .destructive) { session.confirmDelete("Delete mapping \(row.id)?", path: "/cluster/mapping/\(kind)/\(row.id.enc)") }
                }
            }
        }
        .debugAction("add-pci-mapping") { editing = MappingEdit(kind: "pci") }
        .debugAction("edit-pci-mapping") {
            Task { if let first = try? await session.client.list("/cluster/mapping/pci").first { editing = MappingEdit(kind: "pci", row: Row(id: first.string("id") ?? "", json: first)) } }
        }
        .sheet(item: $editing) { MappingEditor(edit: $0) }
    }
}

private struct MappingEdit: Identifiable {
    let kind: String
    var row: Row?
    var id: String { "\(kind)/\(row?.id ?? "")" }
}

/// Names a host device (or, for virtiofs, a folder) on each node, so guests using the mapping can run on any of them.
private struct MappingEditor: View {
    @Environment(Session.self) private var session
    let edit: MappingEdit

    var body: some View {
        let existing = edit.row?.json.strings("map") ?? []
        Prepared(load: {
            var devices: [(node: String, choices: [FormField.Choice])] = []
            for node in session.onlineNodes {
                let list = edit.kind == "dir" ? [] : (try? await session.client.list("/nodes/\(node.enc)/hardware/\(edit.kind)")) ?? []
                var choices = list.map { Self.choice($0, node: node, kind: edit.kind) }
                if edit.kind != "dir", let saved = existing.first(where: { Self.node(of: $0) == node }) {
                    // Match the saved entry by device so its extra settings (IOMMU group, subsystem) survive a save.
                    let key = edit.kind == "pci" ? "path" : "id"
                    if let index = choices.firstIndex(where: { PropertyString($0.value)[key] == PropertyString(saved)[key] }) {
                        choices[index] = .init(saved, choices[index].label)
                    } else {
                        choices.append(.init(saved, "\(PropertyString(saved)[key] ?? saved) (saved, not found on \(node) now)"))
                    }
                }
                devices.append((node, choices))
            }
            return devices
        }) { devices in
            // Entries for nodes that are offline right now stay as they are.
            let kept = existing.filter { entry in !devices.contains { $0.node == Self.node(of: entry) } }
            let folders = edit.kind == "dir"
            FormSheet(title: edit.row.map { "Edit \($0.id)" } ?? (folders ? "Add directory mapping" : "Add \(edit.kind.uppercased()) mapping"),
                      message: folders ? "The folder on each node that guests using this mapping share through virtiofs." : "Pick the device on each node that guests using this mapping may get.",
                      fields: [FormField(key: "id", label: "Name", prompt: ["pci": "gpu0", "usb": "zigbee-stick"][edit.kind] ?? "media", required: true, lockedOnEdit: true),
                               FormField(key: "description", label: "Description")]
                          + devices.map { device in
                              folders ? FormField(key: "map:\(device.node)", label: "Folder on \(device.node)", prompt: "/mnt/media")
                                  : FormField(key: "map:\(device.node)", label: "Device on \(device.node)", kind: .choice(device.choices), prompt: "Not mapped")
                          },
                      initial: initial(devices, existing: existing), isEdit: edit.row != nil, submitTitle: edit.row == nil ? "Add" : "Save") { result in
                let entries = devices.compactMap { device -> String? in
                    let value = result["map:\(device.node)"]
                    if value.isEmpty { return nil }
                    return folders ? "node=\(device.node),path=\(value)" : value
                } + kept
                var params = ["map": entries.joined(separator: "\0")]
                if let description = result.changed["description"] { params["description"] = description }
                if result.cleared.contains("description") { params["delete"] = "description" }
                guard let row = edit.row else {
                    params["id"] = result["id"]
                    return await session.run("Add mapping \(result["id"])", .post, "/cluster/mapping/\(edit.kind)", params)
                }
                return await session.run("Save \(row.id)", .put, "/cluster/mapping/\(edit.kind)/\(row.id.enc)", params)
            }
        }
    }

    private func initial(_ devices: [(node: String, choices: [FormField.Choice])], existing: [String]) -> [String: String] {
        var values = ["id": edit.row?.id ?? "", "description": edit.row?["description"] ?? ""]
        for (index, device) in devices.enumerated() {
            let current = existing.first { Self.node(of: $0) == device.node }
            if edit.kind == "dir" {
                values["map:\(device.node)"] = current.flatMap { PropertyString($0)["path"] } ?? ""
                continue
            }
            // A new mapping starts with the first node's first device picked.
            values["map:\(device.node)"] = current ?? (edit.row == nil && index == 0 ? device.choices.first?.value ?? "" : "")
        }
        return values
    }

    private static func node(of entry: String) -> String? { PropertyString(entry)["node"] }

    private static func choice(_ device: JSONObject, node: String, kind: String) -> FormField.Choice {
        if kind == "pci" {
            let path = device.string("id") ?? ""
            let ids = [device.string("vendor"), device.string("device")].map { ($0 ?? "").replacingOccurrences(of: "0x", with: "") }.joined(separator: ":")
            return .init("node=\(node),path=\(path),id=\(ids)", "\(path)  \(device.text("device_name") ?? device.text("vendor_name") ?? ids)")
        }
        let ids = [device.string("vendid"), device.string("prodid")].map { ($0 ?? "").replacingOccurrences(of: "0x", with: "") }.joined(separator: ":")
        return .init("node=\(node),id=\(ids)", "\(device.text("product") ?? device.text("manufacturer") ?? ids) (\(ids))")
    }
}

// MARK: ACME

struct ACMESection: View {
    @Environment(Session.self) private var session
    @State private var registering = false
    @State private var addingPlugin = false

    var body: some View {
        VStack(spacing: 0) {
            ActionBar(hint: "Then set a domain on a node under System → Certificates.") {
                Button("Register Account", systemImage: "person.badge.plus") { registering = true }
                Button("Add DNS Plugin", systemImage: "puzzlepiece") { addingPlugin = true }
            }
            SectionTitle(text: "Accounts")
            ResourceList(path: "/cluster/acme/account", id: { $0.string("name") ?? "" }, columns: [APIColumn("Account", key: "name", width: 220)],
                         emptyTitle: "No ACME accounts", emptySymbol: "checkmark.seal",
                         emptyMessage: "Register with Let's Encrypt to get trusted certificates for your nodes.") { row in
                Button("Deactivate…", role: .destructive) { session.confirmDelete("Deactivate ACME account \(row.id)?", path: "/cluster/acme/account/\(row.id.enc)") }
            }
            SectionTitle(text: "Challenge plugins")
            ResourceList(path: "/cluster/acme/plugins", id: { $0.string("plugin") ?? "" },
                         columns: [APIColumn("Plugin", key: "plugin", width: 160), APIColumn("Type", width: 100) { $0.string("type") == "dns" ? "DNS" : "HTTP" }, APIColumn("DNS API", key: "api", width: 160)],
                         emptyTitle: "No plugins", emptySymbol: "puzzlepiece", emptyMessage: "DNS plugins let you get certificates without opening port 80.") { row in
                Button("Delete…", role: .destructive) { session.confirmDelete("Delete plugin \(row.id)?", path: "/cluster/acme/plugins/\(row.id.enc)") }
            }
        }
        .debugAction("add-acme-plugin") { addingPlugin = true }
        .sheet(isPresented: $registering) { ACMERegisterSheet() }
        .debugAction("register-acme") { registering = true }
        .sheet(isPresented: $addingPlugin) {
            Prepared(load: { ((try? await session.client.list("/cluster/acme/challenge-schema")) ?? []).compactMap { item in item.text("id").map { FormField.Choice($0, item.text("name") ?? $0) } } }) { apis in
                FormSheet(title: "Add DNS plugin", message: "Credentials as KEY=value lines, for example CF_Token=… for Cloudflare.", fields: [
                    FormField(key: "id", label: "Name", prompt: "cloudflare", required: true),
                    FormField(key: "api", label: "DNS provider", kind: .choice(apis.isEmpty ? [.init("cf", "Cloudflare")] : apis), required: true),
                    FormField(key: "data", label: "Credentials", kind: .multiline, required: true),
                ], initial: ["api": apis.first?.value ?? "cf"], submitTitle: "Add") { result in
                    // Proxmox expects the credentials base64-encoded.
                    await session.run("Add plugin \(result["id"])", .post, "/cluster/acme/plugins",
                                      ["id": result["id"], "type": "dns", "api": result["api"], "data": Data(result["data"].utf8).base64EncodedString()])
                }
            }
        }
    }
}

/// Registers an ACME account: pick a CA from the server's list (or any directory URL), accept its terms, and give
/// External Account Binding keys when the CA needs them (ZeroSSL, Google).
struct ACMERegisterSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var directories: [FormField.Choice] = []
    @State private var name = "default"
    @State private var contact = ""
    @State private var directory = "https://acme-v02.api.letsencrypt.org/directory"
    @State private var meta: JSONObject?
    @State private var metaError: String?
    @State private var eabKid = ""
    @State private var eabKey = ""
    @State private var accepted = false
    @State private var busy = false

    private var terms: String? { meta?.text("termsOfService") }
    private var needsEAB: Bool { meta?.bool("externalAccountRequired") ?? false }
    private var ready: Bool {
        !contact.trimmingCharacters(in: .whitespaces).isEmpty && meta != nil && (terms == nil || accepted)
            && (!needsEAB || !eabKid.isEmpty && !eabKey.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Register ACME account").font(.title2.bold())
                Text("Certificate authorities like Let's Encrypt issue trusted certificates to accounts registered here.").foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 8)
            Form {
                TextField("Name", text: $name, prompt: Text("default"))
                TextField("Email", text: $contact, prompt: Text("admin@example.com"))
                LabeledContent("Certificate authority") {
                    HStack(spacing: 6) {
                        TextField("", text: $directory, prompt: Text("https://…/directory"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .truncationMode(.head)
                        Menu {
                            ForEach(directories, id: \.self) { choice in Button(choice.label) { directory = choice.value } }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Choose a certificate authority")
                    }
                }
                if let metaError {
                    Text(metaError).font(.callout).foregroundStyle(.red)
                }
                if needsEAB {
                    Section {
                        TextField("Key ID", text: $eabKid)
                        SecureField("HMAC key", text: $eabKey)
                    } header: {
                        Text("External Account Binding")
                    } footer: {
                        Text("This CA links new accounts to one you have on its website; copy both keys from there.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let terms, let url = URL(string: terms) {
                    Toggle(isOn: $accepted) {
                        Text("I accept the terms of service")
                        Link(url.lastPathComponent.isEmpty ? terms : url.lastPathComponent, destination: url).font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Register") { Task { await register() } }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !ready)
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 540, height: needsEAB ? 520 : 420)
        .task {
            directories = ((try? await session.client.list("/cluster/acme/directories")) ?? [])
                .compactMap { item in item.text("url").map { FormField.Choice($0, item.text("name") ?? $0) } }
        }
        .task(id: directory) {
            // Each CA has its own terms and may need account binding; ask the server about the one picked.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            meta = nil
            accepted = false
            do {
                meta = try await session.client.object("/cluster/acme/meta", ["directory": directory.trimmingCharacters(in: .whitespaces)])
                metaError = nil
            } catch {
                metaError = "Couldn't reach this directory: \(error.localizedDescription)"
            }
        }
    }

    private func register() async {
        busy = true
        defer { busy = false }
        var params = ["name": name.isEmpty ? "default" : name, "contact": contact.trimmingCharacters(in: .whitespaces),
                      "directory": directory.trimmingCharacters(in: .whitespaces)]
        if let terms { params["tos_url"] = terms }
        if needsEAB {
            params["eab-kid"] = eabKid
            params["eab-hmac-key"] = eabKey
        }
        if await session.run("Register ACME account \(params["name"] ?? "")", .post, "/cluster/acme/account", params) { dismiss() }
    }
}

/// Lets a node request a certificate for a domain through an ACME account.
struct ACMEDomainSheet: View {
    @Environment(Session.self) private var session
    let node: String

    var body: some View {
        Prepared(load: {
            let accounts = ((try? await session.client.list("/cluster/acme/account")) ?? []).compactMap { $0.text("name") }
            let plugins = ((try? await session.client.list("/cluster/acme/plugins")) ?? []).compactMap { $0.text("plugin") }
            let config = (try? await session.client.object("/nodes/\(node.enc)/config")) ?? [:]
            return (accounts, plugins, config)
        }) { loaded in
            let (accounts, plugins, config) = loaded
            let current = PropertyString(config.string("acmedomain0") ?? "", defaultKey: "domain")
            FormSheet(title: "ACME domain for \(node)", message: accounts.isEmpty ? "Register an ACME account first under Datacenter → Options → ACME." : "Without a plugin, the CA reaches the node on port 80 to verify the domain.", fields: [
                FormField(key: "account", label: "Account", kind: .choice(accounts.map { FormField.Choice($0) }), required: true),
                FormField(key: "domain", label: "Domain", prompt: "\(node).example.com", required: true),
                FormField(key: "plugin", label: "DNS plugin", kind: .choice(plugins.map { FormField.Choice($0) })),
            ], initial: ["account": PropertyString(config.string("acme") ?? "", defaultKey: "account")["account"] ?? accounts.first ?? "",
                         "domain": current["domain"] ?? "", "plugin": current["plugin"] ?? ""], submitTitle: "Save") { result in
                var domain = "domain=\(result["domain"])"
                if !result["plugin"].isEmpty { domain += ",plugin=\(result["plugin"])" }
                return await session.run("Set the ACME domain", .put, "/nodes/\(node.enc)/config", ["acme": "account=\(result["account"])", "acmedomain0": domain])
            }
        }
    }
}

// MARK: Cluster

struct ClusterSection: View {
    @Environment(Session.self) private var session
    @State private var join: JSONObject = [:]
    @State private var creating = false
    @State private var joining = false

    var body: some View {
        VStack(spacing: 0) {
            ActionBar(hint: session.clusterName == nil ? "This node isn't in a cluster yet." : "Cluster \(session.clusterName ?? "")") {
                if session.clusterName == nil {
                    Button("Create Cluster", systemImage: "plus") { creating = true }
                    Button("Join Cluster", systemImage: "link") { joining = true }
                } else {
                    Button("Copy Join Information", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.joinInformation(join) ?? "", forType: .string)
                    }
                    .disabled(join.isEmpty)
                }
            }
            ResourceList(path: "/cluster/status", id: { $0.string("id") ?? "" },
                         columns: [APIColumn("Name", key: "name", width: 160), APIColumn("Type", width: 80) { ($0.string("type") ?? "").capitalized },
                                   APIColumn("Node ID", key: "nodeid", width: 70), APIColumn("Address", key: "ip", width: 140, monospaced: true),
                                   APIColumn("Online", width: 70) { $0.string("type") == "node" ? ($0.bool("online") ? "Yes" : "No") : "" },
                                   APIColumn("Quorate", width: 70) { $0.string("type") == "cluster" ? ($0.bool("quorate") ? "Yes" : "No") : "" }],
                         emptyTitle: "No cluster information", emptySymbol: "server.rack") { _ in EmptyView() }
        }
        .task(id: session.revision) { join = (try? await session.client.object("/cluster/config/join")) ?? [:] }
        .debugAction("join-cluster") { joining = true }
        .sheet(isPresented: $creating) {
            FormSheet(title: "Create cluster", message: "Turns this node into the first member of a new cluster. Other nodes join it afterwards.", fields: [
                FormField(key: "clustername", label: "Cluster name", prompt: "homelab", required: true),
                FormField(key: "link0", label: "Cluster network address", prompt: "Default: the node's address"),
            ], submitTitle: "Create") { result in
                await session.run("Create cluster \(result["clustername"])", .post, "/cluster/config", result.changed)
            }
        }
        .sheet(isPresented: $joining) {
            FormSheet(title: "Join cluster", message: "Paste the Join Information copied on a cluster member, or enter its address and fingerprint. Then enter that member's root password.", fields: [
                FormField(key: "info", label: "Join information", kind: .multiline),
                FormField(key: "hostname", label: "Member address", prompt: "From the join information"),
                FormField(key: "fingerprint", label: "Member fingerprint", prompt: "From the join information"),
                FormField(key: "password", label: "Member root password", kind: .secure, required: true),
                FormField(key: "link0", label: "Cluster network address", prompt: "Default: this node's address"),
            ], submitTitle: "Join") { result in
                var params = result.changed
                if let info = params.removeValue(forKey: "info").flatMap(Self.decodeJoinInformation) {
                    params["hostname"] = params["hostname"] ?? info.string("ipAddress")
                    params["fingerprint"] = params["fingerprint"] ?? info.string("fingerprint")
                }
                return await session.run("Join the cluster", .post, "/cluster/config/join", params)
            }
        }
    }

    /// The same base64 blob the web UI's "Join Information" shows.
    static func joinInformation(_ join: JSONObject) -> String? {
        let preferred = join.string("preferred_node")
        let member = join.objects("nodelist").first { $0.string("name") == preferred } ?? join.objects("nodelist").first ?? [:]
        // Corosync links are ring0_addr, ring1_addr… on each member.
        let links = (0..<8).compactMap { index in member.text("ring\(index)_addr").map { (String(index), $0) } }
        let info: [String: Any] = ["ipAddress": member.string("pve_addr") ?? "", "fingerprint": member.string("pve_fp") ?? "",
                                   "peerLinks": Dictionary(uniqueKeysWithValues: links), "ring_addr": links.map(\.1),
                                   "totem": join.object("totem") ?? [:]]
        return (try? JSONSerialization.data(withJSONObject: info))?.base64EncodedString()
    }

    static func decodeJoinInformation(_ text: String) -> JSONObject? {
        Data(base64Encoded: text.filter { !$0.isWhitespace }).flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSONObject }
    }
}

// MARK: SDN fabrics (PVE 9)

/// Fabrics route between the nodes over dedicated links (OpenFabric or OSPF), for example for Ceph or EVPN.
struct SDNFabrics: View {
    @Environment(Session.self) private var session
    @State private var editingFabric: Row?
    @State private var editingNode: FabricNodeEdit?

    var body: some View {
        VStack(spacing: 0) {
            ResourceList(path: "/cluster/sdn/fabrics/fabric", id: { $0.string("id") ?? "" },
                         columns: [APIColumn("Fabric", key: "id", width: 120),
                                   APIColumn("Protocol", width: 100) { Self.protocols[$0.string("protocol") ?? ""] ?? $0.string("protocol") ?? "" },
                                   APIColumn("IPv4 prefix", key: "ip_prefix", width: 150, monospaced: true),
                                   APIColumn("IPv6 prefix", key: "ip6_prefix", width: 170, monospaced: true),
                                   APIColumn("Area", key: "area", width: 70),
                                   APIColumn("Pending", width: 70) { $0["state"] == nil || $0.string("state") == "" ? "" : "Yes" }],
                         emptyTitle: "No fabrics", emptySymbol: "point.3.connected.trianglepath.dotted",
                         emptyMessage: "A fabric routes between your nodes over dedicated links with OpenFabric or OSPF, for example for Ceph or EVPN.",
                         open: { editingFabric = $0 }) { row in
                Button("Edit…") { editingFabric = row }
                Menu("Add Node") {
                    ForEach(session.nodes.map(\.node), id: \.self) { node in
                        Button(node) { editingNode = FabricNodeEdit(fabric: row.id, protocol: row["protocol"] ?? "openfabric", node: node) }
                    }
                }
                Divider()
                Button("Delete…", role: .destructive) {
                    session.confirmDelete("Delete fabric \(row.id)?", message: "Its nodes leave it too. Apply the SDN changes afterwards.", path: "/cluster/sdn/fabrics/fabric/\(row.id.enc)")
                }
            }
            SectionTitle(text: "Nodes")
            ResourceList(path: "/cluster/sdn/fabrics/node", id: { "\($0.string("fabric_id") ?? "")/\($0.string("node_id") ?? "")" },
                         columns: [APIColumn("Fabric", key: "fabric_id", width: 120), APIColumn("Node", key: "node_id", width: 140),
                                   APIColumn("IPv4", key: "ip", width: 130, monospaced: true), APIColumn("IPv6", key: "ip6", width: 160, monospaced: true),
                                   APIColumn("Links", width: 220) { $0.strings("interfaces").compactMap { PropertyString($0)["name"] }.joined(separator: ", ") }],
                         emptyTitle: "No nodes in a fabric yet", emptySymbol: "server.rack",
                         emptyMessage: "Right-click a fabric to add nodes to it.", open: { editingNode = FabricNodeEdit(row: $0) }) { row in
                Button("Edit…") { editingNode = FabricNodeEdit(row: row) }
                Divider()
                Button("Remove…", role: .destructive) {
                    session.confirmDelete("Remove \(row["node_id"] ?? "") from \(row["fabric_id"] ?? "")?",
                                          path: "/cluster/sdn/fabrics/node/\((row["fabric_id"] ?? "").enc)/\((row["node_id"] ?? "").enc)")
                }
            }
        }
        .sheet(item: $editingFabric) { FabricEditor(row: $0) }
        .sheet(item: $editingNode) { FabricNodeEditor(edit: $0) }
        .debugAction("add-fabric-node") { editingNode = FabricNodeEdit(fabric: "ceph", protocol: "openfabric", node: session.nodes.first?.node ?? "") }
    }

    static let protocols = ["openfabric": "OpenFabric", "ospf": "OSPF"]
}

struct FabricEditor: View {
    @Environment(Session.self) private var session
    let row: Row?

    var body: some View {
        FormSheet(title: row.map { "Edit \($0.id)" } ?? "Add fabric",
                  message: "Nodes take their router address from the IPv4 prefix. OpenFabric needs no addresses on the links; OSPF uses an area.", fields: [
            FormField(key: "id", label: "Name", prompt: "ceph", help: "Up to 8 letters and digits", required: true, lockedOnEdit: true),
            FormField(key: "protocol", label: "Protocol", kind: .choice(SDNFabrics.protocols.sorted { $0.key < $1.key }.map { FormField.Choice($0.key, $0.value) }),
                      required: true, lockedOnEdit: true),
            FormField(key: "ip_prefix", label: "IPv4 prefix", prompt: "10.10.10.0/24"),
            FormField(key: "ip6_prefix", label: "IPv6 prefix", prompt: "fd00:10::/64"),
            FormField(key: "area", label: "Area (OSPF)", prompt: "0"),
            FormField(key: "hello_interval", label: "Hello interval (OpenFabric)", kind: .number, prompt: "3 seconds"),
            FormField(key: "csnp_interval", label: "CSNP interval (OpenFabric)", kind: .number, prompt: "10 seconds"),
        ], initial: row.map { row in
            ["id": row.id, "protocol": row["protocol"] ?? "", "ip_prefix": row["ip_prefix"] ?? "", "ip6_prefix": row["ip6_prefix"] ?? "",
             "area": row["area"] ?? "", "hello_interval": row["hello_interval"] ?? "", "csnp_interval": row["csnp_interval"] ?? ""]
        } ?? ["protocol": "openfabric"], isEdit: row != nil, submitTitle: row == nil ? "Add" : "Save") { result in
            var params = row == nil ? result.changed : result.params
            // Only the chosen protocol's own settings apply.
            for key in result["protocol"] == "ospf" ? ["hello_interval", "csnp_interval"] : ["area"] { params[key] = nil }
            params["protocol"] = result["protocol"]
            guard let row else { return await session.run("Add fabric \(result["id"])", .post, "/cluster/sdn/fabrics/fabric", params) }
            return await session.run("Save \(row.id)", .put, "/cluster/sdn/fabrics/fabric/\(row.id.enc)", params)
        }
    }
}

struct FabricNodeEdit: Identifiable {
    let fabric: String
    let `protocol`: String
    let node: String
    var row: Row?
    var id: String { "\(fabric)/\(node)" }

    init(fabric: String, protocol: String, node: String) {
        self.fabric = fabric
        self.protocol = `protocol`
        self.node = node
    }

    init(row: Row) {
        self.init(fabric: row["fabric_id"] ?? "", protocol: row["protocol"] ?? "openfabric", node: row["node_id"] ?? "")
        self.row = row
    }
}

/// A node's part in a fabric: its router address and the links that join it to the others.
struct FabricNodeEditor: View {
    @Environment(Session.self) private var session
    let edit: FabricNodeEdit

    var body: some View {
        let saved = edit.row?.json.strings("interfaces") ?? []
        let ospf = edit.protocol == "ospf"
        Prepared(load: {
            ((try? await session.client.list("/nodes/\(edit.node.enc)/network")) ?? [])
                .filter { ["eth", "bond", "vlan"].contains($0.string("type") ?? "") }
                .compactMap { $0.text("iface") }
                .sorted(using: KeyPathComparator(\.self, comparator: .localizedStandard))
        }) { interfaces in
            FormSheet(title: edit.row == nil ? "Add \(edit.node) to \(edit.fabric)" : "\(edit.node) in \(edit.fabric)",
                      message: "Pick the network ports that connect \(edit.node) to the other fabric members.", fields: [
                FormField(key: "ip", label: "Router address (IPv4)", prompt: "10.10.10.1", help: "An address inside the fabric's IPv4 prefix"),
                FormField(key: "ip6", label: "Router address (IPv6)", prompt: "fd00:10::1"),
                FormField(key: "interfaces", label: "Links", kind: interfaces.isEmpty ? .text : .multiChoice(interfaces.map { FormField.Choice($0) }),
                          prompt: "ens19,ens20", required: true),
            ] + (ospf ? [FormField(key: "network_type", label: "Link type", kind: .choice([.init("point-to-point", "Point-to-point"), .init("broadcast", "Broadcast")]))] : []),
                      initial: ["ip": edit.row?["ip"] ?? "", "ip6": edit.row?["ip6"] ?? "",
                                "interfaces": saved.compactMap { PropertyString($0)["name"] }.joined(separator: ","),
                                "network_type": saved.first.flatMap { PropertyString($0)["network_type"] } ?? (ospf ? "point-to-point" : "")],
                      isEdit: edit.row != nil, submitTitle: edit.row == nil ? "Add" : "Save") { result in
                var params = edit.row == nil ? result.changed : result.params
                params["network_type"] = nil
                if result.changed["interfaces"] != nil || result.changed["network_type"] != nil {
                    // Links keep any settings saved with them (such as their own addresses); new ones get the link type.
                    let previous = Dictionary(saved.map { (PropertyString($0)["name"] ?? "", $0) }, uniquingKeysWith: { first, _ in first })
                    params["interfaces"] = result["interfaces"].split(separator: ",").map { name in
                        var entry = PropertyString(previous[String(name)] ?? "name=\(name)")
                        if ospf, !result["network_type"].isEmpty { entry["network_type"] = result["network_type"] }
                        return entry.raw
                    }
                    .joined(separator: "\0")
                }
                params["protocol"] = edit.protocol
                guard edit.row != nil else {
                    params["node_id"] = edit.node
                    return await session.run("Add \(edit.node) to \(edit.fabric)", .post, "/cluster/sdn/fabrics/node/\(edit.fabric.enc)", params)
                }
                return await session.run("Save \(edit.node) in \(edit.fabric)", .put, "/cluster/sdn/fabrics/node/\(edit.fabric.enc)/\(edit.node.enc)", params)
            }
        }
    }
}

// MARK: Custom CPU models

/// CPU types of your own (PVE 9): a base model QEMU reports to the guest, plus flags. VMs pick them as custom-NAME.
struct CustomCPUModels: View {
    @Environment(Session.self) private var session
    @State private var editing: Row??

    var body: some View {
        VStack(spacing: 0) {
            ActionBar(hint: "VMs pick these as CPU type custom-NAME.") {
                Button("Add CPU Model", systemImage: "plus") { editing = .some(nil) }
            }
            ResourceList(path: "/cluster/qemu/custom-cpu-models", id: { $0.string("cputype") ?? "" },
                         columns: [APIColumn("Name", key: "cputype", width: 190, monospaced: true),
                                   APIColumn("Reports as", key: "reported-model", width: 170),
                                   APIColumn("Flags", width: 260, monospaced: true) { ($0.string("flags") ?? "").replacingOccurrences(of: ";", with: " ") },
                                   APIColumn("Hidden", width: 70) { $0.bool("hidden") ? "Yes" : "" },
                                   APIColumn("Address bits", width: 100) { $0.string("phys-bits") ?? "" }],
                         emptyTitle: "No custom CPU models", emptySymbol: "cpu",
                         emptyMessage: "Define a CPU with exactly the flags your guests need, for example to live-migrate between different hosts.",
                         open: { editing = .some($0) }) { row in
                Button("Edit…") { editing = .some(row) }
                Divider()
                Button("Delete…", role: .destructive) {
                    session.confirmDelete("Delete CPU model \(row.id)?", message: "VMs using it can't start until they get another CPU type.",
                                          path: "/cluster/qemu/custom-cpu-models/\(row.id.enc)")
                }
            }
        }
        .sheet(item: Binding(get: { editing.map { SimpleEdit(row: $0) } }, set: { editing = $0.map(\.row) })) { CPUModelEditor(row: $0.row) }
        .debugAction("add-cpu-model") { editing = .some(nil) }
    }
}

private struct CPUModelEditor: View {
    @Environment(Session.self) private var session
    let row: Row?

    var body: some View {
        Prepared(load: {
            // Every flag the cluster's CPUs know, not just the VM-specific short list.
            let flags = ((try? await session.client.list("/cluster/qemu/cpu-flags")) ?? [])
                .compactMap { flag in flag.text("name").map { FormField.Choice($0, flag.text("description") ?? $0) } }
            return (await session.cpuChoices(on: session.onlineNodes.first ?? "").filter { !$0.value.hasPrefix("custom-") }, flags)
        }) { loaded in
            let (models, known) = loaded
            let json = row?.json ?? [:]
            let set = (json.string("flags") ?? "").split(separator: ";").map { String($0.dropFirst()) }
            let flags = known + set.filter { name in !known.contains { $0.value == name } }.map { FormField.Choice($0) }
            FormSheet(title: row == nil ? "Add CPU model" : "Edit \(row!.id)", fields: [
                FormField(key: "cputype", label: "Name", prompt: "epyc-migratable", help: "VMs see it as custom-NAME", required: true, lockedOnEdit: true),
                FormField(key: "reported-model", label: "Based on", kind: .choice(models), required: true),
                FormField(key: "flags", label: "Flags", kind: flags.isEmpty ? .text : .flags(flags), prompt: "+aes;-pcid",
                          help: flags.isEmpty ? "Separate with ;. +FLAG turns a flag on, -FLAG turns it off" : "On or off on top of the base model"),
                FormField(key: "hidden", label: "Hide the hypervisor", kind: .toggle, help: "Don't identify as a KVM virtual machine"),
                FormField(key: "hv-vendor-id", label: "Hyper-V vendor ID", help: "Some Windows drivers expect a particular ID"),
                FormField(key: "phys-bits", label: "Physical address bits", prompt: "host, or 32–64"),
                FormField(key: "guest-phys-bits", label: "Guest physical address bits", kind: .number),
                FormField(key: "level", label: "CPUID level", kind: .number),
            ], initial: ["cputype": (json.string("cputype") ?? "").replacingOccurrences(of: "custom-", with: ""),
                         "reported-model": json.string("reported-model") ?? "x86-64-v2-AES", "flags": json.string("flags") ?? "",
                         "hidden": json.bool("hidden") ? "1" : "0", "hv-vendor-id": json.string("hv-vendor-id") ?? "",
                         "phys-bits": json.string("phys-bits") ?? "", "guest-phys-bits": json.string("guest-phys-bits") ?? "",
                         "level": json.string("level") ?? ""], isEdit: row != nil, submitTitle: row == nil ? "Add" : "Save") { result in
                guard let row else {
                    var params = result.changed
                    if params["hidden"] == "0" { params["hidden"] = nil }
                    return await session.run("Add CPU model \(result["cputype"])", .post, "/cluster/qemu/custom-cpu-models", params)
                }
                return await session.run("Save \(row.id)", .put, "/cluster/qemu/custom-cpu-models/\(row.id.enc)", result.params)
            }
        }
    }
}
