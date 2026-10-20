import AppKit
import SwiftUI

// MARK: Storage configuration

struct StorageConfigView: View {
    @Environment(Session.self) private var session
    @State private var adding: String?
    @State private var editing: Row?

    static let types: [(id: String, name: String)] = [("dir", "Directory"), ("lvm", "LVM"), ("lvmthin", "LVM-Thin"), ("zfspool", "ZFS"),
                                                      ("nfs", "NFS"), ("cifs", "SMB/CIFS"), ("pbs", "Proxmox Backup Server"), ("iscsi", "iSCSI"),
                                                      ("esxi", "ESXi (import)")]
    static let contents = [("images", "Disk images"), ("rootdir", "Container volumes"), ("iso", "ISO images"), ("vztmpl", "Container templates"),
                           ("backup", "Backups"), ("snippets", "Snippets"), ("import", "Import")].map { FormField.Choice($0.0, $0.1) }

    var body: some View {
        AdminPage(title: "Storage", subtitle: "Where disks, ISOs, templates and backups live", symbol: "externaldrive.connected.to.line.below", colors: [.teal, .mint]) {
            Menu("Add Storage", systemImage: "plus") {
                ForEach(Self.types, id: \.id) { type in Button("\(type.name)…") { adding = type.id } }
            }
            .fixedSize()
        } content: {
            ResourceList(path: "/storage", id: { $0.string("storage") ?? "" },
                         columns: [APIColumn("ID", key: "storage", width: 130),
                                   APIColumn("Type", width: 170) { row in Self.types.first { $0.id == row.string("type") }?.name ?? row.string("type") ?? "" },
                                   APIColumn("Content", width: 260) { row in
                                       (row.string("content") ?? "").split(separator: ",").map { ContentType(rawValue: String($0))?.label ?? String($0) }.joined(separator: ", ")
                                   },
                                   APIColumn("Location", width: 210, monospaced: true) { row in
                                       if let path = row.text("path"), row.string("type") == "dir" { return path }
                                       if let server = row.text("server") { return (row.text("export") ?? row.text("share") ?? row.text("datastore")).map { "\(server):\($0)" } ?? server }
                                       if let pool = row.text("pool") { return pool }
                                       if let vg = row.text("vgname") { return row.text("thinpool").map { "\(vg)/\($0)" } ?? vg }
                                       return row.string("portal") ?? ""
                                   },
                                   APIColumn("Shared", width: 60) { $0.bool("shared") || ["nfs", "cifs", "pbs", "iscsi", "rbd", "cephfs"].contains($0.string("type") ?? "") ? "Yes" : "No" },
                                   APIColumn("Enabled", width: 70) { $0.bool("disable") ? "No" : "Yes" },
                                   APIColumn("Nodes", width: 140) { $0.string("nodes") ?? "All" }],
                         emptyTitle: "No storage configured", emptySymbol: "externaldrive", open: { editing = $0 }) { row in
                Button("Edit…") { editing = row }
                Button(row.json.bool("disable") ? "Enable" : "Disable") {
                    Task { await session.run(row.json.bool("disable") ? "Enable \(row.id)" : "Disable \(row.id)", .put, "/storage/\(row.id.enc)",
                                             ["disable": row.json.bool("disable") ? "0" : "1"]) }
                }
                Divider()
                Button("Remove…", role: .destructive) {
                    session.confirmDelete("Remove storage \(row.id)?", message: "Only the configuration is removed; data on the disk or server stays.", path: "/storage/\(row.id.enc)")
                }
            }
        }
        .sheet(item: Binding(get: { adding.map { StorageKind(type: $0) } }, set: { adding = $0?.type })) { kind in
            FormSheet(title: "Add \(Self.types.first { $0.id == kind.type }?.name ?? kind.type) storage", fields: Self.fields(for: kind.type, editing: false, session: session),
                      initial: Self.defaults(for: kind.type), submitTitle: "Add") { result in
                var params = result.changed
                params["type"] = kind.type
                if kind.type == "esxi" { params["content"] = "import" }
                for key in ["shared", "skip-cert-verification"] where params[key] == "0" { params[key] = nil }
                return await session.run("Add storage \(result["storage"])", .post, "/storage", params)
            }
        }
        .debugAction("add-nfs") { adding = "nfs" }
        .debugAction("add-lvmthin") { adding = "lvmthin" }
        .sheet(item: $editing) { row in
            let type = row["type"] ?? "dir"
            FormSheet(title: "Edit \(row.id)", fields: Self.fields(for: type, editing: true, session: session),
                      initial: row.json.mapValues { value in (value as? String) ?? jsonDouble(value).map { String(Int($0)) } ?? "\(value)" }
                        .merging(["disable": row.json.bool("disable") ? "0" : "1"]) { $1 },
                      isEdit: true) { result in
                var params = result.params
                if let enabled = result.changed["disable"] { params["disable"] = enabled == "1" ? "0" : "1" }
                return await session.run("Save storage \(row.id)", .put, "/storage/\(row.id.enc)", params)
            }
        }
    }

