import SwiftUI

// MARK: Add and edit

/// What's being added or edited on the SDN page: the kind, its type (zones and controllers), the row when editing,
/// and the VNet a subnet belongs to.
struct SDNEdit: Identifiable {
    let kind: String
    var type: String?
    var row: Row?
    var vnet: String?
    var id: String { "\(kind)-\(type ?? "")-\(row?.id ?? "new")" }
}

/// One editor for every SDN object, like the web UI's: the fields that apply to its type, with zones, controllers,
/// IPAMs, DNS servers, fabrics and nodes offered as choices. Secrets left empty keep their current value.
struct SDNObjectEditor: View {
    @Environment(Session.self) private var session
    let edit: SDNEdit

    private struct Lists {
        var zones: [FormField.Choice] = []
        var controllers: [FormField.Choice] = []
        var ipams: [FormField.Choice] = []
        var dns: [FormField.Choice] = []
        var fabrics: [FormField.Choice] = []
        var routeMaps: [FormField.Choice] = []
        var config: JSONObject = [:]
    }

    private static let idKeys = ["zones": "zone", "vnets": "vnet", "subnets": "subnet", "controllers": "controller", "ipams": "ipam", "dns": "dns"]
    private static let secrets = ["token", "key"]

    var body: some View {
        Prepared(load: {
            var lists = Lists()
            let ids = { (path: String, key: String) async -> [FormField.Choice] in
                ((try? await session.client.list(path)) ?? []).compactMap { $0.text(key) }.map { FormField.Choice($0) }
            }
            lists.zones = await ids("/cluster/sdn/zones", "zone")
            lists.controllers = await ids("/cluster/sdn/controllers", "controller")
            lists.ipams = await ids("/cluster/sdn/ipams", "ipam")
            lists.dns = await ids("/cluster/sdn/dns", "dns")
            lists.fabrics = await ids("/cluster/sdn/fabrics/fabric", "id")
            if edit.kind == "controllers" { lists.routeMaps = await ids("/cluster/sdn/route-maps", "id") }
            if let row = edit.row {
                let path = edit.kind == "subnets" ? "/cluster/sdn/vnets/\((edit.vnet ?? "").enc)/subnets/\(row.id.enc)" : "/cluster/sdn/\(edit.kind)/\(row.id.enc)"
                lists.config = (try? await session.client.object(path)) ?? row.json
            }
            return lists
        }) { lists in
            let fields = fields(lists)
            FormSheet(title: title, message: message, fields: fields, initial: initial(lists.config, fields: fields),
                      isEdit: edit.row != nil, submitTitle: edit.row == nil ? "Add" : "Save") { result in
                await save(result)
            }
        }
    }

    private var type: String { edit.type ?? edit.row?["type"] ?? "" }

    private var title: String {
        let noun = ["zones": "zone", "vnets": "VNet", "subnets": "subnet", "controllers": "controller", "ipams": "IPAM", "dns": "DNS server"][edit.kind] ?? edit.kind
        let typed = SDNView.typeNames[type].map { "\($0) \(noun)" } ?? noun
        return edit.row.map { "Edit \(noun) \($0.id)" } ?? "Add \(typed)"
    }

    private var message: String? {
        switch (edit.kind, type) {
        case ("zones", "simple"): "An isolated bridge on each node, with optional routing and DHCP."
        case ("zones", "vlan"): "VNets get a VLAN tag on an existing bridge."
        case ("zones", "qinq"): "VNets get an inner VLAN tag inside a service VLAN."
        case ("zones", "vxlan"): "VNets span the cluster over UDP tunnels between the peers."
        case ("zones", "evpn"): "VXLAN with BGP EVPN routing between nodes and exit nodes."
        case ("subnets", _): "Changes apply with Apply Changes on the SDN page."
        default: nil
        }
    }

    private func nodes() -> [FormField.Choice] { session.nodes.map { FormField.Choice($0.node) } }

