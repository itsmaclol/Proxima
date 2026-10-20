import AppKit
import SwiftUI

/// A node: header, section tabs and the selected section.
struct NodeView: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    let name: String
    @State private var status: NodeStatus?

    private var path: String { "/nodes/\(name.enc)" }

    static let tabs = [
        PageTab(id: "summary", title: "Summary", symbol: "gauge.with.dots.needle.33percent"),
        PageTab(id: "shell", title: "Shell", symbol: "terminal"),
        PageTab(id: "system", title: "System", symbol: "gearshape.2"),
        PageTab(id: "network", title: "Network", symbol: "network"),
        PageTab(id: "sdn", title: "SDN", symbol: "point.3.connected.trianglepath.dotted"),
        PageTab(id: "disks", title: "Disks", symbol: "internaldrive"),
        PageTab(id: "services", title: "Services", symbol: "switch.2"),
        PageTab(id: "updates", title: "Updates", symbol: "arrow.down.circle"),
        PageTab(id: "syslog", title: "System Log", symbol: "doc.text.magnifyingglass"),
        PageTab(id: "firewall", title: "Firewall", symbol: "shield.lefthalf.filled"),
        PageTab(id: "ceph", title: "Ceph", symbol: "circle.hexagongrid"),
        PageTab(id: "tasks", title: "Tasks", symbol: "list.bullet.rectangle.portrait"),
        PageTab(id: "permissions", title: "Permissions", symbol: "person.2"),
    ]

    var body: some View {
        @Bindable var session = session
        let node = session.node(name)
        let online = node?.isOnline ?? false
        VStack(spacing: 0) {
            Hero(title: name, subtitle: status.map { "Proxmox VE \($0.pveVersion), \($0.kernel)" } ?? (online ? "Node" : "Node is offline"),
                 symbol: "server.rack", colors: online ? [.blue, .indigo] : [.red, .orange]) {
                StatusBadgeNode(online: online)
                if online, let node { Pill(text: "Up \(Format.duration(status?.uptime ?? node.uptime))", systemImage: "clock") }
                Pill(text: "\(session.guests(on: name).filter { $0.power == .running }.count) of \(Format.count(session.guests(on: name).count, "guest")) running", systemImage: "square.stack.3d.up")
            } trailing: {
                if online, let status {
                    HStack(spacing: 14) {
                        ring("CPU", status.cpu, Theme.cpu)
                        ring("Memory", status.memTotal > 0 ? Double(status.memUsed) / Double(status.memTotal) : 0, Theme.memory)
                        ring("Root disk", status.rootTotal > 0 ? Double(status.rootUsed) / Double(status.rootTotal) : 0, Theme.disk)
                    }
                }
            }
            TabStrip(tabs: Self.tabs, selection: $session.nodeTab)
                .padding(.bottom, 6)
            Group {
                if !online && !["summary", "tasks", "permissions"].contains(session.nodeTab) {
                    ContentUnavailableView("\(name) is offline", systemImage: "bolt.horizontal.circle", description: Text("Bring the node back online to manage it."))
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Shell Window", systemImage: "macwindow") { openWindow(id: "console", value: ConsoleTarget(kind: "shell", node: name, vmid: nil, name: name)) }
                    Button("SPICE in Remote Viewer", systemImage: "display") { Task { await session.openSPICE("/nodes/\(name.enc)/spiceshell", name: name) } }
                } label: {
                    Label("Shell", systemImage: "terminal")
                } primaryAction: {
                    openWindow(id: "console", value: ConsoleTarget(kind: "shell", node: name, vmid: nil, name: name))
                }
                .help("Open a shell on \(name) in its own window")
                Menu("Node", systemImage: "power") { NodeMenuItems(session: session, node: name) }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Menu("Create", systemImage: "plus") {
                    Button("New Virtual Machine…") { session.sheet = .createVM(node: name) }
                    Button("New Container…") { session.sheet = .createCT(node: name) }
                }
            }
        }
        .polling(id: "\(name)-\(online)", every: .seconds(4)) {
            guard online, let object = try? await session.client.object(path + "/status") else { return }
            status = NodeStatus(object)
        }
    }

    @ViewBuilder private var content: some View {
        switch session.nodeTab {
        case "shell": ConsoleView(target: ConsoleTarget(kind: "shell", node: name, vmid: nil, name: name)).id(name)
        case "system": NodeSystemView(node: name)
        case "network": NodeNetworkView(node: name)
        case "sdn": NodeSDNView(node: name)
        case "disks": NodeDisksView(node: name)
        case "services": NodeServicesView(node: name)
        case "updates": NodeUpdatesView(node: name)
        case "syslog": NodeSyslogView(node: name)
        case "firewall": FirewallView(scope: .node(name))
        case "ceph": CephView(node: name)
        case "tasks": TaskHistory(node: name)
        case "permissions": PermissionsList(path: "/nodes/\(name)")
        default: NodeSummary(node: name, status: status)
        }
    }

    private func ring(_ title: String, _ fraction: Double, _ color: Color) -> some View {
        VStack(spacing: 4) {
            MetricRing(fraction: fraction, color: color, lineWidth: 6).frame(width: 58, height: 58)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StatusBadgeNode: View {
    let online: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(online ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(online ? "Online" : "Offline")
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background((online ? Color.green : Color.red).opacity(0.14), in: .capsule)
        .foregroundStyle(online ? Color.green : Color.red)
    }
}

// MARK: Summary

private struct NodeSummary: View {
    @Environment(Session.self) private var session
    let node: String
    let status: NodeStatus?
    @AppStorage("chart.timeframe") private var timeframe = Timeframe.hour
    @AppStorage("chart.maximum") private var maximum = false
    @State private var samples: [RRDPoint] = []
    @State private var notes = ""
    @State private var editingNotes = false
    @State private var showingVersions = false

    var body: some View {
        Page {
            HStack(alignment: .top, spacing: 18) {
                Card(title: "Status", systemImage: "info.circle") {
                    if let status {
                        InfoGrid(rows: [
                            ("CPU usage", "\(Format.percent(status.cpu)) of \(status.cpus) CPUs"),
                            ("IO delay", Format.percent(status.ioWait)),
                            ("Load average", status.loadavg.map { String(format: "%.2f", $0) }.joined(separator: ", ")),
                            ("Memory", "\(Format.bytes(status.memUsed)) of \(Format.bytes(status.memTotal))"),
                            ("Swap", "\(Format.bytes(status.swapUsed)) of \(Format.bytes(status.swapTotal))"),
                            ("Root disk", "\(Format.bytes(status.rootUsed)) of \(Format.bytes(status.rootTotal))"),
                            ("KSM sharing", Format.bytes(status.ksmShared)),
                            ("CPU", "\(status.cpus) × \(status.cpuModel) (\(status.sockets) socket\(status.sockets == 1 ? "" : "s"))"),
                            ("Kernel", status.kernel), ("Boot mode", status.bootMode), ("Manager version", status.pveVersion),
                        ])
                    } else {
                        Text(session.node(node)?.isOnline == false ? "\(node) is offline, so there's no live status." : "Loading status…").foregroundStyle(.secondary)
                    }
                } accessory: {
                    Button("Package Versions") { showingVersions = true }.buttonStyle(.link)
                }
                .frame(maxWidth: .infinity)
                .sheet(isPresented: $showingVersions) { PackageVersionsSheet(node: node) }
                .debugAction("package-versions") { showingVersions = true }
                Card(title: "Notes", systemImage: "note.text") {
                    if notes.isEmpty {
                        Text("No notes yet. Record the hardware, location or anything unusual about this node.").foregroundStyle(.secondary)
                    } else {
                        MarkdownText(source: notes)
                    }
                } accessory: {
                    Button("Edit") { editingNotes = true }.buttonStyle(.link)
                }
                .frame(maxWidth: .infinity)
            }
            HStack {
                Text("Performance").font(.title3.weight(.semibold))
                Spacer()
                TimeframePicker(timeframe: $timeframe, useMaximum: $maximum)
            }
            .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                MetricChart(title: "CPU", series: [ChartSeries("Usage", color: Theme.cpu, from: samples) { $0["cpu"] },
                                                   ChartSeries("IO delay", color: .red, from: samples) { $0["iowait"] }],
                            unit: .percent, ceiling: 1, timeframe: timeframe)
                MetricChart(title: "Server load", series: [ChartSeries("Load", color: .blue, from: samples) { $0["loadavg"] }],
                            unit: .number, timeframe: timeframe)
                MetricChart(title: "Memory", series: [ChartSeries("Used", color: Theme.memory, from: samples) { $0["memused"] },
                                                      ChartSeries("Swap", color: .pink, from: samples) { $0["swapused"] }],
                            unit: .bytes, ceiling: samples.compactMap { $0["memtotal"] }.max(), timeframe: timeframe)
                MetricChart(title: "Network", series: [ChartSeries("In", color: Theme.netIn, from: samples) { $0["netin"] },
                                                       ChartSeries("Out", color: Theme.netOut, from: samples) { $0["netout"] }],
                            unit: .rate, timeframe: timeframe)
            }
        }
        .polling(id: "\(node)-\(timeframe)-\(maximum)", every: .seconds(timeframe == .hour ? 30 : 300)) {
            if let list = try? await session.client.list("/nodes/\(node.enc)/rrddata", ["timeframe": timeframe.rawValue, "cf": maximum ? "MAX" : "AVERAGE"]) {
                samples = list.map(RRDPoint.init)
            }
        }
        .task(id: "\(node)-\(session.revision)") { notes = (try? await session.client.object("/nodes/\(node.enc)/config"))?.string("description") ?? "" }
        .sheet(isPresented: $editingNotes) {
            NotesEditor(title: "Notes for \(node)", text: notes) { text in
                await session.run("Save the notes", .put, "/nodes/\(node.enc)/config", text.isEmpty ? ["delete": "description"] : ["description": text])
            }
        }
    }
}

// MARK: System

private struct NodeSystemView: View {
    @Environment(Session.self) private var session
    let node: String
    @State private var dns: JSONObject = [:]
    @State private var hosts = ""
    @State private var hostsDigest = ""
    @State private var time: JSONObject = [:]
    @State private var subscription: JSONObject = [:]
    @State private var options: JSONObject = [:]
    @State private var editingDNS = false
    @State private var editingHosts = false
    @State private var editingTimezone = false
    @State private var editingKey = false
    @State private var report: String?
    @State private var uploadingCert = false
    @State private var settingACMEDomain = false

    private var path: String { "/nodes/\(node.enc)" }

    var body: some View {
        Form {
            Section("DNS") {
                LabeledContent("Search domain", value: dns.string("search") ?? "–")
                LabeledContent("DNS servers", value: ["dns1", "dns2", "dns3"].compactMap { dns.text($0) }.joined(separator: ", "))
                Button("Edit DNS…") { editingDNS = true }
            }
            Section("Hosts file") {
                Text(hosts.isEmpty ? "–" : hosts).font(.system(.caption, design: .monospaced)).lineLimit(8).textSelection(.enabled)
                Button("Edit Hosts…") { editingHosts = true }
            }
            Section("Time") {
                LabeledContent("Time zone", value: time.string("timezone") ?? "–")
                LabeledContent("Server time", value: Format.epoch(time.int("time")).map(Format.dateTime) ?? "–")
                Button("Change Time Zone…") { editingTimezone = true }
            }
            Section("Certificates") {
                CertificateList(node: node)
                HStack {
                    Button("Upload Custom Certificate…") { uploadingCert = true }
                    Button("ACME Domain…") { settingACMEDomain = true }
                    Button("Order with ACME") { Task { await session.run("Order a certificate", .post, path + "/certificates/acme/certificate") } }
                    Button("Remove Custom Certificate", role: .destructive) {
                        session.confirmDelete("Remove the custom certificate from \(node)?", message: "The node goes back to its self-signed certificate. You may need to trust it again here.",
                                              path: path + "/certificates/custom", params: ["restart": "1"])
                    }
                }
            }
            Section("Subscription") {
                LabeledContent("Status", value: Format.subscription(subscription.string("status")))
                if let level = subscription.text("level") { LabeledContent("Level", value: level) }
                if let message = subscription.text("message") { Text(message).font(.callout).foregroundStyle(.secondary) }
                Button("Enter Subscription Key…") { editingKey = true }
            }
            Section("Options") {
                LabeledContent("Wake-on-LAN MAC", value: options.string("wakeonlan") ?? "–")
                LabeledContent("Start-on-boot delay", value: options.string("startall-onboot-delay").map { "\($0) s" } ?? "–")
                Button("Wake This Node") { Task { await session.run("Wake \(node)", .post, path + "/wakeonlan") } }
                    .disabled(options["wakeonlan"] == nil)
            }
            Section {
                Button("Generate System Report") {
                    Task { report = (try? await session.client.get(path + "/report")) as? String ?? "The report couldn't be generated." }
                }
            } footer: {
                Text("A full diagnostic report, as Proxmox support asks for.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: "\(node)-\(session.revision)") {
            dns = (try? await session.client.object(path + "/dns")) ?? [:]
            let hostsObject = (try? await session.client.object(path + "/hosts")) ?? [:]
            hosts = hostsObject.string("data") ?? ""
            hostsDigest = hostsObject.string("digest") ?? ""
            time = (try? await session.client.object(path + "/time")) ?? [:]
            subscription = (try? await session.client.object(path + "/subscription")) ?? [:]
            options = (try? await session.client.object(path + "/config")) ?? [:]
        }
        .sheet(isPresented: $editingDNS) {
            FormSheet(title: "DNS on \(node)", fields: [FormField(key: "search", label: "Search domain", required: true),
                                                         FormField(key: "dns1", label: "DNS server 1"), FormField(key: "dns2", label: "DNS server 2"),
                                                         FormField(key: "dns3", label: "DNS server 3")],
                      initial: ["search": dns.string("search") ?? "", "dns1": dns.string("dns1") ?? "", "dns2": dns.string("dns2") ?? "", "dns3": dns.string("dns3") ?? ""]) { result in
                // Proxmox rewrites resolv.conf from the servers sent (there's no `delete`), so a cleared one is left out.
                await session.run("Save DNS settings", .put, path + "/dns", result.all.filter { !$0.value.isEmpty })
            }
        }
        .sheet(isPresented: $editingHosts) {
            NotesEditor(title: "/etc/hosts on \(node)", text: hosts) { text in
                await session.run("Save the hosts file", .post, path + "/hosts", ["data": text + "\n", "digest": hostsDigest])
            }
        }
        .sheet(isPresented: $editingTimezone) {
            FormSheet(title: "Time zone", fields: [FormField(key: "timezone", label: "Time zone",
                                                             kind: .choice(TimeZone.knownTimeZoneIdentifiers.map { FormField.Choice($0) }), required: true)],
                      initial: ["timezone": time.string("timezone") ?? "UTC"]) { result in
                await session.run("Change the time zone", .put, path + "/time", ["timezone": result["timezone"]])
            }
        }
        .sheet(isPresented: $editingKey) {
            FormSheet(title: "Subscription key", fields: [FormField(key: "key", label: "Key", prompt: "pve1c-0123456789", required: true)], submitTitle: "Upload") { result in
                await session.run("Upload the subscription key", .put, path + "/subscription", ["key": result["key"]])
            }
        }
        .sheet(isPresented: $settingACMEDomain) { ACMEDomainSheet(node: node) }
        .debugAction("acme-domain") { settingACMEDomain = true }
        .sheet(isPresented: $uploadingCert) {
            FormSheet(title: "Upload certificate", message: "PEM format. The web interface restarts to use it.", fields: [
                FormField(key: "certificates", label: "Certificate chain", kind: .multiline, required: true),
                FormField(key: "key", label: "Private key", kind: .multiline),
            ], submitTitle: "Upload") { result in
                var params = result.changed
                params["restart"] = "1"
                params["force"] = "1"
                return await session.run("Upload the certificate", .post, path + "/certificates/custom", params)
            }
        }
        .sheet(item: Binding(get: { report.map { ReportText(text: $0) } }, set: { report = $0?.text })) { report in
            VStack(alignment: .leading, spacing: 12) {
                Text("System report for \(node)").font(.title3.bold())
                ScrollView { Text(report.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report.text, forType: .string) }
                    Spacer()
                    Button("Done") { self.report = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 760, height: 560)
        }
    }

    private struct ReportText: Identifiable {
        let text: String
        var id: Int { text.hashValue }
    }
}

private struct CertificateList: View {
    @Environment(Session.self) private var session
    let node: String
    @State private var certificates: [JSONObject] = []

    var body: some View {
        ForEach(Array(certificates.enumerated()), id: \.offset) { _, cert in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(cert.string("filename") ?? "").fontWeight(.medium)
                    Spacer()
                    if let expires = Format.epoch(cert.int("notafter")) {
                        Text("Expires \(Format.dateTime(expires))").font(.caption).foregroundStyle(expires < .now.addingTimeInterval(30 * 86_400) ? .orange : .secondary)
                    }
                }
                Text(cert.string("subject") ?? "").font(.caption).foregroundStyle(.secondary)
                Text(cert.string("fingerprint") ?? "").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .task(id: session.revision) { certificates = (try? await session.client.list("/nodes/\(node.enc)/certificates/info")) ?? [] }
    }
}

// MARK: Network

private struct NodeNetworkView: View {
    @Environment(Session.self) private var session
    let node: String
    @State private var adding: String?
    @State private var editing: Row?

    private var path: String { "/nodes/\(node.enc)/network" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu("Create", systemImage: "plus") {
                    Button("Linux Bridge…") { adding = "bridge" }
                    Button("Linux Bond…") { adding = "bond" }
                    Button("Linux VLAN…") { adding = "vlan" }
                }
                .fixedSize()
                Button("Apply Configuration", systemImage: "checkmark.circle") {
                    session.confirmation = Confirmation(title: "Apply network changes on \(node)?", message: "Pending changes are activated now. A mistake can cut off access to the node.",
                                                        actionTitle: "Apply", destructive: true) {
                        await session.run("Apply network changes", .put, path)
                    }
                }
                Button("Revert", systemImage: "arrow.uturn.backward") {
                    session.confirmDelete("Discard pending network changes on \(node)?", message: "Changes that weren't applied yet are thrown away.", path: path)
                }
                Spacer()
                Text("Changes take effect after Apply Configuration.").font(.callout).foregroundStyle(.secondary)
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            ResourceList(path: path, id: { $0.string("iface") ?? "" },
                         columns: [APIColumn("Name", key: "iface", width: 100, monospaced: true),
                                   APIColumn("Type", width: 100) { row in
                                       ["bridge": "Bridge", "eth": "Ethernet", "bond": "Bond", "vlan": "VLAN", "OVSBridge": "OVS bridge", "OVSPort": "OVS port",
                                        "OVSBond": "OVS bond", "OVSIntPort": "OVS internal", "unknown": "Other"][row.string("type") ?? ""] ?? (row.string("type") ?? "").capitalized
                                   },
                                   APIColumn("Active", width: 60) { $0.bool("active") ? "Yes" : "No" },
                                   APIColumn("Autostart", width: 70) { $0.bool("autostart") ? "Yes" : "No" },
                                   APIColumn("VLANs", width: 60) { $0.bool("bridge_vlan_aware") ? "Aware" : "" },
                                   APIColumn("Ports / slaves", width: 130) { $0.string("bridge_ports") ?? $0.string("slaves") ?? "" },
                                   APIColumn("CIDR", width: 150, monospaced: true) { $0.string("cidr") ?? "" },
                                   APIColumn("Gateway", key: "gateway", width: 120, monospaced: true),
                                   APIColumn("Comment", key: "comments", width: 200)],
                         emptyTitle: "No interfaces", emptySymbol: "network", open: { editing = $0 }) { row in
                Button("Edit…") { editing = row }
                if row["type"] != "eth" {
                    Button("Remove…", role: .destructive) { session.confirmDelete("Remove \(row.id)?", message: "Takes effect after Apply Configuration.", path: "\(path)/\(row.id.enc)") }
                }
            }
        }
        .sheet(item: Binding(get: { adding.map { Kind(type: $0) } }, set: { adding = $0?.type })) { kind in
            FormSheet(title: "Create \(["bridge": "Linux bridge", "bond": "Linux bond", "vlan": "Linux VLAN"][kind.type] ?? kind.type)", fields: Self.fields(kind.type, editing: false),
                      initial: ["autostart": "1", "iface": kind.type == "bridge" ? "vmbr1" : (kind.type == "bond" ? "bond0" : ""), "bond_mode": "active-backup"],
                      submitTitle: "Create") { result in
                var params = result.changed
                params["type"] = kind.type
                return await session.run("Create \(result["iface"])", .post, path, params)
            }
        }
        .sheet(item: $editing) { row in
            let type = row["type"] ?? "eth"
            FormSheet(title: "Edit \(row.id)", fields: Self.fields(type, editing: true),
                      initial: row.json.mapValues { value in (value as? String) ?? jsonDouble(value).map { String(Int($0)) } ?? "\(value)" }, isEdit: true) { result in
                var params = result.params
                params["type"] = type
                return await session.run("Save \(row.id)", .put, "\(path)/\(row.id.enc)", params)
            }
        }
    }

    private struct Kind: Identifiable {
        let type: String
        var id: String { type }
    }

    static func fields(_ type: String, editing: Bool) -> [FormField] {
        var fields = [FormField(key: "iface", label: "Name", prompt: type == "vlan" ? "eno1.10 or vlan10" : "", required: true, lockedOnEdit: true),
                      FormField(key: "cidr", label: "IPv4/CIDR", prompt: "192.168.10.2/24"), FormField(key: "gateway", label: "IPv4 gateway"),
                      FormField(key: "cidr6", label: "IPv6/CIDR"), FormField(key: "gateway6", label: "IPv6 gateway"),
                      FormField(key: "autostart", label: "Autostart", kind: .toggle), FormField(key: "mtu", label: "MTU", kind: .number, prompt: "1500")]
        switch type {
        case "bridge":
            fields += [FormField(key: "bridge_ports", label: "Bridge ports", prompt: "enp5s0"), FormField(key: "bridge_vlan_aware", label: "VLAN aware", kind: .toggle)]
        case "bond":
            fields += [FormField(key: "slaves", label: "Slaves", prompt: "enp5s0 enp6s0", required: true),
                       FormField(key: "bond_mode", label: "Mode", kind: .choice(["balance-rr", "active-backup", "balance-xor", "broadcast", "802.3ad", "balance-tlb", "balance-alb"].map { .init($0) }), required: true),
                       FormField(key: "bond-primary", label: "Primary (active-backup)"),
                       FormField(key: "bond_xmit_hash_policy", label: "Hash policy", kind: .choice(["layer2", "layer2+3", "layer3+4"].map { .init($0) }))]
        case "vlan":
            fields += [FormField(key: "vlan-raw-device", label: "VLAN raw device", prompt: "enp5s0"), FormField(key: "vlan-id", label: "VLAN tag", kind: .number)]
        default: break
        }
        fields.append(FormField(key: "comments", label: "Comment"))
        return fields
    }
}

// MARK: Disks

private struct NodeDisksView: View {
    @Environment(Session.self) private var session
    let node: String
    @State private var section = "disks"
    @State private var smart: Row?
    @State private var creating: String?
    @State private var destroying: Destroy?
    @State private var zfsPool: String?

    private var path: String { "/nodes/\(node.enc)/disks" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Section", selection: $section) {
                    Text("Disks").tag("disks")
                    Text("LVM").tag("lvm")
                    Text("LVM-Thin").tag("lvmthin")
                    Text("Directory").tag("directory")
                    Text("ZFS").tag("zfs")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if section != "disks" {
                    Button("Create \(["lvm": "Volume Group", "lvmthin": "Thin Pool", "directory": "Directory", "zfs": "ZFS Pool"][section] ?? "")…", systemImage: "plus") { creating = section }
                        .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            switch section {
            case "lvm":
                ResourceList(path: path + "/lvm", id: { $0.string("name") ?? "" },
                             columns: [APIColumn("Volume group", key: "name", width: 160), APIColumn("Size", width: 100) { Format.bytes($0.int64("size")) },
                                       APIColumn("Free", width: 100) { Format.bytes($0.int64("free")) }],
                             emptyTitle: "No LVM volume groups", emptySymbol: "cylinder.split.1x2",
                             transform: { list in list.first?.objects("children") ?? list }) { row in
                    Button("Destroy…", role: .destructive) { destroying = Destroy(kind: "lvm", name: row.id) }
                }
            case "lvmthin":
                ResourceList(path: path + "/lvmthin", id: { $0.string("lv") ?? "" },
                             columns: [APIColumn("Thin pool", key: "lv", width: 140), APIColumn("Volume group", key: "vg", width: 120),
                                       APIColumn("Size", width: 100) { Format.bytes($0.int64("lv_size")) }, APIColumn("Used", width: 100) { Format.bytes($0.int64("used")) },
                                       APIColumn("Metadata", width: 100) { Format.bytes($0.int64("metadata_used")) }],
                             emptyTitle: "No thin pools", emptySymbol: "cylinder") { row in
                    Button("Destroy…", role: .destructive) { destroying = Destroy(kind: "lvmthin", name: row.id, volumeGroup: row["vg"]) }
                }
            case "directory":
                ResourceList(path: path + "/directory", id: { $0.string("path") ?? "" },
                             columns: [APIColumn("Path", key: "path", width: 200, monospaced: true), APIColumn("Device", key: "device", width: 140, monospaced: true),
                                       APIColumn("File system", key: "type", width: 90), APIColumn("Options", key: "options", width: 200)],
                             emptyTitle: "No directory storages", emptySymbol: "folder") { row in
                    // The API names a directory storage by its mount point's last component (/mnt/pve/backups → backups).
                    Button("Destroy…", role: .destructive) { destroying = Destroy(kind: "directory", name: String(row.id.split(separator: "/").last ?? "")) }
                }
            case "zfs":
                ResourceList(path: path + "/zfs", id: { $0.string("name") ?? "" },
                             columns: [APIColumn("Pool", key: "name", width: 120), APIColumn("Health", key: "health", width: 80),
                                       APIColumn("Size", width: 100) { Format.bytes($0.int64("size")) }, APIColumn("Allocated", width: 100) { Format.bytes($0.int64("alloc")) },
                                       APIColumn("Free", width: 100) { Format.bytes($0.int64("free")) }, APIColumn("Fragmentation", width: 100) { "\($0.string("frag") ?? "0")%" },
                                       APIColumn("Dedup", width: 60) { $0.string("dedup").map { "\($0)×" } ?? "" }],
                             emptyTitle: "No ZFS pools", emptySymbol: "circle.grid.2x2", open: { zfsPool = $0.id }) { row in
                    Button("Show Details") { zfsPool = row.id }
                    Divider()
                    Button("Destroy…", role: .destructive) { destroying = Destroy(kind: "zfs", name: row.id) }
                }
            default:
                ResourceList(path: path + "/list", id: { $0.string("devpath") ?? "" },
                             columns: [APIColumn("Device", key: "devpath", width: 120, monospaced: true),
                                       APIColumn("Type", width: 60) { ($0.string("type") ?? "").uppercased() },
                                       APIColumn("Usage", width: 100) { $0.text("used") ?? "Unused" },
                                       APIColumn("Size", width: 90) { Format.bytes($0.int64("size")) },
                                       APIColumn("Model", key: "model", width: 220), APIColumn("Serial", key: "serial", width: 160, monospaced: true),
                                       APIColumn("S.M.A.R.T.", key: "health", width: 80),
                                       APIColumn("Wearout", width: 80) { row in row.int("wearout").map { "\(100 - $0)% used" } ?? (row.string("wearout") ?? "") }],
                             emptyTitle: "No disks", emptySymbol: "internaldrive", open: { smart = $0 }) { row in
                    Button("Show S.M.A.R.T. Values") { smart = row }
                    Button("Initialize Disk with GPT") {
                        session.confirmation = Confirmation(title: "Initialize \(row.id) with GPT?", message: "Writes a new empty partition table. Only works on unused disks.",
                                                            actionTitle: "Initialize", destructive: true) {
                            await session.run("Initialize \(row.id)", .post, path + "/initgpt", ["disk": row.id])
                        }
                    }
                    Divider()
                    Button("Wipe Disk…", role: .destructive) {
                        session.confirmation = Confirmation(title: "Wipe \(row.id)?", message: "Every partition and all data on \(row["model"] ?? "this disk") is destroyed.",
                                                            actionTitle: "Wipe", destructive: true) {
                            await session.run("Wipe \(row.id)", .put, path + "/wipedisk", ["disk": row.id])
                        }
                    }
                }
            }
        }
        .sheet(item: $smart) { row in SmartSheet(node: node, disk: row.id, model: row["model"] ?? "") }
        .sheet(item: Binding(get: { zfsPool.map { ZFSPool(name: $0) } }, set: { zfsPool = $0?.name })) { pool in ZFSPoolSheet(node: node, pool: pool.name) }
        .debugAction("zfs-detail") { section = "zfs"; zfsPool = "tank" }
        .debugAction("destroy-zfs") { section = "zfs"; destroying = Destroy(kind: "zfs", name: "tank") }
        .sheet(item: $destroying) { target in
            FormSheet(title: "Destroy \(target.name)?", message: "\(target.what) on \(node) is removed, with everything stored on it. This can't be undone.", fields: [
                FormField(key: "cleanup-config", label: "Remove its storage from the configuration", kind: .toggle,
                          help: "Otherwise the storage stays configured but is unavailable on this node"),
                FormField(key: "cleanup-disks", label: "Wipe the disks so they can be reused", kind: .toggle),
                FormField(key: "confirm", label: "Name", prompt: target.name, help: "Type the name to confirm", required: true),
            ], initial: ["cleanup-config": "1", "cleanup-disks": "0"], submitTitle: "Destroy", destructive: true) { result in
                guard result["confirm"] == target.name else {
                    session.alert = AlertItem(title: "The name doesn't match", message: "Type \(target.name) exactly to destroy it.")
                    return false
                }
                var params: [String: String] = [:]
                for key in ["cleanup-config", "cleanup-disks"] where result[key] == "1" { params[key] = "1" }
                if let group = target.volumeGroup { params["volume-group"] = group }
                return await session.run("Destroy \(target.name)", .delete, "\(path)/\(target.kind)/\(target.name.enc)", params)
            }
        }
        .sheet(item: Binding(get: { creating.map { Create(kind: $0) } }, set: { creating = $0?.kind })) { create in
            Prepared(load: {
                ((try? await session.client.list(path + "/list", ["type": "unused", "include-partitions": "0"])) ?? [])
                    .compactMap { disk in disk.text("devpath").map { FormField.Choice($0, "\($0) — \(disk.string("model") ?? "") \(Format.bytes(disk.int64("size")))") } }
            }) { disks in
                FormSheet(title: create.title, message: disks.isEmpty ? "There's no unused disk on \(node). Wipe one first." : nil, fields: create.fields(disks),
                          initial: ["add_storage": "1", "raidlevel": "mirror", "compression": "on", "ashift": "12", "filesystem": "ext4"], submitTitle: "Create") { result in
                    var params = result.changed
                    if let devices = params["devices"] { params["devices"] = devices.replacingOccurrences(of: ",", with: " ") }
                    return await session.run(create.title, .post, "\(path)/\(create.kind)", params)
                }
            }
        }
    }

    private struct Destroy: Identifiable {
        let kind: String
        let name: String
        var volumeGroup: String?
        var id: String { kind + "/" + name }
        var what: String { ["lvm": "The volume group", "lvmthin": "The thin pool", "directory": "The directory storage", "zfs": "The ZFS pool"][kind] ?? "It" }
    }

    private struct ZFSPool: Identifiable {
        let name: String
        var id: String { name }
    }

    private struct Create: Identifiable {
        let kind: String
        var id: String { kind }
        var title: String { ["lvm": "Create LVM volume group", "lvmthin": "Create LVM thin pool", "directory": "Create directory storage", "zfs": "Create ZFS pool"][kind] ?? "Create" }
        func fields(_ disks: [FormField.Choice]) -> [FormField] {
            var fields = [FormField(key: "name", label: "Name", prompt: kind == "zfs" ? "tank" : "data", required: true)]
            if kind == "zfs" {
                fields += [FormField(key: "devices", label: "Disks", kind: .multiChoice(disks), required: true),
                           FormField(key: "raidlevel", label: "RAID level", kind: .choice(["single", "mirror", "raid10", "raidz", "raidz2", "raidz3", "draid", "draid2"].map { .init($0) }), required: true),
                           FormField(key: "compression", label: "Compression", kind: .choice(["on", "off", "lz4", "zstd", "gzip"].map { .init($0) })),
                           FormField(key: "ashift", label: "ashift", kind: .number)]
            } else {
                fields.append(FormField(key: "device", label: "Disk", kind: .choice(disks), required: true))
                if kind == "directory" { fields.append(FormField(key: "filesystem", label: "File system", kind: .choice([.init("ext4"), .init("xfs")]))) }
            }
            fields.append(FormField(key: "add_storage", label: "Add as storage", kind: .toggle))
            return fields
        }
    }
}

/// The versions of the important Proxmox packages, as text to copy into a forum post or bug report,
/// in the web UI's "Package versions" format.
private struct PackageVersionsSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let node: String

    var body: some View {
        Prepared(load: { () -> String? in
            guard let list = try? await session.client.list("/nodes/\(node.enc)/apt/versions") else { return nil }
            return list.map { package in
                let name = package.string("Package") ?? ""
                var line = "\(name): " + (package.string("CurrentState") == "Installed" ? package.string("OldVersion") ?? "" : "not correctly installed")
                if let kernel = package.text("RunningKernel") { line += " (running kernel: \(kernel))" }
                if let manager = package.text("ManagerVersion") { line += " (running version: \(manager))" }
                return line
            }.joined(separator: "\n")
        }) { text in
            VStack(alignment: .leading, spacing: 12) {
                Text("Package versions on \(node)").font(.title2.bold())
                ScrollView {
                    Text(text ?? "Couldn't read the package versions.")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
                HStack {
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text ?? "", forType: .string)
                    }
                    .disabled(text == nil)
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(24)
            .frame(width: 640, height: 520)
        }
    }
}

/// A ZFS pool's health, last scrub and device tree, like the web UI's Detail window.
private struct ZFSPoolSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let node: String
    let pool: String

    private struct Device: Identifiable {
        let id: Int
        let depth: Int
        let json: JSONObject
    }

    var body: some View {
        Prepared(load: { try? await session.client.object("/nodes/\(node.enc)/disks/zfs/\(pool.enc)") }) { detail in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(pool).font(.title2.bold())
                    let state = detail?.string("state") ?? "unknown"
                    Pill(text: state, color: state == "ONLINE" ? .green : .orange)
                    Spacer()
                }
                if let detail {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(["status", "action", "scan", "errors"], id: \.self) { key in
                            if let value = detail.text(key) {
                                GridRow {
                                    Text(key.capitalized).foregroundStyle(.secondary)
                                    Text(value).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    Table(Self.flatten(detail.objects("children"))) {
                        TableColumn("Device") { device in
                            // ZFS's note about a device (such as "was /dev/sdb1") follows its name.
                            Text("\(device.json.string("name") ?? "")\(Text(device.json.text("msg").map { "  \($0)" } ?? "").foregroundStyle(.secondary))")
                                .padding(.leading, CGFloat(device.depth) * 14).lineLimit(1).truncationMode(.middle)
                        }
                        .width(min: 200, ideal: 330)
                        TableColumn("State") { Text($0.json.string("state") ?? "") }.width(80)
                        TableColumn("Read") { Text($0.json.string("read") ?? "").monospacedDigit() }.width(50)
                        TableColumn("Write") { Text($0.json.string("write") ?? "").monospacedDigit() }.width(50)
                        TableColumn("Checksum") { Text($0.json.string("cksum") ?? "").monospacedDigit() }.width(70)
                    }
                    .frame(minHeight: 180)
                } else {
                    ContentUnavailableView("Couldn't read the pool", systemImage: "exclamationmark.triangle")
                }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
            .controlSize(.large)
            .padding(24)
            .frame(width: 760, height: 480)
        }
    }

    /// The nested vdev tree as indented rows.
    private static func flatten(_ nodes: [JSONObject], depth: Int = 0, into rows: inout [Device]) {
        for node in nodes {
            rows.append(Device(id: rows.count, depth: depth, json: node))
            flatten(node.objects("children"), depth: depth + 1, into: &rows)
        }
    }

    private static func flatten(_ nodes: [JSONObject]) -> [Device] {
        var rows: [Device] = []
        flatten(nodes, into: &rows)
        return rows
    }
}

private struct SmartSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let node: String
    let disk: String
    let model: String
    @State private var data: JSONObject = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("S.M.A.R.T. for \(disk)").font(.title3.bold())
                Text(model).foregroundStyle(.secondary)
                Spacer()
                if let health = data.text("health") {
                    Pill(text: health, systemImage: health == "PASSED" || health == "OK" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                         color: health == "PASSED" || health == "OK" ? .green : .red)
                }
            }
            if let text = data.text("text") {
                ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                Table(data.objects("attributes").enumerated().map { Row(id: String($0.offset), json: $0.element) }) {
                    TableColumn("ID") { row in Text(row["id"]?.trimmingCharacters(in: .whitespaces) ?? "").monospacedDigit() }.width(40)
                    TableColumn("Attribute") { row in Text(row["name"] ?? "") }.width(min: 160, ideal: 220)
                    TableColumn("Value") { row in Text(row["value"] ?? "").monospacedDigit() }.width(60)
                    TableColumn("Worst") { row in Text(row["worst"] ?? "").monospacedDigit() }.width(60)
                    TableColumn("Threshold") { row in Text(row["threshold"] ?? "").monospacedDigit() }.width(70)
                    TableColumn("Failing") { row in Text(row["fail"] ?? "").foregroundStyle(row["fail"] == "-" ? Color.secondary : .red) }.width(90)
                    TableColumn("Raw") { row in Text(row["raw"] ?? "").monospacedDigit() }.width(min: 60, ideal: 100)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 760, height: 520)
        .task { data = (try? await session.client.object("/nodes/\(node.enc)/disks/smart", ["disk": disk])) ?? [:] }
    }
}

// MARK: Services, updates, syslog

private struct NodeServicesView: View {
    @Environment(Session.self) private var session
    let node: String

    var body: some View {
        ResourceList(path: "/nodes/\(node.enc)/services", id: { $0.string("service") ?? "" },
                     columns: [APIColumn("Service", key: "service", width: 160), APIColumn("State", key: "state", width: 90),
                               APIColumn("Active", key: "active-state", width: 80), APIColumn("Unit", key: "unit-state", width: 90),
                               APIColumn("Description", key: "desc", width: 320)],
                     emptyTitle: "No services", emptySymbol: "switch.2") { row in
            Button("Start") { action(row.id, "start") }
            Button("Stop") { action(row.id, "stop") }
            Button("Restart") { action(row.id, "restart") }
            Button("Reload") { action(row.id, "reload") }
        }
    }

    private func action(_ service: String, _ verb: String) {
        Task { await session.run("\(verb.capitalized) \(service)", .post, "/nodes/\(node.enc)/services/\(service.enc)/\(verb)") }
    }
}

private struct NodeUpdatesView: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    let node: String
    @State private var section = "updates"
    @State private var changelog: (String, String)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Section", selection: $section) {
                    Text("Updates").tag("updates")
                    Text("Repositories").tag("repos")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await session.run("Refresh the package lists", .post, "/nodes/\(node.enc)/apt/update") } }
                Button("Upgrade", systemImage: "arrow.down.circle") {
                    openWindow(id: "console", value: ConsoleTarget(kind: "upgrade", node: node, vmid: nil, name: "Upgrade \(node)"))
                }
                .buttonStyle(.glassProminent)
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            if section == "repos" {
                RepositoriesView(node: node)
            } else {
                ResourceList(path: "/nodes/\(node.enc)/apt/update", id: { $0.string("Package") ?? "" },
                             columns: [APIColumn("Package", key: "Package", width: 200), APIColumn("Installed", key: "OldVersion", width: 140, monospaced: true),
                                       APIColumn("Available", key: "Version", width: 140, monospaced: true), APIColumn("Origin", key: "Origin", width: 90),
                                       APIColumn("Priority", key: "Priority", width: 80), APIColumn("Description", key: "Title", width: 300)],
                             emptyTitle: "Up to date", emptySymbol: "checkmark.circle", emptyMessage: "No updates are available. Refresh to check again.",
                             open: { row in loadChangelog(row.id) }) { row in
                    Button("Show Changelog") { loadChangelog(row.id) }
                }
            }
        }
        .sheet(item: Binding(get: { changelog.map { Changelog(name: $0.0, text: $0.1) } }, set: { if $0 == nil { changelog = nil } })) { log in
            VStack(alignment: .leading, spacing: 12) {
                Text("Changelog for \(log.name)").font(.title3.bold())
                ScrollView { Text(log.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Done") { changelog = nil }.keyboardShortcut(.defaultAction) }
            }
            .padding(24)
            .frame(width: 680, height: 500)
        }
    }

    private struct Changelog: Identifiable {
        let name: String
        let text: String
        var id: String { name }
    }

    private func loadChangelog(_ package: String) {
        Task {
            let text = (try? await session.client.get("/nodes/\(node.enc)/apt/changelog", ["name": package])) as? String ?? "No changelog available."
            changelog = (package, text)
        }
    }
}