    private struct StorageKind: Identifiable {
        let type: String
        var id: String { type }
    }

    static func defaults(for type: String) -> [String: String] {
        switch type {
        case "dir": ["content": "iso,vztmpl,backup"]
        case "nfs", "cifs": ["content": "iso,vztmpl,backup"]
        case "pbs": ["content": "backup", "username": "root@pam"]
        case "esxi": ["username": "root"]
        default: ["content": "images,rootdir"]
        }
    }

    static func fields(for type: String, editing: Bool, session: Session? = nil) -> [FormField] {
        // Scans only help while adding; an existing storage's location is fixed.
        let scan = { (kind: String, value: String, needs: [String: String]) -> FormField.Kind in
            guard let session, !editing else { return .text }
            return .lookup { values in try await Self.scan(session, kind, value: value, needs: needs, values: values) }
        }
        var fields = [FormField(key: "storage", label: "ID", prompt: "e.g. nas-backup", required: true, lockedOnEdit: true)]
        switch type {
        case "dir":
            fields += [FormField(key: "path", label: "Directory", prompt: "/mnt/data", required: true, lockedOnEdit: true),
                       FormField(key: "shared", label: "Shared (same path on all nodes)", kind: .toggle)]
        case "lvm":
            fields += [FormField(key: "vgname", label: "Volume group", kind: scan("lvm", "vg", [:]), prompt: "pve", required: true, lockedOnEdit: true),
                       FormField(key: "shared", label: "Shared", kind: .toggle)]
        case "lvmthin":
            fields += [FormField(key: "vgname", label: "Volume group", kind: scan("lvm", "vg", [:]), prompt: "pve", required: true, lockedOnEdit: true),
                       FormField(key: "thinpool", label: "Thin pool", kind: scan("lvmthin", "lv", ["vg": "vgname"]), prompt: "data", required: true, lockedOnEdit: true)]
        case "zfspool":
            fields += [FormField(key: "pool", label: "ZFS pool", kind: scan("zfs", "pool", [:]), prompt: "tank/vmdata", required: true, lockedOnEdit: true),
                       FormField(key: "sparse", label: "Thin provision", kind: .toggle), FormField(key: "blocksize", label: "Block size", prompt: "16k")]
        case "nfs":
            fields += [FormField(key: "server", label: "Server", prompt: "192.168.1.20", required: true, lockedOnEdit: true),
                       FormField(key: "export", label: "Export", kind: scan("nfs", "path", ["server": "server"]), prompt: "/mnt/tank/pve", required: true, lockedOnEdit: true),
                       FormField(key: "options", label: "Mount options", prompt: "vers=4.2")]
        case "cifs":
            fields += [FormField(key: "server", label: "Server", prompt: "nas.home.lan", required: true, lockedOnEdit: true),
                       FormField(key: "username", label: "Username"), FormField(key: "password", label: "Password", kind: .secure),
                       FormField(key: "domain", label: "Domain"),
                       FormField(key: "share", label: "Share", kind: scan("cifs", "share", ["server": "server", "username": "username", "password": "password", "domain": "domain"]),
                                 prompt: "proxmox", required: true, lockedOnEdit: true)]
        case "pbs":
            fields += [FormField(key: "server", label: "Server", prompt: "pbs.home.lan", required: true),
                       FormField(key: "username", label: "Username", prompt: "backup@pbs", required: true),
                       FormField(key: "password", label: "Password or token secret", kind: .secure),
                       FormField(key: "fingerprint", label: "Fingerprint", prompt: "For self-signed certificates"),
                       FormField(key: "datastore", label: "Datastore",
                                 kind: scan("pbs", "store", ["server": "server", "username": "username", "password": "password", "fingerprint": "fingerprint"]),
                                 prompt: "store1", required: true),
                       FormField(key: "namespace", label: "Namespace")]
        case "esxi":
            fields += [FormField(key: "server", label: "ESXi or vCenter", prompt: "esxi.home.lan", required: true, lockedOnEdit: true),
                       FormField(key: "username", label: "Username", prompt: "root", required: true),
                       FormField(key: "password", label: "Password", kind: .secure, required: !editing),
                       FormField(key: "skip-cert-verification", label: "Skip certificate check", kind: .toggle, help: "For hosts with a self-signed certificate")]
        case "iscsi":
            fields += [FormField(key: "portal", label: "Portal", prompt: "192.168.1.30", required: true, lockedOnEdit: true),
                       FormField(key: "target", label: "Target", kind: scan("iscsi", "target", ["portal": "portal"]), prompt: "iqn.2005-10.org.freenas.ctl:pve",
                                 required: true, lockedOnEdit: true)]
        default: break
        }
        if !["iscsi", "esxi"].contains(type) { fields.append(FormField(key: "content", label: "Content", kind: .multiChoice(contents))) }
        fields.append(FormField(key: "nodes", label: "Nodes", prompt: "All, or pve1,pve2"))
        if editing { fields.append(FormField(key: "disable", label: "Enabled", kind: .toggle)) }
        if ["dir", "nfs", "cifs", "pbs"].contains(type) {
            fields.append(FormField(key: "prune-backups", label: "Backup retention", prompt: "keep-last=3,keep-weekly=4"))
        }
        return fields
    }