    private func fields(_ lists: Lists) -> [FormField] {
        switch edit.kind {
        case "zones":
            var fields = [FormField(key: "zone", label: "ID", prompt: "lab", help: "Up to 8 letters and digits", required: true, lockedOnEdit: true)]
            switch type {
            case "vlan":
                fields.append(FormField(key: "bridge", label: "Bridge", prompt: "vmbr0", required: true))
            case "qinq":
                fields += [FormField(key: "bridge", label: "Bridge", prompt: "vmbr0", required: true),
                           FormField(key: "tag", label: "Service VLAN", kind: .number, required: true),
                           FormField(key: "vlan-protocol", label: "Service VLAN protocol", kind: .choice([.init("802.1q"), .init("802.1ad")]), prompt: "802.1q")]
            case "vxlan":
                fields += [FormField(key: "peers", label: "Peers", prompt: "192.168.1.10,192.168.1.11", help: "The nodes' addresses, or use a fabric"),
                           FormField(key: "fabric", label: "Fabric", kind: .choice(lists.fabrics), prompt: "None"),
                           FormField(key: "vxlan-port", label: "UDP port", kind: .number, prompt: "4789")]
            case "evpn":
                fields += [FormField(key: "controller", label: "Controller", kind: .choice(lists.controllers), required: true),
                           FormField(key: "vrf-vxlan", label: "VRF VNI", kind: .number, required: true),
                           FormField(key: "mac", label: "Router MAC", prompt: "Automatic"),
                           FormField(key: "exitnodes", label: "Exit nodes", kind: .multiChoice(nodes())),
                           FormField(key: "exitnodes-primary", label: "Primary exit node", kind: .choice(nodes()), prompt: "None"),
                           FormField(key: "exitnodes-local-routing", label: "Exit nodes reach guests", kind: .toggle),
                           FormField(key: "advertise-subnets", label: "Advertise subnets", kind: .toggle, help: "Type-5 routes instead of MAC/IP pairs"),
                           FormField(key: "disable-arp-nd-suppression", label: "Don't suppress ARP and ND", kind: .toggle),
                           FormField(key: "rt-import", label: "Import route targets", prompt: "65000:100")]
            default:
                fields.append(FormField(key: "dhcp", label: "DHCP", kind: .choice([.init("dnsmasq", "dnsmasq")]), prompt: "None", help: "Hands out addresses from the subnets' DHCP ranges"))
            }
            fields += [FormField(key: "mtu", label: "MTU", kind: .number, prompt: "Automatic"),
                       FormField(key: "nodes", label: "Nodes", kind: .multiChoice(nodes()), help: "None checked means all nodes"),
                       FormField(key: "ipam", label: "IPAM", kind: .choice(lists.ipams), prompt: "pve"),
                       FormField(key: "dns", label: "DNS server", kind: .choice(lists.dns), prompt: "None"),
                       FormField(key: "reversedns", label: "Reverse DNS server", kind: .choice(lists.dns), prompt: "None"),
                       FormField(key: "dnszone", label: "DNS zone", prompt: "lab.example.com")]
            return fields
        case "vnets":
            return [FormField(key: "vnet", label: "Name", prompt: "vnet1", help: "Up to 8 letters and digits", required: true, lockedOnEdit: true),
                    FormField(key: "zone", label: "Zone", kind: .choice(lists.zones), required: true),
                    FormField(key: "alias", label: "Alias"),
                    FormField(key: "tag", label: "Tag", kind: .number, help: "VLAN ID (VLAN, QinQ) or VNI (VXLAN, EVPN)"),
                    FormField(key: "vlanaware", label: "VLAN aware", kind: .toggle, help: "Lets guests use VLANs inside this VNet"),
                    FormField(key: "isolate-ports", label: "Isolate ports", kind: .toggle, help: "Guests on this VNet can only talk to the gateway")]
        case "subnets":
            return [FormField(key: "subnet", label: "Subnet", prompt: "10.10.0.0/24", required: true, lockedOnEdit: true),
                    FormField(key: "gateway", label: "Gateway", prompt: "10.10.0.1"),
                    FormField(key: "snat", label: "SNAT", kind: .toggle, help: "Masquerade traffic leaving the subnet"),
                    FormField(key: "dnszoneprefix", label: "DNS zone prefix", prompt: "adm"),
                    FormField(key: "dhcp-range", label: "DHCP ranges", kind: .multiline, help: "One per line: first-last, e.g. 10.10.0.100-10.10.0.200"),
                    FormField(key: "dhcp-dns-server", label: "DHCP DNS server", prompt: "The gateway")]
        case "controllers":
            var fields = [FormField(key: "controller", label: "ID", prompt: "evpn1", required: true, lockedOnEdit: true)]
            switch type {
            case "bgp":
                fields += [FormField(key: "node", label: "Node", kind: .choice(nodes()), required: true),
                           FormField(key: "asn", label: "ASN", kind: .number, required: true),
                           FormField(key: "peers", label: "Peers", prompt: "192.168.1.1", required: true),
                           FormField(key: "ebgp", label: "eBGP", kind: .toggle),
                           FormField(key: "ebgp-multihop", label: "eBGP multihop", kind: .number),
                           FormField(key: "loopback", label: "Loopback interface", prompt: "dummy1"),
                           FormField(key: "bgp-multipath-as-path-relax", label: "Multipath with different AS paths", kind: .toggle)] + routeMapFields(lists)
            case "isis":
                fields += [FormField(key: "node", label: "Node", kind: .choice(nodes()), required: true),
                           FormField(key: "isis-domain", label: "Domain", prompt: "evpn", required: true),
                           FormField(key: "isis-ifaces", label: "Interfaces", prompt: "eth1,eth2", required: true),
                           FormField(key: "isis-net", label: "Network entity title", prompt: "47.0023.0000.0000.0000.0000.0000.0000.1900.0004.00", required: true),
                           FormField(key: "loopback", label: "Loopback interface", prompt: "dummy1")]
            default:
                fields += [FormField(key: "asn", label: "ASN", kind: .number, required: true),
                           FormField(key: "peers", label: "Peers", prompt: "192.168.1.10,192.168.1.11", required: true),
                           FormField(key: "fabric", label: "Fabric", kind: .choice(lists.fabrics), prompt: "None")] + routeMapFields(lists)
            }
            return fields
        case "ipams":
            var fields = [FormField(key: "ipam", label: "ID", prompt: "netbox", required: true, lockedOnEdit: true),
                          FormField(key: "url", label: "API URL", prompt: type == "phpipam" ? "https://phpipam.example.com/api/proxmox" : "https://netbox.example.com/api", required: true),
                          FormField(key: "token", label: "Token", kind: .secure, prompt: edit.row == nil ? "" : "Unchanged", required: edit.row == nil)]
            if type == "phpipam" { fields.append(FormField(key: "section", label: "Section", kind: .number, required: true)) }
            return fields
        default:
            return [FormField(key: "dns", label: "ID", prompt: "powerdns", required: true, lockedOnEdit: true),
                    FormField(key: "url", label: "API URL", prompt: "http://powerdns.example.com:8081/api/v1/servers/localhost", required: true),
                    FormField(key: "key", label: "API key", kind: .secure, prompt: edit.row == nil ? "" : "Unchanged", required: edit.row == nil),
                    FormField(key: "ttl", label: "TTL", kind: .number, prompt: "3600"),
                    FormField(key: "reversemaskv6", label: "IPv6 reverse mask", kind: .number, prompt: "64")]
        }
    }

