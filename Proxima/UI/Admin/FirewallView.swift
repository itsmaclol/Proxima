import SwiftUI

/// Firewall for the datacenter, a node or a guest.
struct FirewallView: View {
    enum Scope: Hashable {
        case datacenter, node(String), guest(Resource)

        var base: String {
            switch self {
            case .datacenter: "/cluster/firewall"
            case .node(let node): "/nodes/\(node.enc)/firewall"
            case .guest(let guest): "/nodes/\(guest.node.enc)/\(guest.type)/\(guest.vmid)/firewall"
            }
        }

        /// Forward rules filter routed traffic; guests only see their own in and out.
        var directions: [String] {
            if case .guest = self { return ["in", "out"] }
            return ["in", "out", "forward"]
        }
    }

    let scope: Scope
    @State private var section = "rules"

    var body: some View {
        if scope == .datacenter {
            AdminPage(title: "Firewall", subtitle: "Cluster-wide rules, security groups, aliases and IP sets", symbol: "shield.lefthalf.filled",
                      colors: [.red, .orange]) {
                EmptyView()
            } content: {
                TabStrip(tabs: [PageTab(id: "rules", title: "Rules", symbol: "list.bullet"),
                                PageTab(id: "options", title: "Options", symbol: "slider.horizontal.3"),
                                PageTab(id: "groups", title: "Security Groups", symbol: "person.3"),
                                PageTab(id: "aliases", title: "Aliases", symbol: "tag"),
                                PageTab(id: "ipsets", title: "IP Sets", symbol: "number")], selection: $section)
                    .padding(.bottom, 6)
                content
            }
        } else {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    Text("Rules").tag("rules")
                    // Like the web UI, guests have their own aliases and IP sets; nodes don't.
                    if case .guest = scope {
                        Text("Aliases").tag("aliases")
                        Text("IP Sets").tag("ipsets")
                    }
                    Text("Options").tag("options")
                    Text("Log").tag("log")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, 8)
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .debugAction("firewall-aliases") { section = "aliases" }
            .debugAction("firewall-ipsets") { section = "ipsets" }
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case "options": FirewallOptions(scope: scope)
        case "groups": SecurityGroups()
        case "aliases": FirewallAliases(base: scope.base)
        case "ipsets": IPSets(base: scope.base)
        case "log": FirewallLog(base: scope.base)
        default: FirewallRules(rulesPath: scope.base + "/rules", directions: scope.directions)
        }
    }
}

/// The ordered rule list; also used inside security groups.
struct FirewallRules: View {
    @Environment(Session.self) private var session
    /// The rule list endpoint: `…/firewall/rules`, or `/cluster/firewall/groups/{group}` for a security group.
    let rulesPath: String
    var allowGroups = true
    /// Rule directions this firewall takes: forward needs the nftables firewall; VNet firewalls (PVE 8.3+) only filter forwarded traffic.
    var directions = ["in", "out", "forward"]
    @State private var rules: [Row] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var selection: Row.ID?
    @State private var editing: RuleEdit?
    @State private var groups: [FormField.Choice] = []
    @State private var macros: [FormField.Choice] = []
    @State private var refs: [FormField.Choice] = []

    struct RuleEdit: Identifiable {
        let rule: Row?
        var id: String { rule?.id ?? "new" }
    }