    /// Asks a node what it can reach, like the web UI's storage dialogs: an NFS server's exports, an SMB server's shares,
    /// a backup server's datastores, an iSCSI portal's targets, or the node's own volume groups, thin pools and ZFS pools.
    /// `needs` maps the scan's parameters to the form fields they come from; the first one is required.
    private static func scan(_ session: Session, _ kind: String, value: String, needs: [String: String], values: [String: String]) async throws -> [FormField.Choice] {
        var query: [String: String] = [:]
        for (param, key) in needs {
            if let entered = values[key]?.trimmingCharacters(in: .whitespaces), !entered.isEmpty { query[param] = entered }
        }
        if let first = ["server", "portal", "vg"].first(where: { needs[$0] != nil }), query[first] == nil {
            throw LookupNeeds(message: first == "vg" ? "Enter the volume group first." : "Enter the \(first) first.")
        }
        if kind == "pbs", query["password"] == nil { throw LookupNeeds(message: "Enter the password first.") }
        // Local scans run on a node the storage is for, else on any online node (the web UI uses the node it's connected to).
        let node = values["nodes"]?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? session.onlineNodes.first ?? ""
        return try await session.client.list("/nodes/\(node.enc)/scan/\(kind)", query).compactMap { item in
            guard let found = item.text(value) else { return nil }
            let detail = item.text("description") ?? item.text("comment") ?? (kind == "nfs" ? item.text("options").map { "for \($0)" } : nil)
            return FormField.Choice(found, detail.map { "\(found)  —  \($0)" })
        }
    }
}

// MARK: SDN

struct SDNView: View {
    @Environment(Session.self) private var session
    @State private var section = "zones"
    @State private var editing: SDNEdit?
    @State private var vnet: String?
    @State private var firewall: String?
    @State private var ipam: String?
    @State private var reviewing = false