    private func routeMapFields(_ lists: Lists) -> [FormField] {
        [FormField(key: "route-map-in", label: "Incoming route map", kind: .choice(lists.routeMaps), prompt: "None"),
         FormField(key: "route-map-out", label: "Outgoing route map", kind: .choice(lists.routeMaps), prompt: "None")]
    }

    private func initial(_ config: JSONObject, fields: [FormField]) -> [String: String] {
        var values: [String: String] = [:]
        for field in fields where !Self.secrets.contains(field.key) {
            if field.key == "dhcp-range" {
                // Ranges read back as {start-address, end-address} objects; each becomes an "a-b" line.
                values[field.key] = ((config["dhcp-range"] as? [Any]) ?? []).compactMap { item in
                    let range = item as? JSONObject ?? (item as? String).map { Dictionary(uniqueKeysWithValues: PropertyString($0).pairs.map { ($0.key, $0.value as Any) }) }
                    return range.map { [$0.string("start-address"), $0.string("end-address")].compactMap { $0 }.joined(separator: "-") }
                }.joined(separator: "\n")
            } else if case .toggle = field.kind {
                values[field.key] = config.bool(field.key) ? "1" : "0"
            } else {
                values[field.key] = config.string(field.key) ?? ""
            }
        }
        if edit.kind == "subnets", let cidr = config.string("cidr") { values["subnet"] = cidr }
        if edit.row == nil, edit.kind == "vnets" { values["zone"] = values["zone"].flatMap { $0.isEmpty ? nil : $0 } ?? "" }
        return values
    }

    private func save(_ result: FormResult) async -> Bool {
        let idKey = Self.idKeys[edit.kind] ?? edit.kind
        var params = edit.row == nil ? result.changed : result.params
        // Booleans the user left off aren't sent when adding.
        if edit.row == nil { params = params.filter { $0.value != "0" || ["tag", "mtu"].contains($0.key) } }
        if let ranges = params["dhcp-range"] {
            params["dhcp-range"] = ranges.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let parts = line.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 ? "start-address=\(parts[0]),end-address=\(parts[1])" : nil
            }.joined(separator: "\0")
        }
        // An empty secret on edit keeps the stored one.
        for secret in Self.secrets where edit.row != nil && params[secret] == nil {
            params["delete"] = params["delete"]?.split(separator: ",").filter { $0 != secret }.joined(separator: ",")
        }
        if params["delete"]?.isEmpty == true { params["delete"] = nil }
        if let row = edit.row {
            params[idKey] = nil
            let path = edit.kind == "subnets" ? "/cluster/sdn/vnets/\((edit.vnet ?? "").enc)/subnets/\(row.id.enc)" : "/cluster/sdn/\(edit.kind)/\(row.id.enc)"
            return await session.run("Save \(row.id)", .put, path, params)
        }
        if edit.kind == "subnets" {
            params["type"] = "subnet"
            return await session.run("Add subnet \(result["subnet"])", .post, "/cluster/sdn/vnets/\((edit.vnet ?? "").enc)/subnets", params)
        }
        if let type = edit.type { params["type"] = type }
        if edit.kind == "dns" { params["type"] = "powerdns" }
        return await session.run("Add \(result[idKey])", .post, "/cluster/sdn/\(edit.kind)", params)
    }
}

// MARK: VNet firewall