    var body: some View {
        let selected = rules.first { $0.id == selection }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Add Rule", systemImage: "plus") { editing = RuleEdit(rule: nil) }
                Button("Edit", systemImage: "pencil") { editing = RuleEdit(rule: selected) }.disabled(selected == nil)
                Button("Move Up", systemImage: "arrow.up") { move(selected, by: -1) }.disabled(selected == nil || selected?["pos"] == "0")
                Button("Move Down", systemImage: "arrow.down") { move(selected, by: 1) }.disabled(selected == nil || Int(selected?["pos"] ?? "") == rules.count - 1)
                Button("Delete", systemImage: "trash") {
                    if let selected { session.confirmDelete("Delete rule \(selected["pos"] ?? "")?", path: "\(rulesPath)/\(selected["pos"] ?? "")") }
                }
                .disabled(selected == nil)
                Spacer()
                Text("Rules are checked top to bottom; the first match wins.").font(.callout).foregroundStyle(.secondary)
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            Loadable(loading: !loaded, error: error, isEmpty: rules.isEmpty, emptyTitle: "No rules", emptySymbol: "shield",
                     emptyMessage: "Without rules, the default policy decides. Add a rule to allow or block traffic.") {
                Table(rules, selection: $selection) {
                    TableColumn("On") { rule in
                        Toggle("", isOn: Binding { rule.json.bool("enable") } set: { on in
                            Task { await session.run(on ? "Enable the rule" : "Disable the rule", .put, "\(rulesPath)/\(rule["pos"] ?? "")", ["enable": on ? "1" : "0"]) }
                        })
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    }
                    .width(30)
                    TableColumn("#") { rule in Text(rule["pos"] ?? "").monospacedDigit().foregroundStyle(.secondary) }.width(24)
                    TableColumn("Direction") { rule in Text((rule["type"] ?? "").uppercased()) }.width(min: 70, ideal: 84)
                    TableColumn("Action") { rule in
                        let action = rule["action"] ?? ""
                        Text(action).fontWeight(.medium)
                            .foregroundStyle(action == "ACCEPT" ? Color.green : (action == "DROP" || action == "REJECT" ? Color.red : Color.primary))
                    }
                    .width(min: 60, ideal: 80)
                    Group {
                        TableColumn("Macro") { (rule: Row) in Text(rule["macro"] ?? "") }.width(min: 50, ideal: 80)
                        TableColumn("Protocol") { (rule: Row) in Text(rule["proto"] ?? "") }.width(min: 50, ideal: 60)
                        TableColumn("Source") { (rule: Row) in Text(rule["source"] ?? "").fontDesign(.monospaced) }.width(min: 80, ideal: 140)
                        TableColumn("Destination") { (rule: Row) in Text(rule["dest"] ?? "").fontDesign(.monospaced) }.width(min: 80, ideal: 120)
                    }
                    Group {
                        TableColumn("Port") { (rule: Row) in Text(rule["dport"] ?? "").fontDesign(.monospaced) }.width(min: 40, ideal: 70)
                        TableColumn("Interface") { (rule: Row) in Text(rule["iface"] ?? "") }.width(min: 50, ideal: 70)
                        TableColumn("Comment") { (rule: Row) in Text(rule["comment"] ?? "").foregroundStyle(.secondary) }.width(min: 80, ideal: 200)
                    }
                }
                .opacity(1)
                .contextMenu(forSelectionType: Row.ID.self) { ids in
                    if let rule = rules.first(where: { ids.contains($0.id) }) {
                        Button("Edit…") { editing = RuleEdit(rule: rule) }
                        Button("Delete…", role: .destructive) { session.confirmDelete("Delete rule \(rule["pos"] ?? "")?", path: "\(rulesPath)/\(rule["pos"] ?? "")") }
                    }
                } primaryAction: { ids in
                    if let rule = rules.first(where: { ids.contains($0.id) }) { editing = RuleEdit(rule: rule) }
                }
            }
        }
        .task(id: "\(rulesPath)-\(session.revision)") { await load() }
        .sheet(item: $editing) { edit in editor(edit.rule) }
        .debugAction("add-rule") { editing = RuleEdit(rule: nil) }
    }

    private func load() async {
        do {
            rules = try await session.client.list(rulesPath).map { Row(id: $0.string("pos") ?? UUID().uuidString, json: $0) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
        if allowGroups, groups.isEmpty, let list = try? await session.client.list("/cluster/firewall/groups") {
            groups = list.compactMap { $0.text("group") }.map { FormField.Choice($0) }
        }
        // The server's own macros and the aliases and IP sets a rule here may use, for the editor's pickers.
        if macros.isEmpty, let list = try? await session.client.list("/cluster/firewall/macros") {
            macros = list.compactMap { m in
                m.text("macro").map { name in FormField.Choice(name, m.text("descr").map { "\(name) — \($0)" } ?? name) }
            }
                .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        }
        if let list = try? await session.client.list(refsPath) {
            refs = list.compactMap { r in
                r.text("ref").map { FormField.Choice($0, "\($0)\(r.text("comment").map { " — \($0)" } ?? "")") }
            }
        }
    }

    /// Guests have their own aliases and IP sets on top of the datacenter's; everything else uses the datacenter's.
    private var refsPath: String {
        rulesPath.hasSuffix("/rules") && (rulesPath.contains("/qemu/") || rulesPath.contains("/lxc/"))
            ? String(rulesPath.dropLast("/rules".count)) + "/refs" : "/cluster/firewall/refs"
    }

    private func move(_ rule: Row?, by offset: Int) {
        guard let rule, let pos = Int(rule["pos"] ?? "") else { return }
        Task {
            if await session.run("Move the rule", .put, "\(rulesPath)/\(pos)", ["moveto": String(max(0, pos + offset + (offset > 0 ? 1 : 0)))]) {
                selection = String(pos + offset)
            }
        }
    }

    private func editor(_ rule: Row?) -> some View {
        var directions = self.directions.map { FormField.Choice($0, $0.capitalized) }
        if allowGroups && !groups.isEmpty { directions.append(.init("group", "Security group")) }
        let actions: [FormField.Choice] = [.init("ACCEPT", "Accept"), .init("DROP", "Drop"), .init("REJECT", "Reject")] + groups
        var initial: [String: String] = ["type": self.directions.first ?? "in", "action": "ACCEPT", "enable": "1"]
        if let rule {
            for key in ["type", "action", "enable", "macro", "proto", "source", "dest", "dport", "sport", "iface", "log", "comment"] {
                initial[key] = rule[key] ?? ""
            }
        }
        return FormSheet(title: rule == nil ? "Add firewall rule" : "Edit rule \(rule?["pos"] ?? "")",
                         message: "For a security group, set Direction to Security group and pick it as the Action.",
                         fields: [
                            FormField(key: "type", label: "Direction", kind: .choice(directions), required: true),
                            FormField(key: "action", label: "Action", kind: .choice(actions), required: true),
                            FormField(key: "enable", label: "Enabled", kind: .toggle),
                            FormField(key: "macro", label: "Macro", kind: .choice(macros), prompt: "None", help: "A preset protocol and port, e.g. SSH"),
                            FormField(key: "proto", label: "Protocol", kind: .choice(["tcp", "udp", "icmp", "icmpv6", "sctp", "gre", "esp", "ah", "igmp"].map { .init($0) })),
                            FormField(key: "source", label: "Source", kind: .suggested(refs), prompt: "Any, or 192.168.1.0/24, alias, +ipset"),
                            FormField(key: "dest", label: "Destination", kind: .suggested(refs), prompt: "Any"),
                            FormField(key: "dport", label: "Destination port", prompt: "e.g. 22, 8000:8100"),
                            FormField(key: "sport", label: "Source port", prompt: "Any"),
                            FormField(key: "iface", label: "Interface", prompt: "Any, e.g. net0"),
                            FormField(key: "log", label: "Log level", kind: .choice(["nolog", "info", "notice", "warning", "err", "crit", "alert", "emerg", "debug"].map { .init($0) })),
                            FormField(key: "comment", label: "Comment"),
                         ], initial: initial, isEdit: rule != nil, submitTitle: rule == nil ? "Add" : "Save") { result in
            if let rule {
                return await session.run("Save the rule", .put, "\(rulesPath)/\(rule["pos"] ?? "")", result.params)
            }
            var params = result.changed
            params["enable"] = result["enable"] == "1" ? "1" : "0"
            return await session.run("Add the rule", .post, rulesPath, params)
        }
    }
}

private struct FirewallOptions: View {
    @Environment(Session.self) private var session
    let scope: FirewallView.Scope
    @State private var options: JSONObject = [:]
    @State private var editingRateLimit = false
    @State private var editingConntrack = false

    private var isNode: Bool {
        if case .node = scope { return true }
        return false
    }

    /// The switches the web UI shows for each level, with Proxmox's defaults.
    private var switches: [(key: String, title: String, on: Bool, help: String)] {
        switch scope {
        case .datacenter:
            [("ebtables", "ebtables", true, "Filter bridged traffic with ebtables rules too")]
        case .node:
            [("ndp", "NDP", true, "Allow IPv6 neighbor discovery"),
             ("nosmurfs", "SMURF filter", true, "Drop SMURF packets"),
             ("tcpflags", "TCP flags filter", false, "Drop packets with invalid TCP flag combinations"),
             ("nf_conntrack_allow_invalid", "Allow invalid packets", false, "Accept packets connection tracking marks invalid"),
             ("log_nf_conntrack", "Log connection tracking", false, "Log new connections"),
             ("nftables", "nftables (tech preview)", false, "Use the nftables-based firewall")]
        case .guest:
            [("dhcp", "DHCP", false, "Allow DHCP traffic"),
             ("ndp", "NDP", true, "Allow IPv6 neighbor discovery"),
             ("radv", "Router advertisement", false, "Allow the guest to send router advertisements"),
             ("macfilter", "MAC filter", true, "Drop traffic from MAC addresses that aren't the guest's"),
             ("ipfilter", "IP filter", false, "Drop traffic from addresses not in the guest's ipfilter IP set")]
        }
    }

    private var logLevels: Bool {
        if case .datacenter = scope { return false }
        return true
    }

    var body: some View {
        Form {
            Section {
                Toggle("Firewall enabled", isOn: Binding { options["enable"] == nil ? isNode : options.bool("enable") } set: { on in save(["enable": on ? "1" : "0"]) })
                // Nodes have no policies of their own; the datacenter's apply.
                if !isNode {
                    policy("Input policy", "policy_in", fallback: "DROP")
                    policy("Output policy", "policy_out", fallback: "ACCEPT")
                }
                if case .datacenter = scope { policy("Forward policy", "policy_forward", fallback: "ACCEPT") }
            } footer: {
                if case .datacenter = scope, !options.bool("enable") {
                    Text("The datacenter switch turns the firewall on for every node; node and guest settings apply on top.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Filtering") {
                ForEach(switches, id: \.key) { item in
                    Toggle(isOn: Binding { options[item.key] == nil ? item.on : options.bool(item.key) } set: { on in save([item.key: on ? "1" : "0"]) }) {
                        Text(item.title)
                        Text(item.help)
                    }
                }
            }
            Section("Logging") {
                if logLevels {
                    level("Incoming", "log_level_in")
                    level("Outgoing", "log_level_out")
                }
                if case .datacenter = scope {
                    LabeledContent("Log rate limit") {
                        HStack {
                            // "enable=1,rate=1/second,burst=5" reads as "1 per second, bursts of 5".
                            let limit = PropertyString(options.string("log_ratelimit") ?? "enable=1")
                            Text(limit["enable"] == "0" ? "Off" : "\((limit["rate"] ?? "1/second").replacingOccurrences(of: "/", with: " per ")), bursts of \(limit["burst"] ?? "5")")
                                .foregroundStyle(options["log_ratelimit"] == nil ? .tertiary : .secondary)
                            Button("Edit") { editingRateLimit = true }.buttonStyle(.borderless)
                        }
                    }
                }
                if case .node = scope {
                    level("Forwarded", "log_level_forward")
                    level("SMURF packets", "smurf_log_level")
                    level("Invalid TCP flags", "tcp_flags_log_level")
                }
            }
            if isNode {
                Section("Connection tracking") {
                    LabeledContent("Tracked connections", value: (options.int("nf_conntrack_max") ?? 262_144).formatted())
                    LabeledContent("Established TCP timeout", value: Format.duration(options.int("nf_conntrack_tcp_timeout_established") ?? 432_000))
                    LabeledContent("Half-open TCP timeout", value: Format.duration(options.int("nf_conntrack_tcp_timeout_syn_recv") ?? 60))
                    LabeledContent("Protocol helpers", value: options.text("nf_conntrack_helpers")?.replacingOccurrences(of: ",", with: ", ") ?? "None")
                    Button("Edit…") { editingConntrack = true }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: session.revision) { options = (try? await session.client.object("\(scope.base)/options")) ?? [:] }
        .sheet(isPresented: $editingConntrack) { conntrackSheet }
        .sheet(isPresented: $editingRateLimit) {
            FormSheet(title: "Log rate limit", message: "Limits how often the firewall writes log lines, so a flood doesn't fill the disk.", fields: [
                FormField(key: "enable", label: "Limit logging", kind: .toggle),
                FormField(key: "rate", label: "Rate", prompt: "1/second"),
                FormField(key: "burst", label: "Burst", kind: .number, prompt: "5"),
            ], initial: Dictionary(uniqueKeysWithValues: PropertyString(options.string("log_ratelimit") ?? "enable=1").pairs.map { ($0.key, $0.value) }),
                      submitTitle: "Save") { result in
                var value = "enable=\(result["enable"] == "0" ? "0" : "1")"
                for key in ["rate", "burst"] where !result[key].isEmpty { value += ",\(key)=\(result[key])" }
                return await session.run("Change the log rate limit", .put, "\(scope.base)/options", ["log_ratelimit": value])
            }
        }
    }

    private var conntrackSheet: some View {
        let helpers = ["amanda", "ftp", "irc", "netbios-ns", "pptp", "sane", "sip", "snmp", "tftp"].map { FormField.Choice($0, $0 == "netbios-ns" ? "NetBIOS name service" : $0.uppercased()) }
        let keys = ["nf_conntrack_max", "nf_conntrack_tcp_timeout_established", "nf_conntrack_tcp_timeout_syn_recv", "nf_conntrack_helpers"]
        return FormSheet(title: "Connection tracking", message: "How many connections the node's firewall follows, and for how long. Empty fields use Proxmox's defaults.", fields: [
            FormField(key: "nf_conntrack_max", label: "Tracked connections", kind: .number, prompt: "262144", help: "At least 32768"),
            FormField(key: "nf_conntrack_tcp_timeout_established", label: "Established TCP timeout (seconds)", kind: .number, prompt: "432000", help: "At least 7875"),
            FormField(key: "nf_conntrack_tcp_timeout_syn_recv", label: "Half-open TCP timeout (seconds)", kind: .number, prompt: "60", help: "At least 30"),
            FormField(key: "nf_conntrack_helpers", label: "Protocol helpers", kind: .multiChoice(helpers), help: "Let these protocols open their related connections, e.g. FTP data"),
        ], initial: Dictionary(uniqueKeysWithValues: keys.map { ($0, options.string($0) ?? "") }), isEdit: true, submitTitle: "Save") { result in
            await session.run("Change connection tracking", .put, "\(scope.base)/options", result.params)
        }
    }

    private func policy(_ title: String, _ key: String, fallback: String) -> some View {
        Picker(title, selection: Binding { options.string(key) ?? fallback } set: { save([key: $0]) }) {
            Text("Accept").tag("ACCEPT")
            Text("Drop").tag("DROP")
            Text("Reject").tag("REJECT")
        }
    }

    private func level(_ title: String, _ key: String) -> some View {
        Picker(title, selection: Binding { options.string(key) ?? "nolog" } set: { save([key: $0]) }) {
            ForEach(["nolog", "emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"], id: \.self) { level in
                Text(level == "nolog" ? "Don't log" : level.capitalized).tag(level)
            }
        }
    }

    private func save(_ params: [String: String]) {
        Task { await session.run("Change the firewall options", .put, "\(scope.base)/options", params) }
    }
}

private struct FirewallLog: View {
    @Environment(Session.self) private var session
    let base: String
    @State private var lines: [String] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                }
                if lines.isEmpty { Text(error ?? "No firewall log entries.").foregroundStyle(.secondary).padding() }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 24)
        }
        .polling(id: base, every: .seconds(5)) {
            do {
                lines = try await session.client.list("\(base)/log", ["limit": "500"]).compactMap { $0.string("t") }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct SecurityGroups: View {
    @Environment(Session.self) private var session
    @State private var groups: [Row] = []
    @State private var selected: String?
    @State private var adding = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(groups, selection: $selected) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.id).fontWeight(.medium)
                        if let comment = group["comment"], !comment.isEmpty { Text(comment).font(.caption).foregroundStyle(.secondary) }
                    }
                    .tag(group.id)
                    .contextMenu {
                        Button("Delete Group…", role: .destructive) { session.confirmDelete("Delete security group \(group.id)?", path: "/cluster/firewall/groups/\(group.id.enc)") }
                    }
                }
                HStack {
                    Button("Add Group", systemImage: "plus") { adding = true }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320, maxHeight: .infinity)
            Group {
                if let selected {
                    FirewallRules(rulesPath: "/cluster/firewall/groups/\(selected.enc)", allowGroups: false).id(selected)
                } else {
                    ContentUnavailableView("Pick a security group", systemImage: "person.3", description: Text("Groups bundle rules you can add to nodes and guests with one rule."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: session.revision) {
            groups = ((try? await session.client.list("/cluster/firewall/groups")) ?? []).map { Row(id: $0.string("group") ?? "", json: $0) }
        }
        .sheet(isPresented: $adding) {
            FormSheet(title: "Add security group", fields: [FormField(key: "group", label: "Name", prompt: "webservers", required: true),
                                                             FormField(key: "comment", label: "Comment")], submitTitle: "Add") { result in
                await session.run("Add security group \(result["group"])", .post, "/cluster/firewall/groups", result.changed)
            }
        }
    }
}

private struct FirewallAliases: View {
    @Environment(Session.self) private var session
    /// The datacenter's firewall, or a guest's: both have their own aliases.
    var base = "/cluster/firewall"
    @State private var editing: Row??

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add Alias", systemImage: "plus") { editing = .some(nil) }
                Spacer()
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            ResourceList(path: "\(base)/aliases", id: { $0.string("name") ?? "" },
                         columns: [APIColumn("Name", key: "name", width: 160), APIColumn("Address", key: "cidr", width: 200, monospaced: true),
                                   APIColumn("Comment", key: "comment", width: 300)],
                         emptyTitle: "No aliases", emptySymbol: "tag", emptyMessage: "Aliases give names to addresses, like nas = 192.168.1.20.",
                         open: { editing = .some($0) }) { row in
                Button("Edit…") { editing = .some(row) }
            } delete: { row in
                Deletion { session.confirmDelete("Delete alias \(row.id)?", path: "\(base)/aliases/\(row.id.enc)") }
            }
        }
        .sheet(item: Binding(get: { editing.map { AliasEdit(row: $0) } }, set: { editing = $0.map(\.row) })) { edit in
            FormSheet(title: edit.row == nil ? "Add alias" : "Edit \(edit.row!.id)",
                      fields: [FormField(key: "name", label: "Name", required: true, lockedOnEdit: true),
                               FormField(key: "cidr", label: "IP address or network", prompt: "192.168.1.20 or 10.0.0.0/8", required: true),
                               FormField(key: "comment", label: "Comment")],
                      initial: edit.row?.json.mapValues { "\($0)" } ?? [:], isEdit: edit.row != nil) { result in
                if let row = edit.row {
                    var params = result.changed
                    params["cidr"] = result["cidr"]
                    return await session.run("Save alias \(row.id)", .put, "\(base)/aliases/\(row.id.enc)", params)
                }
                return await session.run("Add alias \(result["name"])", .post, "\(base)/aliases", result.changed)
            }
        }
    }

    private struct AliasEdit: Identifiable {
        let row: Row?
        var id: String { row?.id ?? "new" }
    }
}

private struct IPSets: View {
    @Environment(Session.self) private var session
    /// The datacenter's firewall, or a guest's: both have their own IP sets.
    var base = "/cluster/firewall"
    @State private var sets: [Row] = []
    @State private var selected: String?
    @State private var addingSet = false
    @State private var addingEntry = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(sets, selection: $selected) { set in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(set.id).fontWeight(.medium)
                        if let comment = set["comment"], !comment.isEmpty { Text(comment).font(.caption).foregroundStyle(.secondary) }
                    }
                    .tag(set.id)
                    .contextMenu {
                        Button("Delete IP Set…", role: .destructive) { session.confirmDelete("Delete IP set \(set.id)?", path: "\(base)/ipset/\(set.id.enc)") }
                    }
                }
                HStack {
                    Button("Add IP Set", systemImage: "plus") { addingSet = true }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320, maxHeight: .infinity)
            Group {
                if let selected {
                    VStack(spacing: 0) {
                        HStack {
                            Button("Add Address", systemImage: "plus") { addingEntry = true }
                            Spacer()
                        }
                        .buttonStyle(.glass)
                        .padding(10)
                        ResourceList(path: "\(base)/ipset/\(selected.enc)", id: { $0.string("cidr") ?? "" },
                                     columns: [APIColumn("Address", key: "cidr", width: 200, monospaced: true),
                                               APIColumn("Exclude", width: 70) { $0.bool("nomatch") ? "Yes" : "" },
                                               APIColumn("Comment", key: "comment", width: 260)],
                                     emptyTitle: "Empty IP set", emptySymbol: "number") { _ in } delete: { row in
                            Deletion(title: "Remove…") {
                                session.confirmDelete("Remove \(row.id) from \(selected)?", path: "\(base)/ipset/\(selected.enc)/\(row.id.enc)")
                            }
                        }
                    }
                    .id(selected)
                } else {
                    ContentUnavailableView("Pick an IP set", systemImage: "number", description: Text("Use IP sets in rules as +name to match many addresses at once."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: session.revision) {
            sets = ((try? await session.client.list("\(base)/ipset")) ?? []).map { Row(id: $0.string("name") ?? "", json: $0) }
        }
        .sheet(isPresented: $addingSet) {
            FormSheet(title: "Add IP set", fields: [FormField(key: "name", label: "Name", prompt: "trusted", required: true),
                                                     FormField(key: "comment", label: "Comment")], submitTitle: "Add") { result in
                await session.run("Add IP set \(result["name"])", .post, "\(base)/ipset", result.changed)
            }
        }
        .sheet(isPresented: $addingEntry) {
            FormSheet(title: "Add address to \(selected ?? "")", fields: [
                FormField(key: "cidr", label: "IP address or network", prompt: "192.168.1.0/24", required: true),
                FormField(key: "nomatch", label: "Exclude this address", kind: .toggle),
                FormField(key: "comment", label: "Comment"),
            ], submitTitle: "Add") { result in
                var params = result.changed
                if params["nomatch"] == "0" { params["nomatch"] = nil }
                return await session.run("Add \(result["cidr"])", .post, "\(base)/ipset/\((selected ?? "").enc)", params)
            }
        }
    }
}