    var body: some View {
        AdminPage(title: "SDN", subtitle: "Software-defined networks across the cluster", symbol: "point.3.connected.trianglepath.dotted", colors: [.indigo, .cyan]) {
            Button("Review Changes…", systemImage: "doc.text.magnifyingglass") { reviewing = true }
            Button("Apply Changes", systemImage: "checkmark.circle") {
                session.confirmation = Confirmation(title: "Apply SDN changes?", message: "Pending zone and VNet changes are written to every node's network configuration.",
                                                    actionTitle: "Apply", destructive: false) {
                    await session.run("Apply SDN changes", .put, "/cluster/sdn")
                }
            }
        } content: {
            TabStrip(tabs: [PageTab(id: "zones", title: "Zones", symbol: "square.dashed"),
                            PageTab(id: "vnets", title: "VNets", symbol: "network"),
                            PageTab(id: "subnets", title: "Subnets", symbol: "number"),
                            PageTab(id: "fabrics", title: "Fabrics", symbol: "point.3.connected.trianglepath.dotted"),
                            PageTab(id: "controllers", title: "Controllers", symbol: "point.3.filled.connected.trianglepath.dotted"),
                            PageTab(id: "ipams", title: "IPAM", symbol: "list.number"),
                            PageTab(id: "dns", title: "DNS", symbol: "globe"),
                            PageTab(id: "prefixlists", title: "Prefix Lists", symbol: "line.3.horizontal.decrease"),
                            PageTab(id: "routemaps", title: "Route Maps", symbol: "arrow.triangle.branch")], selection: $section)
                .padding(.bottom, 6)
            if !["prefixlists", "routemaps"].contains(section) {
                HStack {
                    if let types = Self.addTypes[section] {
                        Menu(Self.addTitles[section] ?? "Add", systemImage: "plus") {
                            ForEach(types, id: \.self) { type in Button("\(Self.typeNames[type] ?? type)…") { editing = SDNEdit(kind: section, type: type) } }
                        }
                        .fixedSize()
                    } else {
                        Button(Self.addTitles[section] ?? "Add", systemImage: "plus") { editing = SDNEdit(kind: section, vnet: vnet) }
                            .disabled(section == "subnets" && vnet == nil)
                    }
                    if section == "subnets" {
                        SDNVnetPicker(vnet: $vnet)
                    }
                    Spacer()
                }
                .buttonStyle(.glass)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            switch section {
            case "vnets":
                ResourceList(path: "/cluster/sdn/vnets", id: { $0.string("vnet") ?? "" },
                             columns: [APIColumn("VNet", key: "vnet", width: 120), APIColumn("Zone", key: "zone", width: 120), APIColumn("Tag", key: "tag", width: 70),
                                       APIColumn("Alias", key: "alias", width: 200), APIColumn("Pending", width: 80) { $0["pending"] != nil ? "Yes" : "" }],
                             emptyTitle: "No VNets", emptySymbol: "network", open: { edit($0) }) { row in
                    Button("Edit…") { edit(row) }
                    Button("Subnets") { vnet = row.id; section = "subnets" }
                    Button("Firewall…") { firewall = row.id }
                    Divider()
                    Button("Delete…", role: .destructive) { session.confirmDelete("Delete VNet \(row.id)?", path: "/cluster/sdn/vnets/\(row.id.enc)") }
                }
            case "subnets":
                if let vnet {
                    ResourceList(path: "/cluster/sdn/vnets/\(vnet.enc)/subnets", id: { $0.string("subnet") ?? $0.string("cidr") ?? "" },
                                 columns: [APIColumn("Subnet", width: 180, monospaced: true) { $0.string("cidr") ?? $0.string("subnet") ?? "" },
                                           APIColumn("Gateway", key: "gateway", width: 140, monospaced: true), APIColumn("SNAT", width: 60) { $0.bool("snat") ? "Yes" : "" },
                                           APIColumn("DHCP ranges", width: 260, monospaced: true) { row in
                                               row.objects("dhcp-range").map { "\($0.string("start-address") ?? "")–\($0.string("end-address") ?? "")" }.joined(separator: ", ")
                                           }],
                                 emptyTitle: "No subnets", emptySymbol: "number", open: { edit($0) }) { row in
                        Button("Edit…") { edit(row) }
                        Divider()
                        Button("Delete…", role: .destructive) { session.confirmDelete("Delete subnet \(row.id)?", path: "/cluster/sdn/vnets/\(vnet.enc)/subnets/\(row.id.enc)") }
                    }
                    .id(vnet)
                } else {
                    ContentUnavailableView("Pick a VNet", systemImage: "network")
                }
            case "fabrics":
                SDNFabrics()
            case "controllers":
                ResourceList(path: "/cluster/sdn/controllers", id: { $0.string("controller") ?? "" },
                             columns: [APIColumn("Controller", key: "controller", width: 130), APIColumn("Type", width: 80) { Self.typeNames[$0.string("type") ?? ""] ?? ($0.string("type") ?? "") }, APIColumn("ASN", key: "asn", width: 90),
                                       APIColumn("Peers", key: "peers", width: 220), APIColumn("Node", key: "node", width: 100),
                                       APIColumn("Pending", width: 80) { $0["pending"] != nil ? "Yes" : "" }],
                             emptyTitle: "No controllers", emptySymbol: "point.3.filled.connected.trianglepath.dotted",
                             emptyMessage: "EVPN zones need an EVPN controller; BGP and IS-IS controllers advertise routes to your network.", open: { edit($0) }) { row in
                    Button("Edit…") { edit(row) }
                    Divider()
                    Button("Delete…", role: .destructive) { session.confirmDelete("Delete controller \(row.id)?", path: "/cluster/sdn/controllers/\(row.id.enc)") }
                }
            case "ipams":
                ResourceList(path: "/cluster/sdn/ipams", id: { $0.string("ipam") ?? "" },
                             columns: [APIColumn("IPAM", key: "ipam", width: 130), APIColumn("Type", width: 90) { Self.typeNames[$0.string("type") ?? ""] ?? ($0.string("type") ?? "") }, APIColumn("URL", key: "url", width: 280), APIColumn("Section", key: "section", width: 80)],
                             emptyTitle: "No IPAM", emptySymbol: "list.number",
                             emptyMessage: "Track the addresses VNets hand out, in Proxmox itself, NetBox or phpIPAM.",
                             open: { row in if row["type"] == "pve" { ipam = row.id } else { edit(row) } }) { row in
                    if row["type"] == "pve" {
                        Button("Show Addresses…") { ipam = row.id }
                    } else {
                        Button("Edit…") { edit(row) }
                        Divider()
                        Button("Delete…", role: .destructive) { session.confirmDelete("Delete IPAM \(row.id)?", path: "/cluster/sdn/ipams/\(row.id.enc)") }
                    }
                }
            case "dns":
                ResourceList(path: "/cluster/sdn/dns", id: { $0.string("dns") ?? "" },
                             columns: [APIColumn("DNS", key: "dns", width: 130), APIColumn("Type", width: 90) { Self.typeNames[$0.string("type") ?? ""] ?? ($0.string("type") ?? "") }, APIColumn("URL", key: "url", width: 280), APIColumn("TTL", key: "ttl", width: 70)],
                             emptyTitle: "No DNS servers", emptySymbol: "globe", emptyMessage: "Register guest names in PowerDNS as they get addresses.", open: { edit($0) }) { row in
                    Button("Edit…") { edit(row) }
                    Divider()
                    Button("Delete…", role: .destructive) { session.confirmDelete("Delete DNS server \(row.id)?", path: "/cluster/sdn/dns/\(row.id.enc)") }
                }
            case "prefixlists":
                SDNPrefixLists()
            case "routemaps":
                SDNRouteMaps()
            default:
                ResourceList(path: "/cluster/sdn/zones", id: { $0.string("zone") ?? "" },
                             columns: [APIColumn("Zone", key: "zone", width: 120), APIColumn("Type", width: 90) { Self.typeNames[$0.string("type") ?? ""] ?? ($0.string("type") ?? "") }, APIColumn("Bridge", key: "bridge", width: 100),
                                       APIColumn("Peers", key: "peers", width: 200), APIColumn("MTU", key: "mtu", width: 60), APIColumn("Nodes", key: "nodes", width: 140),
                                       APIColumn("Pending", width: 80) { $0["pending"] != nil ? "Yes" : "" }],
                             emptyTitle: "No zones", emptySymbol: "square.dashed",
                             emptyMessage: "A zone defines how VNets are separated: plain bridge, VLAN, QinQ, VXLAN or EVPN.", open: { edit($0) }) { row in
                    Button("Edit…") { edit(row) }
                    Divider()
                    Button("Delete…", role: .destructive) { session.confirmDelete("Delete zone \(row.id)?", path: "/cluster/sdn/zones/\(row.id.enc)") }
                }
            }
        }
        .sheet(item: $editing) { edit in
            if edit.kind == "fabrics" { FabricEditor(row: nil) } else { SDNObjectEditor(edit: edit) }
        }
        .sheet(item: Binding(get: { firewall.map { SDNName(name: $0) } }, set: { firewall = $0?.name })) { SDNVNetFirewallSheet(vnet: $0.name) }
        .sheet(item: Binding(get: { ipam.map { SDNName(name: $0) } }, set: { ipam = $0?.name })) { SDNIPAMSheet(ipam: $0.name) }
        .sheet(isPresented: $reviewing) { SDNDryRunSheet() }
        .debugAction("edit-zone") { editing = SDNEdit(kind: "zones", row: Row(id: "lab", json: ["zone": "lab", "type": "simple"])) }
        .debugAction("sdn-firewall") { firewall = "labnet" }
        .debugAction("sdn-ipam") { ipam = "pve" }
        .debugAction("sdn-review") { reviewing = true }
    }

    private func edit(_ row: Row) {
        editing = SDNEdit(kind: section, row: row, vnet: section == "subnets" ? vnet : nil)
    }

    static let typeNames = ["simple": "Simple", "vlan": "VLAN", "qinq": "QinQ", "vxlan": "VXLAN", "evpn": "EVPN", "bgp": "BGP", "isis": "IS-IS",
                            "faucet": "Faucet", "pve": "Proxmox", "netbox": "NetBox", "phpipam": "phpIPAM", "powerdns": "PowerDNS"]

    private static let addTitles = ["zones": "Add Zone", "vnets": "Add VNet", "subnets": "Add Subnet", "fabrics": "Add Fabric", "controllers": "Add Controller", "ipams": "Add IPAM", "dns": "Add DNS Server"]
    private static let addTypes = ["zones": ["simple", "vlan", "qinq", "vxlan", "evpn"], "controllers": ["evpn", "bgp", "isis"], "ipams": ["netbox", "phpipam"]]

    private struct SDNName: Identifiable {
        let name: String
        var id: String { name }
    }
}

private struct SDNVnetPicker: View {
    @Environment(Session.self) private var session
    @Binding var vnet: String?
    @State private var vnets: [String] = []