/// A VNet's own firewall (PVE 8.3+): rules for traffic forwarded through it, and its options.
struct SDNVNetFirewallSheet: View {
    @Environment(\.dismiss) private var dismiss
    let vnet: String
    @State private var section = "rules"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Firewall of \(vnet)").font(.title2.bold())
                    Text("Filters traffic that passes through the VNet's bridge.").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Section", selection: $section) {
                    Text("Rules").tag("rules")
                    Text("Options").tag("options")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(24)
            if section == "options" {
                SDNVNetFirewallOptions(vnet: vnet)
            } else {
                FirewallRules(rulesPath: "/cluster/sdn/vnets/\(vnet.enc)/firewall/rules", directions: ["forward"])
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
                .controlSize(.large)
                .padding(20)
        }
        .frame(width: 940, height: 600)
    }
}

private struct SDNVNetFirewallOptions: View {
    @Environment(Session.self) private var session
    let vnet: String
    @State private var options: JSONObject = [:]

    private var path: String { "/cluster/sdn/vnets/\(vnet.enc)/firewall/options" }

    var body: some View {
        Form {
            Toggle("Firewall enabled", isOn: Binding { options.bool("enable") } set: { save(["enable": $0 ? "1" : "0"]) })
            Picker("Forward policy", selection: Binding { options.string("policy_forward") ?? "ACCEPT" } set: { save(["policy_forward": $0]) }) {
                Text("Accept").tag("ACCEPT")
                Text("Drop").tag("DROP")
            }
            Picker("Log forwarded traffic", selection: Binding { options.string("log_level_forward") ?? "nolog" } set: { save(["log_level_forward": $0]) }) {
                ForEach(["nolog", "emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"], id: \.self) { Text($0 == "nolog" ? "Don't log" : $0.capitalized).tag($0) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: session.revision) { options = (try? await session.client.object(path)) ?? [:] }
    }

    private func save(_ params: [String: String]) {
        for (key, value) in params { options[key] = value }
        Task { await session.run("Change the VNet firewall", .put, path, params) }
    }
}

// MARK: IPAM

/// The addresses the built-in IPAM handed out, with the mappings you can add, change or remove.
struct SDNIPAMSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let ipam: String
    @State private var entries: [Row] = []
    @State private var error: String?
    @State private var selection: Row.ID?
    @State private var editing: Row??

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Addresses in \(ipam)").font(.title2.bold())
                    Text("Gateways and the addresses guests got on SDN subnets.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Mapping", systemImage: "plus") { editing = .some(nil) }.buttonStyle(.glass)
            }
            Table(entries, selection: $selection) {
                TableColumn("Zone") { Text($0["zone"] ?? "") }.width(min: 50, ideal: 70)
                TableColumn("VNet") { Text($0["vnet"] ?? "") }.width(min: 50, ideal: 70)
                TableColumn("Subnet") { Text($0["subnet"] ?? "").monospaced() }.width(min: 100, ideal: 120)
                TableColumn("Address") { row in
                    Text(row["ip"] ?? "").monospaced().fontWeight(row.json.bool("gateway") ? .semibold : .regular)
                }
                .width(min: 100, ideal: 120)
                TableColumn("MAC") { Text($0["mac"] ?? "").monospaced().foregroundStyle(.secondary) }.width(min: 120, ideal: 140)
                TableColumn("Guest") { row in
                    Text(row.json.bool("gateway") ? "Gateway" : [row["vmid"], row["hostname"]].compactMap { $0 }.joined(separator: " "))
                        .foregroundStyle(.secondary)
                }
                .width(min: 140, ideal: 180)
            }
            .contextMenu(forSelectionType: Row.ID.self) { ids in
                if let row = entries.first(where: { ids.contains($0.id) }), !row.json.bool("gateway") {
                    Button("Edit…") { editing = .some(row) }
                    Divider()
                    Button("Remove…", role: .destructive) {
                        session.confirmDelete("Remove \(row["ip"] ?? "")?", message: "The address is released in the IPAM.",
                                              path: "/cluster/sdn/vnets/\((row["vnet"] ?? "").enc)/ips",
                                              params: ["zone": row["zone"] ?? "", "ip": row["ip"] ?? ""].merging(row["mac"].map { ["mac": $0] } ?? [:]) { a, _ in a })
                    }
                }
            } primaryAction: { ids in
                if let row = entries.first(where: { ids.contains($0.id) }), !row.json.bool("gateway") { editing = .some(row) }
            }
            .overlay {
                if let error { ContentUnavailableView("Couldn't read the IPAM", systemImage: "exclamationmark.triangle", description: Text(error)) }
                else if entries.isEmpty { ContentUnavailableView("No addresses yet", systemImage: "list.number") }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .controlSize(.large)
        .padding(24)
        .frame(width: 900, height: 520)
        .task(id: session.revision) {
            do {
                entries = try await session.client.list("/cluster/sdn/ipams/\(ipam.enc)/status").enumerated()
                    .map { Row(id: "\($0.offset)-\($0.element.string("ip") ?? "")", json: $0.element) }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
        .sheet(item: Binding(get: { editing.map { SimpleEdit(row: $0) } }, set: { editing = $0.map(\.row) })) { edit in
            Prepared(load: { ((try? await session.client.list("/cluster/sdn/vnets")) ?? []).map { ($0.string("vnet") ?? "", $0.string("zone") ?? "") } }) { vnets in
                let row = edit.row
                FormSheet(title: row == nil ? "Add IP mapping" : "Edit \(row?["ip"] ?? "")", fields: [
                    FormField(key: "vnet", label: "VNet", kind: .choice(vnets.map { FormField.Choice($0.0, "\($0.0) (zone \($0.1))") }), required: true, lockedOnEdit: true),
                    FormField(key: "ip", label: "Address", prompt: "10.20.0.50", required: true, lockedOnEdit: true),
                    FormField(key: "mac", label: "MAC address", prompt: "BC:24:11:00:00:01"),
                    FormField(key: "vmid", label: "Guest ID", kind: .number),
                ], initial: ["vnet": row?["vnet"] ?? vnets.first?.0 ?? "", "ip": row?["ip"] ?? "", "mac": row?["mac"] ?? "", "vmid": row?["vmid"] ?? ""],
                          isEdit: row != nil, submitTitle: row == nil ? "Add" : "Save") { result in
                    let zone = vnets.first { $0.0 == result["vnet"] }?.1 ?? row?["zone"] ?? ""
                    var params = ["zone": zone, "ip": result["ip"]]
                    if !result["mac"].isEmpty { params["mac"] = result["mac"] }
                    if row != nil, !result["vmid"].isEmpty { params["vmid"] = result["vmid"] }
                    return await session.run(row == nil ? "Map \(result["ip"])" : "Save \(result["ip"])", row == nil ? .post : .put,
                                             "/cluster/sdn/vnets/\(result["vnet"].enc)/ips", params)
                }
            }
        }
    }
}

// MARK: Pending changes

/// What Apply Changes would write to a node's network and FRR configuration, as a diff (PVE 8.3+ dry run).
struct SDNDryRunSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var node = ""
    @State private var diff: JSONObject?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pending SDN changes").font(.title2.bold())
                Spacer()
                Picker("Node", selection: $node) {
                    ForEach(session.onlineNodes, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
            }
            if let error {
                ContentUnavailableView("Couldn't preview the changes", systemImage: "exclamationmark.triangle",
                                       description: Text("\(error)\nThe dry run needs Proxmox VE 8.3 or later."))
                    .frame(maxHeight: .infinity)
            } else if let diff {
                let network = diff.string("interfaces-diff") ?? "", frr = diff.string("frr-diff") ?? ""
                if network.isEmpty && frr.isEmpty {
                    ContentUnavailableView("Nothing to apply", systemImage: "checkmark.circle", description: Text("\(node) already runs the current SDN configuration."))
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if !network.isEmpty { section("Network interfaces", network) }
                            if !frr.isEmpty { section("FRR routing", frr) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .controlSize(.large)
        .padding(24)
        .frame(width: 760, height: 540)
        .task(id: node) {
            guard !node.isEmpty else { node = session.onlineNodes.first ?? ""; return }
            diff = nil
            do {
                diff = try await session.client.object("/cluster/sdn/dry-run", ["node": node])
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func section(_ title: String, _ diff: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .foregroundStyle(line.hasPrefix("+") && !line.hasPrefix("+++") ? .green : line.hasPrefix("-") && !line.hasPrefix("---") ? .red : .primary)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
        }
    }
}

// MARK: Prefix lists

/// BGP prefix lists (PVE 9.2): named lists of permitted or denied prefixes that route maps match on.
struct SDNPrefixLists: View {
    @Environment(Session.self) private var session
    @State private var lists: [String] = []
    @State private var selected: String?
    @State private var addingList = false
    @State private var editing: Row??

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(lists, id: \.self, selection: $selected) { name in
                    Text(name).fontWeight(.medium)
                        .contextMenu {
                            Button("Delete List…", role: .destructive) { session.confirmDelete("Delete prefix list \(name)?", path: "/cluster/sdn/prefix-lists/\(name.enc)") }
                        }
                }
                HStack {
                    Button("Add List", systemImage: "plus") { addingList = true }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 300, maxHeight: .infinity)
            Group {
                if let selected {
                    VStack(spacing: 0) {
                        HStack {
                            Button("Add Entry", systemImage: "plus") { editing = .some(nil) }
                            Spacer()
                            Text("Checked in order; the first match decides.").font(.callout).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.glass)
                        .padding(10)
                        ResourceList(path: "/cluster/sdn/prefix-lists/\(selected.enc)/entries", id: { $0.string("seq") ?? "" },
                                     columns: [APIColumn("Order", key: "seq", width: 60), APIColumn("Action", width: 70) { ($0.string("action") ?? "").capitalized },
                                               APIColumn("Prefix", key: "prefix", width: 180, monospaced: true),
                                               APIColumn("Length", width: 140) { row in
                                                   [row.string("ge").map { "≥ \($0)" }, row.string("le").map { "≤ \($0)" }].compactMap { $0 }.joined(separator: ", ")
                                               }],
                                     emptyTitle: "No entries", emptySymbol: "list.number", open: { editing = .some($0) }) { row in
                            Button("Edit…") { editing = .some(row) }
                        } delete: { row in
                            Deletion { session.confirmDelete("Delete entry \(row.id)?", path: "/cluster/sdn/prefix-lists/\(selected.enc)/entries/\(row.id.enc)") }
                        }
                        .id(selected)
                    }
                } else {
                    ContentUnavailableView("Pick a prefix list", systemImage: "list.number", description: Text("Route maps match routes against these lists."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .task(id: session.revision) {
            lists = ((try? await session.client.list("/cluster/sdn/prefix-lists")) ?? []).compactMap { $0.text("id") }
            if selected == nil || !lists.contains(selected ?? "") { selected = lists.first }
        }
        .sheet(isPresented: $addingList) {
            FormSheet(title: "Add prefix list", fields: [FormField(key: "id", label: "Name", prompt: "lan-only", required: true)], submitTitle: "Add") { result in
                await session.run("Add prefix list \(result["id"])", .post, "/cluster/sdn/prefix-lists", ["id": result["id"]])
            }
        }
        .sheet(item: Binding(get: { editing.map { SimpleEdit(row: $0) } }, set: { editing = $0.map(\.row) })) { edit in
            let json = edit.row?.json ?? [:]
            FormSheet(title: edit.row == nil ? "Add entry to \(selected ?? "")" : "Edit entry \(edit.row!.id)", fields: [
                FormField(key: "seq", label: "Order", kind: .number, prompt: "Next", lockedOnEdit: true),
                FormField(key: "action", label: "Action", kind: .choice([.init("permit", "Permit"), .init("deny", "Deny")]), required: true),
                FormField(key: "prefix", label: "Prefix", prompt: "192.168.0.0/16", required: true),
                FormField(key: "ge", label: "Prefix length at least", kind: .number),
                FormField(key: "le", label: "Prefix length at most", kind: .number),
            ], initial: ["seq": json.string("seq") ?? "", "action": json.string("action") ?? "permit", "prefix": json.string("prefix") ?? "",
                         "ge": json.string("ge") ?? "", "le": json.string("le") ?? ""], isEdit: edit.row != nil, submitTitle: edit.row == nil ? "Add" : "Save") { result in
                guard let selected else { return false }
                if let row = edit.row {
                    var params = result.params
                    params["seq"] = nil
                    return await session.run("Save entry \(row.id)", .put, "/cluster/sdn/prefix-lists/\(selected.enc)/entries/\(row.id.enc)", params)
                }
                return await session.run("Add entry to \(selected)", .post, "/cluster/sdn/prefix-lists/\(selected.enc)/entries", result.changed)
            }
        }
    }
}

// MARK: Route maps

/// BGP route maps (PVE 9.2): ordered entries that match routes and change their attributes.
struct SDNRouteMaps: View {
    @Environment(Session.self) private var session
    @State private var editing: Row??

    /// "key=ip-address-prefix-list,value=lan" reads as "ip-address-prefix-list lan".
    static func readable(_ items: [String]) -> String {
        items.map { item in
            let pair = PropertyString(item)
            return [pair["key"], pair["value"]].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: "; ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add Entry", systemImage: "plus") { editing = .some(nil) }
                Spacer()
                Text("Within a route map, entries are checked by order.").font(.callout).foregroundStyle(.secondary)
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            ResourceList(path: "/cluster/sdn/route-maps/entries", id: { "\($0.string("route-map-id") ?? "")/\($0.string("order") ?? "")" },
                         columns: [APIColumn("Route map", key: "route-map-id", width: 130), APIColumn("Order", key: "order", width: 60),
                                   APIColumn("Action", width: 70) { ($0.string("action") ?? "").capitalized },
                                   APIColumn("Match", width: 240) { Self.readable($0.strings("match")) },
                                   APIColumn("Set", width: 200) { Self.readable($0.strings("set")) },
                                   APIColumn("Then", width: 130) { row in Self.readable(row.string("exit-action").map { [$0] } ?? []) }],
                         emptyTitle: "No route maps", emptySymbol: "arrow.triangle.branch",
                         emptyMessage: "Filter or adjust the routes BGP and EVPN controllers exchange.", open: { editing = .some($0) }) { row in
                Button("Edit…") { editing = .some(row) }
            } delete: { row in
                Deletion {
                    session.confirmDelete("Delete entry \(row["order"] ?? "") of \(row["route-map-id"] ?? "")?",
                                          path: "/cluster/sdn/route-maps/entries/\((row["route-map-id"] ?? "").enc)/entry/\((row["order"] ?? "").enc)")
                }
            }
        }
        .sheet(item: Binding(get: { editing.map { SimpleEdit(row: $0) } }, set: { editing = $0.map(\.row) })) { edit in
            let json = edit.row?.json ?? [:]
            let lines = { (items: [String]) in items.map { item in
                let pair = PropertyString(item)
                return [pair["key"], pair["value"]].compactMap { $0 }.joined(separator: " ")
            }.joined(separator: "\n") }
            let exit = PropertyString(json.string("exit-action") ?? "")
            FormSheet(title: edit.row == nil ? "Add route map entry" : "Edit \(edit.row!.id)", fields: [
                FormField(key: "route-map-id", label: "Route map", prompt: "export-lan", required: true, lockedOnEdit: true),
                FormField(key: "order", label: "Order", kind: .number, prompt: "10", required: true, lockedOnEdit: true),
                FormField(key: "action", label: "Action", kind: .choice([.init("permit", "Permit"), .init("deny", "Deny")]), required: true),
                FormField(key: "match", label: "Match", kind: .multiline,
                          help: "One per line: what and value, e.g. ip-address-prefix-list lan-only, vni 100, metric 10, tag 5"),
                FormField(key: "set", label: "Set", kind: .multiline,
                          help: "One per line, e.g. local-preference 200, metric 50, ip-next-hop 10.0.0.1, ip-next-hop-unchanged"),
                FormField(key: "exit", label: "After a match", kind: .choice([.init("on-match-next", "Go to the next entry"), .init("on-match-goto", "Go to an entry"),
                                                                              .init("continue", "Continue")]), prompt: "Stop"),
                FormField(key: "exit-value", label: "Entry to go to", kind: .number),
                FormField(key: "call", label: "Call route map", prompt: "None"),
            ], initial: ["route-map-id": json.string("route-map-id") ?? "", "order": json.string("order") ?? "", "action": json.string("action") ?? "permit",
                         "match": lines(json.strings("match")), "set": lines(json.strings("set")), "exit": exit["key"] ?? "", "exit-value": exit["value"] ?? "",
                         "call": json.string("call") ?? ""],
                      isEdit: edit.row != nil, submitTitle: edit.row == nil ? "Add" : "Save") { result in
                let items = { (text: String) in
                    text.split(whereSeparator: \.isNewline).map { line -> String in
                        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                        return "key=\(parts[0])" + (parts.count > 1 ? ",value=\(parts[1].trimmingCharacters(in: .whitespaces))" : "")
                    }.joined(separator: "\0")
                }
                var params = ["action": result["action"]]
                if !result["match"].isEmpty { params["match"] = items(result["match"]) }
                if !result["set"].isEmpty { params["set"] = items(result["set"]) }
                if !result["exit"].isEmpty { params["exit-action"] = "key=\(result["exit"])" + (result["exit-value"].isEmpty ? "" : ",value=\(result["exit-value"])") }
                if !result["call"].isEmpty { params["call"] = result["call"] }
                if let row = edit.row {
                    var cleared = [String]()
                    for key in ["match", "set", "call"] where result[key].isEmpty && row.json[key] != nil { cleared.append(key) }
                    if result["exit"].isEmpty && row.json["exit-action"] != nil { cleared.append("exit-action") }
                    if !cleared.isEmpty { params["delete"] = cleared.joined(separator: ",") }
                    return await session.run("Save \(row.id)", .put,
                                             "/cluster/sdn/route-maps/entries/\((row["route-map-id"] ?? "").enc)/entry/\((row["order"] ?? "").enc)", params)
                }
                params["route-map-id"] = result["route-map-id"]
                params["order"] = result["order"]
                return await session.run("Add entry \(result["order"]) to \(result["route-map-id"])", .post, "/cluster/sdn/route-maps/entries", params)
            }
        }
    }
}

// MARK: A node's SDN status

/// How the SDN looks on one node: each zone with its VNets' state and bridge ports, and each fabric's neighbors and routes.
struct NodeSDNView: View {
    @Environment(Session.self) private var session
    let node: String

    private struct Zone: Identifiable {
        let id: String
        let status: String
        var vnets: [JSONObject] = []
        var bridges: [JSONObject] = []
        /// EVPN zones: the routes in the zone's IP VRF, and each VNet's MAC VRF entries.
        var routes: [JSONObject] = []
        var macs: [String: [JSONObject]] = [:]
    }

    private struct Fabric: Identifiable {
        let id: String
        var neighbors: [JSONObject] = []
        var routes: [JSONObject] = []
        var interfaces: [JSONObject] = []
    }

    @State private var zones: [Zone] = []
    @State private var fabrics: [Fabric] = []
    @State private var loaded = false

    var body: some View {
        Page {
            if loaded && zones.isEmpty && fabrics.isEmpty {
                ContentUnavailableView("No SDN on \(node)", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Zones and fabrics show up here once they're configured under Datacenter → SDN."))
            }
            ForEach(zones) { zone in
                Card(title: "Zone \(zone.id)", systemImage: "square.dashed") {
                    if zone.vnets.isEmpty { Text("No VNets in this zone.").foregroundStyle(.secondary) }
                    ForEach(Array(zone.vnets.enumerated()), id: \.offset) { _, vnet in
                        let name = vnet.string("vnet") ?? ""
                        let ports = zone.bridges.first { $0.string("name") == name }.map { bridge in
                            bridge.objects("ports").compactMap { port in
                                port.int("vmid").flatMap { session.guest($0) }.map { "\($0.name) (\(port.string("name") ?? ""))" } ?? port.text("name")
                            }
                        } ?? []
                        HStack(alignment: .firstTextBaseline) {
                            Circle().fill(vnet.string("status") == "available" ? Color.green : .orange).frame(width: 8, height: 8)
                            Text(name).fontWeight(.medium)
                            if let message = vnet.text("statusmsg") { Text(message).font(.callout).foregroundStyle(.secondary) }
                            Spacer()
                            Text(ports.isEmpty ? "No guests attached" : ports.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(Array((zone.macs[name] ?? []).prefix(50).enumerated()), id: \.offset) { _, entry in
                            HStack {
                                Text(entry.string("mac") ?? "").monospaced()
                                Text(entry.string("ip") ?? "").monospaced().foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.text("nexthop").map { "via \($0)" } ?? "local").foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .padding(.leading, 16)
                        }
                    }
                    if !zone.routes.isEmpty {
                        Divider()
                        Text("Routes").font(.subheadline.weight(.semibold))
                        ForEach(Array(zone.routes.prefix(100).enumerated()), id: \.offset) { _, route in
                            HStack {
                                Text(route.string("ip") ?? "").monospaced()
                                Spacer()
                                Text([route.strings("nexthops").joined(separator: ", "), route.string("protocol")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                } accessory: {
                    Pill(text: zone.status.capitalized, color: zone.status == "available" ? .green : zone.status == "error" ? .red : .orange)
                }
            }
            ForEach(fabrics) { fabric in
                Card(title: "Fabric \(fabric.id)", systemImage: "point.3.connected.trianglepath.dotted") {
                    if fabric.neighbors.isEmpty && fabric.routes.isEmpty && fabric.interfaces.isEmpty { Text("\(node) isn't part of this fabric.").foregroundStyle(.secondary) }
                    ForEach(Array(fabric.interfaces.enumerated()), id: \.offset) { _, interface in
                        HStack {
                            Image(systemName: "cable.connector").foregroundStyle(.secondary)
                            Text(interface.string("name") ?? "").monospaced()
                            Spacer()
                            Text([interface.string("type"), interface.string("state")].compactMap { $0 }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(fabric.neighbors.enumerated()), id: \.offset) { _, neighbor in
                        HStack {
                            Circle().fill(neighbor.string("status") == "Up" ? Color.green : .red).frame(width: 8, height: 8)
                            Text(neighbor.string("neighbor") ?? "").fontWeight(.medium)
                            Spacer()
                            Text([neighbor.string("status"), neighbor.string("uptime").map { "for \($0)" }].compactMap { $0 }.joined(separator: " "))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(fabric.routes.enumerated()), id: \.offset) { _, route in
                        HStack {
                            Text(route.string("route") ?? "").monospaced()
                            Spacer()
                            Text("via \(route.strings("via").joined(separator: ", "))").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task(id: "\(node)-\(session.revision)") { await load() }
    }

    private func load() async {
        let base = "/nodes/\(node.enc)/sdn"
        let evpn = Set(((try? await session.client.list("/cluster/sdn/zones")) ?? []).filter { $0.string("type") == "evpn" }.compactMap { $0.text("zone") })
        var zones: [Zone] = []
        for zone in (try? await session.client.list("\(base)/zones")) ?? [] {
            guard let id = zone.text("zone") else { continue }
            var entry = Zone(id: id, status: zone.string("status") ?? "unknown")
            entry.vnets = (try? await session.client.list("\(base)/zones/\(id.enc)/content")) ?? []
            entry.bridges = (try? await session.client.list("\(base)/zones/\(id.enc)/bridges")) ?? []
            if evpn.contains(id) {
                entry.routes = (try? await session.client.list("\(base)/zones/\(id.enc)/ip-vrf")) ?? []
                for vnet in entry.vnets.compactMap({ $0.text("vnet") }) {
                    entry.macs[vnet] = (try? await session.client.list("\(base)/vnets/\(vnet.enc)/mac-vrf")) ?? []
                }
            }
            zones.append(entry)
        }
        var fabrics: [Fabric] = []
        for fabric in (try? await session.client.list("/cluster/sdn/fabrics/fabric")) ?? [] {
            guard let id = fabric.text("id") else { continue }
            var entry = Fabric(id: id)
            entry.neighbors = (try? await session.client.list("\(base)/fabrics/\(id.enc)/neighbors")) ?? []
            entry.routes = (try? await session.client.list("\(base)/fabrics/\(id.enc)/routes")) ?? []
            entry.interfaces = (try? await session.client.list("\(base)/fabrics/\(id.enc)/interfaces")) ?? []
            fabrics.append(entry)
        }
        self.zones = zones
        self.fabrics = fabrics
        loaded = true
    }
}