private struct RepositoriesView: View {
    @Environment(Session.self) private var session
    let node: String
    @State private var data: JSONObject = [:]

    var body: some View {
        Form {
            Section("Proxmox repositories") {
                ForEach(Array(data.objects("standard-repos").enumerated()), id: \.offset) { _, repo in
                    LabeledContent {
                        HStack {
                            Text(repo.string("status").map { jsonBool($0) ? "Enabled" : "Disabled" } ?? "Not configured").foregroundStyle(.secondary)
                            if repo["status"] == nil || repo["status"] is NSNull {
                                Button("Add") {
                                    Task { await session.run("Add the \(repo.string("name") ?? "") repository", .put, "/nodes/\(node.enc)/apt/repositories",
                                                             ["handle": repo.string("handle") ?? "", "digest": data.string("digest") ?? ""]) }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } label: {
                        Text(repo.string("name") ?? repo.string("handle") ?? "")
                    }
                }
            }
            ForEach(Array(data.objects("files").enumerated()), id: \.offset) { _, file in
                Section(file.string("path") ?? "") {
                    ForEach(Array(file.objects("repositories").enumerated()), id: \.offset) { index, repo in
                        Toggle(isOn: Binding { repo.bool("Enabled") } set: { on in
                            Task { await session.run(on ? "Enable the repository" : "Disable the repository", .post, "/nodes/\(node.enc)/apt/repositories",
                                                     ["path": file.string("path") ?? "", "index": String(index), "enabled": on ? "1" : "0", "digest": data.string("digest") ?? ""]) }
                        }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(repo.strings("Types").joined(separator: " ")) \(repo.strings("URIs").joined(separator: " "))").fontDesign(.monospaced)
                                Text("\(repo.strings("Suites").joined(separator: " ")) — \(repo.strings("Components").joined(separator: " "))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !data.objects("errors").isEmpty {
                Section("Problems") {
                    ForEach(Array(data.objects("errors").enumerated()), id: \.offset) { _, error in
                        Text("\(error.string("path") ?? ""): \(error.string("error") ?? "")").foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: session.revision) { data = (try? await session.client.object("/nodes/\(node.enc)/apt/repositories")) ?? [:] }
    }
}

private struct NodeSyslogView: View {
    @Environment(Session.self) private var session
    let node: String
    @State private var lines: [String] = []
    @State private var filter = ""
    @State private var follow = true
    /// Where the journal left off, so each refresh only fetches what's new.
    @State private var cursor: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    let shown = filter.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(filter) }
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.localizedCaseInsensitiveContains("error") || line.localizedCaseInsensitiveContains("fail") ? .red : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
                    .onChange(of: lines.count) { _, _ in
                        if follow { proxy.scrollTo(shown.count - 1, anchor: .bottom) }
                    }
                }
            }
        }
        .polling(id: node, every: .seconds(5)) { await load() }
    }

    /// The systemd journal, as the web UI reads it: Proxmox 8 and 9 on Debian 12 and 13 don't keep /var/log/syslog,
    /// so the older syslog call comes back empty there. It stays as the fallback for servers without the journal API.
    private func load() async {
        var query = ["lastentries": "600"]
        if let cursor { query = ["startcursor": cursor] }
        if let raw = try? await session.client.get("/nodes/\(node.enc)/journal", query) as? [Any] {
            // The first line is a cursor for older entries and the last one the cursor to continue from.
            let entries = raw.compactMap { $0 as? String }
            guard entries.count >= 2 else { return }
            cursor = entries.last
            let fresh = entries.dropFirst().dropLast()
            if !fresh.isEmpty {
                lines.append(contentsOf: fresh)
                if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
            }
            return
        }
        guard let first = try? await session.client.call(.get, "/nodes/\(node.enc)/syslog", ["start": "0", "limit": "1"]) else { return }
        let start = max(0, (first.total ?? 0) - 600)
        if let list = try? await session.client.list("/nodes/\(node.enc)/syslog", ["start": String(start), "limit": "600"]) {
            let fresh = list.compactMap { $0.string("t") }
            if fresh != lines { lines = fresh }
        }
    }
}