    var body: some View {
        Picker("VNet", selection: $vnet) {
            Text("Choose a VNet").tag(String?.none)
            ForEach(vnets, id: \.self) { Text($0).tag(String?.some($0)) }
        }
        .fixedSize()
        .task(id: session.revision) {
            vnets = ((try? await session.client.list("/cluster/sdn/vnets")) ?? []).compactMap { $0.text("vnet") }
            if vnet == nil { vnet = vnets.first }
        }
    }
}

// MARK: Pools

struct PoolView: View {
    @Environment(Session.self) private var session
    let poolid: String
    @State private var comment = ""
    @State private var members: [Row] = []
    @State private var tab = "members"
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            Hero(title: poolid, subtitle: comment.isEmpty ? "Resource pool" : comment, symbol: "tray.2", colors: [.purple, .indigo]) {
                Pill(text: Format.count(members.filter { $0["type"] != "storage" }.count, "guest"), systemImage: "square.stack.3d.up")
                // A shared storage is listed once per node; count it once.
                Pill(text: Format.count(Set(members.filter { $0["type"] == "storage" }.compactMap { $0["storage"] }).count, "storage"), systemImage: "externaldrive")
            } trailing: {
                Button("Add Members", systemImage: "plus") { adding = true }.buttonStyle(.glass).controlSize(.large)
            }
            TabStrip(tabs: [PageTab(id: "members", title: "Members", symbol: "square.stack.3d.up"),
                            PageTab(id: "permissions", title: "Permissions", symbol: "person.2")], selection: $tab)
                .padding(.bottom, 6)
            if tab == "permissions" {
                PermissionsList(path: "/pool/\(poolid)")
            } else {
                Table(members) {
                    TableColumn("Type") { row in Label(row["type"] == "storage" ? "Storage" : (row["type"] == "lxc" ? "Container" : "VM"),
                                                       systemImage: row["type"] == "storage" ? "externaldrive" : (row["type"] == "lxc" ? "shippingbox" : "desktopcomputer")) }
                        .width(110)
                    TableColumn("ID") { row in Text(row["vmid"] ?? row["storage"] ?? "").monospacedDigit() }.width(80)
                    TableColumn("Name") { row in Text(row["name"] ?? row["storage"] ?? "") }.width(min: 120, ideal: 200)
                    TableColumn("Node") { row in Text(row["node"] ?? "").foregroundStyle(.secondary) }.width(90)
                    TableColumn("Status") { row in Text(row["status"] ?? "").foregroundStyle(.secondary) }.width(90)
                }
                .contextMenu(forSelectionType: Row.ID.self) { ids in
                    if let row = members.first(where: { ids.contains($0.id) }) {
                        Button("Remove from Pool") {
                            let key = row["type"] == "storage" ? "storage" : "vms"
                            Task { await session.run("Remove from \(poolid)", .put, "/pools/\(poolid.enc)", [key: row["vmid"] ?? row["storage"] ?? "", "delete": "1"]) }
                        }
                    }
                } primaryAction: { ids in
                    if let row = members.first(where: { ids.contains($0.id) }), let vmid = Int(row["vmid"] ?? "") { session.selection = .guest(vmid) }
                }
            }
        }
        .task(id: "\(poolid)-\(session.revision)") {
            guard let detail = try? await session.client.object("/pools/\(poolid.enc)") else { return }
            comment = detail.string("comment") ?? ""
            members = detail.objects("members").map { Row(id: $0.string("id") ?? UUID().uuidString, json: $0) }
        }
        .sheet(isPresented: $adding) {
            FormSheet(title: "Add to \(poolid)", fields: [
                FormField(key: "vms", label: "Guests", kind: .multiChoice(session.guests.filter { $0.pool.isEmpty }.map { FormField.Choice(String($0.vmid), "\($0.vmid) \($0.displayName)") })),
                FormField(key: "storage", label: "Storage", prompt: "e.g. local,nas-backup"),
            ], submitTitle: "Add") { result in
                await session.run("Add members to \(poolid)", .put, "/pools/\(poolid.enc)", result.changed)
            }
        }
    }
}

// MARK: Datacenter options

struct DatacenterOptionsView: View {
    @Environment(Session.self) private var session
    @State private var section = "notes"

    var body: some View {
        AdminPage(title: "Options", subtitle: "Notes, cluster settings, metrics, notifications and more", symbol: "gearshape", colors: [.gray, .blue]) {
            EmptyView()
        } content: {
            TabStrip(tabs: [PageTab(id: "notes", title: "Notes", symbol: "note.text"),
                            PageTab(id: "options", title: "Options", symbol: "slider.horizontal.3"),
                            PageTab(id: "cluster", title: "Cluster", symbol: "server.rack"),
                            PageTab(id: "metrics", title: "Metric Servers", symbol: "chart.xyaxis.line"),
                            PageTab(id: "notifications", title: "Notifications", symbol: "bell"),
                            PageTab(id: "acme", title: "ACME", symbol: "checkmark.seal"),
                            PageTab(id: "mappings", title: "Mappings", symbol: "rectangle.connected.to.line.below"),
                            PageTab(id: "cpumodels", title: "CPU Models", symbol: "cpu"),
                            PageTab(id: "support", title: "Subscriptions", symbol: "key")], selection: $section)
                .padding(.bottom, 6)
            switch section {
            case "options": ClusterOptions()
            case "cluster": ClusterSection()
            case "metrics": MetricServers()
            case "notifications": NotificationsSection()
            case "acme": ACMESection()
            case "mappings": MappingsSection()
            case "cpumodels": CustomCPUModels()
            case "support": Subscriptions()
            default: ClusterNotes()
            }
        }
    }
}

private struct ClusterNotes: View {
    @Environment(Session.self) private var session
    @State private var notes = ""
    @State private var editing = false

    var body: some View {
        Page {
            Card(title: "Datacenter notes", systemImage: "note.text") {
                if notes.isEmpty {
                    Text("No notes yet. Keep the things everyone should know here: IP plan, who to call, maintenance windows.").foregroundStyle(.secondary)
                } else {
                    MarkdownText(source: notes)
                }
            } accessory: {
                Button("Edit") { editing = true }.buttonStyle(.link)
            }
        }
        .task(id: session.revision) { notes = (try? await session.client.object("/cluster/options"))?.string("description") ?? "" }
        .sheet(isPresented: $editing) {
            NotesEditor(title: "Datacenter notes", text: notes) { text in
                await session.run("Save the notes", .put, "/cluster/options", text.isEmpty ? ["delete": "description"] : ["description": text])
            }
        }
    }
}

private struct ClusterOptions: View {
    @Environment(Session.self) private var session
    @State private var options: JSONObject = [:]
    @State private var editing: String?

    private static let known: [(key: String, title: String, prompt: String)] = [
        ("keyboard", "Keyboard layout", "en-us"), ("console", "Console viewer", ""),
        ("email_from", "Email from", "root@pve.home.lan"), ("http_proxy", "HTTP proxy", "http://proxy:3128"),
        ("mac_prefix", "MAC address prefix", "BC:24:11"), ("max_workers", "Maximum workers", "4"),
        ("migration", "Migration settings", "type=secure,network=10.0.0.0/24"), ("bwlimit", "Bandwidth limits", "default=0"),
        ("ha", "HA settings", "shutdown_policy=conditional"), ("crs", "Cluster resource scheduling", "ha=basic"),
        ("next-id", "Next free VMID range", "lower=100,upper=1000000"), ("tag-style", "Tag style", "shape=full,ordering=config"),
        ("user-tag-access", "User tag access", "user-allow=free"), ("registered-tags", "Registered tags", "prod;dev"),
        ("language", "Language", "en"), ("fencing", "Fencing", "watchdog"),
        ("webauthn", "WebAuthn settings", "rp=pve.home.lan,origin=https://pve.home.lan:8006,id=pve.home.lan"),
        ("consent-text", "Login consent text", "Shown before signing in"),
    ]

    /// Options with a fixed set of values get a picker, labelled like the web UI.
    private static let choices: [String: [FormField.Choice]] = [
        "console": [.init("xtermjs", "xterm.js"), .init("html5", "noVNC"), .init("vv", "SPICE (Remote Viewer)")],
        "keyboard": ["da", "de", "de-ch", "en-gb", "en-us", "es", "fi", "fr", "fr-be", "fr-ca", "fr-ch", "hu", "is", "it", "ja", "lt", "mk",
                     "nl", "no", "pl", "pt", "pt-br", "sl", "sv", "tr"].map { FormField.Choice($0) },
        "fencing": [.init("watchdog", "Watchdog"), .init("hardware", "Hardware"), .init("both", "Both")],
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.known, id: \.key) { option in
                    LabeledContent(option.title) {
                        HStack {
                            let value = options.string(option.key)
                            Text(value.map { value in Self.choices[option.key]?.first { $0.value == value }?.label ?? value } ?? "Default")
                                .foregroundStyle(value == nil ? .tertiary : .secondary).lineLimit(1)
                            Button("Edit") { editing = option.key }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: session.revision) { options = (try? await session.client.object("/cluster/options")) ?? [:] }
        .sheet(item: Binding(get: { editing.map { OptionKey(key: $0) } }, set: { editing = $0?.key })) { option in
            let info = Self.known.first { $0.key == option.key }
            FormSheet(title: info?.title ?? option.key, message: "Leave empty to use the default.",
                      fields: [FormField(key: option.key, label: info?.title ?? option.key, kind: Self.choices[option.key].map { .choice($0) } ?? .text,
                                         prompt: Self.choices[option.key] == nil ? info?.prompt ?? "" : "Default")],
                      initial: [option.key: options.string(option.key) ?? ""], isEdit: true) { result in
                await session.run("Save \(info?.title.lowercased() ?? option.key)", .put, "/cluster/options", result.params)
            }
        }
    }

    private struct OptionKey: Identifiable {
        let key: String
        var id: String { key }
    }
}

private struct MetricServers: View {
    @Environment(Session.self) private var session
    @State private var adding: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu("Add", systemImage: "plus") {
                    Button("InfluxDB…") { adding = "influxdb" }
                    Button("Graphite…") { adding = "graphite" }
                }
                .fixedSize()
                Spacer()
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            ResourceList(path: "/cluster/metrics/server", id: { $0.string("id") ?? "" },
                         columns: [APIColumn("Name", key: "id", width: 140), APIColumn("Type", width: 90) { ["influxdb": "InfluxDB", "graphite": "Graphite", "opentelemetry": "OpenTelemetry"][$0.string("type") ?? ""] ?? ($0.string("type") ?? "") },
                                   APIColumn("Server", key: "server", width: 180),
                                   APIColumn("Port", key: "port", width: 60), APIColumn("Enabled", width: 60) { $0.bool("disable") ? "No" : "Yes" }],
                         emptyTitle: "No metric servers", emptySymbol: "chart.xyaxis.line",
                         emptyMessage: "Send node and guest metrics to InfluxDB or Graphite for long-term dashboards.") { row in
                Button("Delete…", role: .destructive) { session.confirmDelete("Delete metric server \(row.id)?", path: "/cluster/metrics/server/\(row.id.enc)") }
            }
        }
        .sheet(item: Binding(get: { adding.map { MetricKind(type: $0) } }, set: { adding = $0?.type })) { kind in
            FormSheet(title: "Add \(kind.type == "influxdb" ? "InfluxDB" : "Graphite") server", fields: [
                FormField(key: "id", label: "Name", required: true), FormField(key: "server", label: "Server", required: true),
                FormField(key: "port", label: "Port", kind: .number, prompt: kind.type == "influxdb" ? "8089" : "2003", required: true),
                FormField(key: "influxdbproto", label: "Protocol (InfluxDB)", kind: .choice([.init("udp", "UDP"), .init("http", "HTTP"), .init("https", "HTTPS")])),
                FormField(key: "organization", label: "Organization (InfluxDB 2)"), FormField(key: "bucket", label: "Bucket (InfluxDB 2)"),
                FormField(key: "token", label: "Token (InfluxDB 2)", kind: .secure),
            ], initial: ["port": kind.type == "influxdb" ? "8089" : "2003"], submitTitle: "Add") { result in
                var params = result.changed
                params["type"] = kind.type
                let id = params.removeValue(forKey: "id") ?? ""
                return await session.run("Add metric server \(id)", .post, "/cluster/metrics/server/\(id.enc)", params)
            }
        }
    }

    private struct MetricKind: Identifiable {
        let type: String
        var id: String { type }
    }
}

private struct Subscriptions: View {
    @Environment(Session.self) private var session
    @State private var rows: [(String, JSONObject)] = []

    var body: some View {
        Page {
            ForEach(rows, id: \.0) { node, info in
                Card(title: node, systemImage: "key") {
                    InfoGrid(rows: [("Status", Format.subscription(info.string("status"))),
                                    ("Level", info.string("level") ?? "–"), ("Product", info.string("productname") ?? "–"),
                                    ("Next due", info.string("nextduedate") ?? "–"), ("Message", info.string("message") ?? "")])
                }
            }
        }
        .task {
            var result: [(String, JSONObject)] = []
            for node in session.onlineNodes {
                result.append((node, (try? await session.client.object("/nodes/\(node.enc)/subscription")) ?? [:]))
            }
            rows = result
        }
    }
}
