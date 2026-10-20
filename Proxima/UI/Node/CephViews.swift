import SwiftUI

/// A node's Ceph page. Walks through installing and configuring Ceph when it's missing; otherwise
/// health and flags, monitors, managers, metadata servers, OSDs, pools and CephFS.
struct CephView: View {
    @Environment(Session.self) private var session
    let node: String
    @State private var status: JSONObject?
    @State private var problem: String?
    @State private var sheet: CephSheet?

    enum CephSheet: String, Identifiable {
        case install, configure, osd, pool, flags, fs, config, restartOSDs
        var id: String { rawValue }
    }

    /// The health check being muted, if any.
    @State private var muting: String?

    var body: some View {
        Group {
            if let problem {
                setup(problem)
            } else if let status {
                Page {
                    health(status)
                    usage(status.object("pgmap") ?? [:])
                    HStack(alignment: .top, spacing: 18) {
                        CephDaemons(node: node, kind: "mon")
                        CephDaemons(node: node, kind: "mgr")
                    }
                    Card(title: "OSDs", systemImage: "externaldrive.connected.to.line.below") {
                        CephOSDs(node: node)
                    } accessory: {
                        HStack(spacing: 14) {
                            Button("Restart OSDs…") { sheet = .restartOSDs }
                            Button("Create OSD…") { sheet = .osd }
                        }
                        .buttonStyle(.link)
                    }
                    Card(title: "Pools", systemImage: "drop") {
                        CephPools(node: node)
                    } accessory: {
                        Button("Create Pool…") { sheet = .pool }.buttonStyle(.link)
                    }
                    HStack(alignment: .top, spacing: 18) {
                        CephDaemons(node: node, kind: "mds")
                        CephFilesystems(node: node) { sheet = .fs }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(node)\(session.revision)") { await load() }
        .debugAction("create-pool") { sheet = .pool }
        .debugAction("create-osd") { sheet = .osd }
        .debugAction("install-ceph") { sheet = .install }
        .debugAction("configure-ceph") { sheet = .configure }
        .debugAction("ceph-flags") { sheet = .flags }
        .debugAction("ceph-config") { sheet = .config }
        .debugAction("restart-osds") { sheet = .restartOSDs }
        .debugAction("mute-check") { muting = "RECENT_CRASH" }
        .sheet(item: Binding(get: { muting.map { MuteCheck(code: $0) } }, set: { muting = $0?.code })) { check in
            FormSheet(title: "Mute \(check.code)?", message: "A muted check no longer turns the cluster's health to warning, but stays listed.", fields: [
                FormField(key: "ttl", label: "For", kind: .choice([.init("1h", "An hour"), .init("1d", "A day"), .init("1w", "A week")]), prompt: "Until unmuted"),
                FormField(key: "sticky", label: "Keep muted if it gets worse", kind: .toggle,
                          help: "Otherwise the mute ends as soon as more daemons or objects are affected"),
            ], submitTitle: "Mute") { result in
                var params = ["value": "1"]
                if !result["ttl"].isEmpty { params["ttl"] = result["ttl"] }
                if result["sticky"] == "1" { params["sticky"] = "1" }
                return await session.run("Mute \(check.code)", .put, "/cluster/ceph/health-mute/\(check.code.enc)", params)
            }
        }
        .sheet(item: $sheet, onDismiss: { Task { await load() } }) { sheet in
            switch sheet {
            case .install: CephInstallSheet(node: node)
            case .configure: CephConfigureSheet(node: node)
            case .osd: CephOSDSheet(node: node)
            case .pool: CephPoolSheet(node: node)
            case .flags: CephFlagsSheet()
            case .fs: CephFSSheet(node: node)
            case .config: CephConfigSheet(node: node)
            case .restartOSDs: CephRestartOSDsSheet(node: node)
            }
        }
    }

    private struct MuteCheck: Identifiable {
        let code: String
        var id: String { code }
    }

    private func load() async {
        do {
            status = try await session.client.object("/nodes/\(node.enc)/ceph/status")
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// pveceph reports "binary not installed" before the packages are in and "not initialized" before the first configuration.
    @ViewBuilder private func setup(_ problem: String) -> some View {
        if problem.contains("not installed") {
            ContentUnavailableView {
                Label("Ceph isn't installed", systemImage: "circle.hexagongrid")
            } description: {
                Text("Install the Ceph packages on \(node). A console window shows the installer; when it's done, come back to configure the cluster.")
            } actions: {
                Button("Install Ceph…") { sheet = .install }.buttonStyle(.glassProminent)
                Button("Check Again") { Task { await load() } }.buttonStyle(.glass)
            }
        } else if problem.contains("not initialized") || problem.contains("ceph.conf") {
            ContentUnavailableView {
                Label("Ceph isn't configured yet", systemImage: "circle.hexagongrid")
            } description: {
                Text("Choose the network Ceph uses and how many copies of each object it keeps. \(node) gets the first monitor and manager.")
            } actions: {
                Button("Configure Ceph…") { sheet = .configure }.buttonStyle(.glassProminent)
            }
        } else {
            ContentUnavailableView {
                Label("Ceph status isn't available", systemImage: "exclamationmark.triangle")
            } description: {
                Text(problem)
            } actions: {
                Button("Try Again") { Task { await load() } }.buttonStyle(.glass)
            }
        }
    }

    private func health(_ status: JSONObject) -> some View {
        let health = status.object("health")?.string("status") ?? "unknown"
        let checks = status.object("health")?.object("checks") ?? [:]
        return Card(title: "Health", systemImage: "heart.text.square") {
            Pill(text: health, systemImage: health == "HEALTH_OK" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                 color: health == "HEALTH_OK" ? .green : (health == "HEALTH_WARN" ? .orange : .red))
            ForEach(checks.keys.sorted(), id: \.self) { key in
                checkRow(key, checks[key] as? JSONObject ?? [:])
            }
        } accessory: {
            HStack(spacing: 14) {
                Button("Configuration…") { sheet = .config }
                Button("Global Flags…") { sheet = .flags }
            }
            .buttonStyle(.link)
        }
    }

    /// One health warning, with Mute… or Unmute.
    private func checkRow(_ key: String, _ check: JSONObject) -> some View {
        let muted = jsonBool(check["muted"])
        return HStack {
            Label {
                Text(check.object("summary")?.string("message") ?? key)
            } icon: {
                Image(systemName: muted ? "speaker.slash.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(muted ? Color.secondary : check.string("severity") == "HEALTH_ERR" ? .red : .orange)
            }
            .foregroundStyle(muted ? .secondary : .primary)
            if muted { Text("Muted").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(muted ? "Unmute" : "Mute…") {
                if muted {
                    Task {
                        await session.run("Unmute \(key)", .put, "/cluster/ceph/health-mute/\(key.enc)", ["value": "0"])
                        await load()
                    }
                } else {
                    muting = key
                }
            }
            .buttonStyle(.link)
            .help(key)
        }
        .font(.callout)
    }

    private func usage(_ pgmap: JSONObject) -> some View {
        let used = pgmap.int64("bytes_used"), total = pgmap.int64("bytes_total")
        return Card(title: "Usage", systemImage: "chart.pie") {
            Meter(title: "Raw capacity", fraction: total > 0 ? Double(used) / Double(total) : 0, color: Theme.disk,
                  detail: "\(Format.bytes(used)) of \(Format.bytes(total))")
            InfoGrid(rows: [("Placement groups", pgmap.int("num_pgs")?.formatted() ?? "–"), ("Objects", pgmap.int("num_objects")?.formatted() ?? "–"),
                            ("Read", Format.rate(pgmap.double("read_bytes_sec") ?? 0)), ("Write", Format.rate(pgmap.double("write_bytes_sec") ?? 0))])
        }
    }
}

// MARK: Setup

/// Runs `pveceph install` in a console window, like the web UI's installation step.
private struct CephInstallSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    let node: String

    var body: some View {
        Prepared(load: {
            let releases = ((try? await session.client.list("/nodes/\(node.enc)/ceph/releases")) ?? [])
                .filter { $0["available"] == nil || jsonBool($0["available"]) }
                .sorted { ($0.string("version") ?? "").localizedStandardCompare($1.string("version") ?? "") == .orderedAscending }
                .compactMap { release in release.text("release").map { FormField.Choice($0, "\($0.capitalized) (\(release.string("version") ?? ""))") } }
            return releases.isEmpty ? [FormField.Choice("reef", "Reef (18.2)"), FormField.Choice("squid", "Squid (19.2)")] : releases
        }) { releases in
            FormSheet(title: "Install Ceph on \(node)",
                      message: "A console window runs the installer and asks you to confirm. Without a subscription, use the No-Subscription repository.", fields: [
                FormField(key: "release", label: "Ceph release", kind: .choice(releases), required: true),
                FormField(key: "repository", label: "Repository", kind: .choice([.init("no-subscription", "No-Subscription"), .init("enterprise", "Enterprise (needs a subscription)"),
                                                                                 .init("test", "Test")]), required: true),
            ], initial: ["release": releases.last?.value ?? "", "repository": "no-subscription"], submitTitle: "Open Installer") { result in
                // pveceph takes its options NUL-separated.
                openWindow(id: "console", value: ConsoleTarget(kind: "cmd", node: node, vmid: nil, name: "Install Ceph on \(node)", cmd: "ceph_install",
                                                              cmdOptions: "--version\0\(result["release"])\0--repository\0\(result["repository"])"))
                return true
            }
        }
    }
}

/// `pveceph init` plus the first monitor (which brings the first manager with it).
struct CephConfigureSheet: View {
    @Environment(Session.self) private var session
    let node: String

    var body: some View {
        Prepared(load: {
            var seen = Set<String>()
            return ((try? await session.client.list("/nodes/\(node.enc)/network")) ?? [])
                .flatMap { [$0.text("cidr"), $0.text("cidr6")].compactMap { $0 } }
                .map(Self.network(of:))
                .filter { seen.insert($0).inserted }
        }) { networks in
            FormSheet(title: "Configure Ceph", message: "Creates the cluster configuration, then a monitor and a manager on \(node).", fields: [
                FormField(key: "network", label: "Public network", kind: networks.isEmpty ? .text : .choice(networks.map { FormField.Choice($0) }), prompt: "10.10.10.0/24", required: true),
                FormField(key: "cluster-network", label: "Cluster network", kind: .choice(networks.map { FormField.Choice($0) }), prompt: "Same as public",
                          help: "A separate network for replication between OSDs"),
                FormField(key: "size", label: "Replicas", kind: .number, prompt: "3"),
                FormField(key: "min_size", label: "Minimum replicas", kind: .number, prompt: "2"),
            ], initial: ["network": networks.first ?? "", "size": "3", "min_size": "2"], submitTitle: "Configure") { result in
                guard await session.run("Configure Ceph", .post, "/nodes/\(node.enc)/ceph/init", result.changed) else { return false }
                return await session.run("Create the first monitor", .post, "/nodes/\(node.enc)/ceph/mon/\(node.enc)")
            }
        }
    }

    /// "192.168.1.10/24" → "192.168.1.0/24". IPv6 and anything unexpected passes through.
    static func network(of cidr: String) -> String {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = UInt32(parts[1]), bits <= 32 else { return cidr }
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 < 256 }) else { return cidr }
        let address = octets.reduce(0) { $0 << 8 | $1 }
        let network = address & (bits == 0 ? 0 : ~UInt32(0) << (32 - bits))
        return "\(network >> 24).\(network >> 16 & 255).\(network >> 8 & 255).\(network & 255)/\(bits)"
    }
}

private struct CephFlagsSheet: View {
    @Environment(Session.self) private var session

    var body: some View {
        Prepared(load: { (try? await session.client.list("/cluster/ceph/flags")) ?? [] }) { flags in
            FormSheet(title: "Global flags", message: "Set noout before maintenance so Ceph doesn't start moving data off a node that's down for a reboot.",
                      fields: flags.compactMap { flag in flag.text("name").map { FormField(key: $0, label: $0, kind: .toggle, help: flag.string("description")) } },
                      initial: Dictionary(uniqueKeysWithValues: flags.compactMap { flag in flag.text("name").map { ($0, jsonBool(flag["value"]) ? "1" : "0") } }),
                      isEdit: true) { result in
                if result.changed.isEmpty { return true }
                return await session.run("Set the Ceph flags", .put, "/cluster/ceph/flags", result.changed)
            }
        }
    }
}

// MARK: Daemons

/// Monitors, managers or metadata servers: where they run, with start, stop, restart, destroy and create.
private struct CephDaemons: View {
    @Environment(Session.self) private var session
    let node: String
    let kind: String
    @State private var daemons: [JSONObject] = []
    @State private var adding = false

    private static let names = ["mon": ("Monitors", "monitor", "eye"), "mgr": ("Managers", "manager", "person.crop.rectangle.stack"),
                                "mds": ("Metadata Servers", "metadata server", "folder.badge.gearshape")]

    var body: some View {
        let (title, singular, symbol) = Self.names[kind] ?? (kind, kind, "gearshape")
        Card(title: title, systemImage: symbol) {
            ForEach(Array(daemons.enumerated()), id: \.offset) { _, daemon in
                let name = daemon.string("name") ?? ""
                let host = daemon.string("host") ?? node
                let state = daemon.string("state") ?? (jsonBool(daemon["quorum"]) ? "in quorum" : "")
                HStack {
                    Circle().fill(Self.healthy(daemon) ? Color.green : .red).frame(width: 8, height: 8)
                    Text("\(kind).\(name)").fontWeight(.medium)
                    Text(host).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text(state).font(.callout).foregroundStyle(.secondary)
                    Menu {
                        ForEach(["start", "stop", "restart"], id: \.self) { action in
                            Button(action.capitalized) {
                                let run = { await session.run("\(action.capitalized) \(kind).\(name)", .post, "/nodes/\(host.enc)/ceph/\(action)", ["service": "\(kind).\(name)"]) }
                                Task {
                                    // Stopping a monitor can cost quorum: ask Ceph first, like the web UI.
                                    if action == "stop", kind != "mgr", let warning = await CephSafety.check(session, host: host, service: kind, id: name, action: "stop") {
                                        session.confirmation = Confirmation(title: "Stop \(kind).\(name)?", message: "Ceph warns: \(warning)", actionTitle: "Stop Anyway", destructive: true) { _ = await run() }
                                    } else {
                                        _ = await run()
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Destroy…", role: .destructive) {
                            Task {
                                let warning = kind == "mgr" ? nil : await CephSafety.check(session, host: host, service: kind, id: name, action: "destroy")
                                session.confirmDelete("Destroy \(kind).\(name)?",
                                                      message: (warning.map { "Ceph warns: \($0). " } ?? "") + "The \(singular) on \(host) is removed from the Ceph cluster.",
                                                      path: "/nodes/\(host.enc)/ceph/\(kind)/\(name.enc)")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                }
            }
            if daemons.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
        } accessory: {
            HStack(spacing: 14) {
                Button("Restart All…") {
                    session.confirmation = Confirmation(
                        title: "Restart every \(singular)?",
                        message: "A rolling restart across the cluster: each \(singular) restarts only after the previous one is back and Ceph is healthy.",
                        actionTitle: "Restart All", destructive: false) {
                            await session.run("Restart all \(title.lowercased())", .post, "/cluster/ceph/restart-bulk", ["service-type": kind])
                        }
                }
                .disabled(daemons.isEmpty)
                Button("Create…") { adding = true }
            }
            .buttonStyle(.link)
        }
        .task(id: session.revision) { daemons = (try? await session.client.list("/nodes/\(node.enc)/ceph/\(kind)")) ?? [] }
        .sheet(isPresented: $adding) {
            let free = session.onlineNodes.filter { candidate in !daemons.contains { $0.string("host") == candidate } }
            FormSheet(title: "Create \(singular)", message: free.isEmpty ? "Every online node already runs a \(singular)." : nil,
                      fields: [FormField(key: "node", label: "Node", kind: .choice(free.map { FormField.Choice($0) }), required: true)],
                      initial: ["node": free.first ?? ""], submitTitle: "Create") { result in
                await session.run("Create \(kind).\(result["node"])", .post, "/nodes/\(result["node"].enc)/ceph/\(kind)/\(result["node"].enc)")
            }
        }
    }

    static func healthy(_ daemon: JSONObject) -> Bool {
        let state = daemon.string("state") ?? ""
        return jsonBool(daemon["quorum"]) || ["running", "active", "standby"].contains { state.contains($0) }
    }
}

// MARK: OSDs

/// The OSDs in the cluster, with in/out, start/stop, scrub and destroy. Actions run on the OSD's own node.
struct CephOSDs: View {
    @Environment(Session.self) private var session
    let node: String
    @State private var osds: [JSONObject] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(osds.enumerated()), id: \.offset) { _, osd in
                let id = osd.int("id") ?? 0
                let host = osd.string("host") ?? node
                let isIn = jsonBool(osd["in"])
                let isUp = osd.string("status") == "up"
                let path = "/nodes/\(host.enc)/ceph"
                HStack {
                    Circle().fill(isUp ? Color.green : .red).frame(width: 8, height: 8)
                    Text(osd.string("name") ?? "osd.\(id)").fontWeight(.medium)
                    Text([host, osd.string("device_class")].compactMap { $0 }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text(isUp ? "up" : "down").foregroundStyle(isUp ? Color.secondary : .red)
                    Text(isIn ? "in" : "out").foregroundStyle(isIn ? Color.secondary : .orange)
                    Menu {
                        Button(isIn ? "Mark Out" : "Mark In") {
                            Task { await session.run("Mark osd.\(id) \(isIn ? "out" : "in")", .post, "\(path)/osd/\(id)/\(isIn ? "out" : "in")") }
                        }
                        Button(isUp ? "Stop" : "Start") {
                            let run = { await session.run("\(isUp ? "Stop" : "Start") osd.\(id)", .post, "\(path)/\(isUp ? "stop" : "start")", ["service": "osd.\(id)"]) }
                            Task {
                                if isUp, let warning = await CephSafety.check(session, host: host, service: "osd", id: String(id), action: "stop") {
                                    session.confirmation = Confirmation(title: "Stop osd.\(id)?", message: "Ceph warns: \(warning)", actionTitle: "Stop Anyway", destructive: true) { _ = await run() }
                                } else {
                                    _ = await run()
                                }
                            }
                        }
                        Button("Restart") { Task { await session.run("Restart osd.\(id)", .post, "\(path)/restart", ["service": "osd.\(id)"]) } }
                        Divider()
                        Button("Scrub") { Task { await session.run("Scrub osd.\(id)", .post, "\(path)/osd/\(id)/scrub") } }
                        Button("Deep Scrub") { Task { await session.run("Deep scrub osd.\(id)", .post, "\(path)/osd/\(id)/scrub", ["deep": "1"]) } }
                        Divider()
                        Button("Destroy…", role: .destructive) {
                            Task {
                                let warning = await CephSafety.check(session, host: host, service: "osd", id: String(id), action: "destroy")
                                session.confirmDelete("Destroy osd.\(id)?", message: (warning.map { "Ceph warns: \($0). " } ?? "") + "Its data is wiped from the disk.",
                                                      path: "\(path)/osd/\(id)", params: ["cleanup": "1"])
                            }
                        }
                        .disabled(isIn || isUp)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                }
                .monospacedDigit()
            }
            if osds.isEmpty { Text("No OSDs yet. Each OSD is a whole disk Ceph stores data on.").foregroundStyle(.secondary) }
        }
        .task(id: session.revision) { osds = Self.flatten((try? await session.client.object("/nodes/\(node.enc)/ceph/osd"))?.object("root") ?? [:]) }
    }

    /// The OSD endpoint returns a CRUSH tree; collect its OSD leaves with their host.
    static func flatten(_ node: JSONObject, host: String? = nil) -> [JSONObject] {
        let here = node.string("type") == "host" ? node.string("name") : host
        if node.string("type") == "osd" {
            var osd = node
            osd["host"] = osd["host"] ?? here
            return [osd]
        }
        return node.objects("children").flatMap { flatten($0, host: here) }
    }
}

private struct CephOSDSheet: View {
    @Environment(Session.self) private var session
    let node: String

    var body: some View {
        Prepared(load: {
            let unused = (try? await session.client.list("/nodes/\(node.enc)/disks/list", ["type": "unused"])) ?? []
            let fast = (try? await session.client.list("/nodes/\(node.enc)/disks/list", ["type": "journal_disks"])) ?? []
            return (unused.map(Self.choice), fast.map(Self.choice))
        }) { disks in
            let (unused, fast) = disks
            FormSheet(title: "Create OSD on \(node)",
                      message: unused.isEmpty ? "\(node) has no unused disks. Wipe one under Disks first." : "The whole disk becomes the OSD. For spinning disks, a DB on an SSD speeds things up.",
                      fields: [
                FormField(key: "dev", label: "Disk", kind: .choice(unused), required: true),
                FormField(key: "crush-device-class", label: "Device class", kind: .choice([.init("hdd", "HDD"), .init("ssd", "SSD"), .init("nvme", "NVMe")]), prompt: "Detect"),
                FormField(key: "db_dev", label: "DB disk", kind: .choice(fast), prompt: "Same disk"),
                FormField(key: "wal_dev", label: "WAL disk", kind: .choice(fast), prompt: "Same disk"),
                FormField(key: "encrypted", label: "Encrypt", kind: .toggle),
            ], initial: ["dev": unused.first?.value ?? ""], submitTitle: "Create") { result in
                var params = result.changed
                if params["encrypted"] == "0" { params["encrypted"] = nil }
                return await session.run("Create an OSD on \(result["dev"])", .post, "/nodes/\(node.enc)/ceph/osd", params)
            }
        }
    }

    static func choice(_ disk: JSONObject) -> FormField.Choice {
        let path = disk.string("devpath") ?? ""
        return .init(path, [path, disk.text("model"), Format.bytes(disk.int64("size"))].compactMap { $0 }.joined(separator: "  "))
    }
}

// MARK: Pools and CephFS

private struct CephPools: View {
    @Environment(Session.self) private var session
    let node: String
    @State private var pools: [JSONObject] = []
    @State private var editing: JSONObject?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(pools.enumerated()), id: \.offset) { _, pool in
                let name = pool.string("pool_name") ?? pool.string("name") ?? ""
                Meter(title: name, fraction: pool.double("percent_used") ?? 0, color: Theme.disk,
                      detail: "\(Format.bytes(pool.int64("bytes_used"))) used, \(pool.string("size") ?? "?") copies (at least \(pool.string("min_size") ?? "?")), \(pool.string("pg_num") ?? "?") PGs")
                    .contentShape(.rect)
                    .contextMenu {
                        Button("Edit…") { editing = pool }
                        Divider()
                        Button("Delete Pool…", role: .destructive) {
                            session.confirmDelete("Delete pool \(name)?", message: "All data in the pool is destroyed, and storages that use it are removed.",
                                                  path: "/nodes/\(node.enc)/ceph/pool/\(name.enc)", params: ["remove_storages": "1"])
                        }
                    }
            }
            if pools.isEmpty { Text("No pools.").foregroundStyle(.secondary) }
        }
        .task(id: session.revision) { pools = (try? await session.client.list("/nodes/\(node.enc)/ceph/pool")) ?? [] }
        .sheet(item: Binding(get: { editing.map { Row(id: $0.string("pool_name") ?? "", json: $0) } }, set: { editing = $0?.json })) { pool in
            FormSheet(title: "Edit \(pool.id)", fields: [
                FormField(key: "size", label: "Replicas", kind: .number),
                FormField(key: "min_size", label: "Minimum replicas", kind: .number),
                FormField(key: "pg_autoscale_mode", label: "PG autoscaler", kind: .choice([.init("on", "On"), .init("warn", "Warn"), .init("off", "Off")])),
                FormField(key: "pg_num", label: "Placement groups", kind: .number),
            ], initial: ["size": pool["size"] ?? "", "min_size": pool["min_size"] ?? "", "pg_autoscale_mode": pool["pg_autoscale_mode"] ?? "", "pg_num": pool["pg_num"] ?? ""],
                      isEdit: true) { result in
                await session.run("Save pool \(pool.id)", .put, "/nodes/\(node.enc)/ceph/pool/\(pool.id.enc)", result.changed)
            }
        }
    }
}

struct CephPoolSheet: View {
    @Environment(Session.self) private var session
    let node: String

    var body: some View {
        Prepared(load: { ((try? await session.client.list("/nodes/\(node.enc)/ceph/rules")) ?? []).compactMap { $0.text("name") } }) { rules in
            FormSheet(title: "Create Ceph pool", fields: [
                FormField(key: "name", label: "Name", prompt: "vm-pool", required: true),
                FormField(key: "size", label: "Replicas", kind: .number, prompt: "3"),
                FormField(key: "min_size", label: "Minimum replicas", kind: .number, prompt: "2"),
                FormField(key: "crush_rule", label: "CRUSH rule", kind: .choice(rules.map { FormField.Choice($0) }), prompt: "replicated_rule",
                          help: "Which OSDs hold the data, e.g. only fast disks"),
                FormField(key: "pg_autoscale_mode", label: "PG autoscale", kind: .choice([.init("on", "On"), .init("warn", "Warn only"), .init("off", "Off")])),
                FormField(key: "pg_num", label: "Placement groups", kind: .number, prompt: "128", help: "Leave it to the autoscaler unless you know better"),
                FormField(key: "application", label: "Application", kind: .choice([.init("rbd", "RBD (VM disks)"), .init("cephfs", "CephFS"), .init("rgw", "Object gateway")])),
                FormField(key: "add_storages", label: "Add as storage", kind: .toggle),
            ], initial: ["size": "3", "min_size": "2", "application": "rbd", "add_storages": "1", "pg_autoscale_mode": "on"], submitTitle: "Create") { result in
                var params = result.changed
                if params["add_storages"] == "0" { params["add_storages"] = nil }
                return await session.run("Create pool \(result["name"])", .post, "/nodes/\(node.enc)/ceph/pool", params)
            }
        }
    }
}

/// Ceph's own verdict on stopping or destroying a daemon (`ok-to-stop` / `safe-to-destroy`), as the web UI asks before doing it.
enum CephSafety {
    /// A warning if Ceph says the action isn't safe right now; nil when it's safe or the check isn't available.
    static func check(_ session: Session, host: String, service: String, id: String, action: String) async -> String? {
        guard let result = try? await session.client.object("/nodes/\(host.enc)/ceph/cmd-safety", ["service": service, "id": id, "action": action]),
              !result.bool("safe") else { return nil }
        return result.text("status") ?? "it isn't safe right now"
    }
}

/// A rolling restart of OSDs, one at a time, waiting for each to come back: the whole cluster's or this node's.
private struct CephRestartOSDsSheet: View {
    @Environment(Session.self) private var session
    let node: String

    var body: some View {
        FormSheet(title: "Restart OSDs", message: "Each OSD restarts only after the previous one is back up and Ceph reports it healthy.", fields: [
            FormField(key: "scope", label: "Which OSDs", kind: .choice([.init("node", "On \(node)"), .init("cluster", "All in the cluster")]), required: true),
            FormField(key: "only-outdated", label: "Only OSDs running an older version", kind: .toggle, help: "For finishing a Ceph upgrade"),
            FormField(key: "set-noout", label: "Set noout while restarting", kind: .toggle, help: "Keeps Ceph from rebalancing data meanwhile (this node only)"),
            FormField(key: "dry-run", label: "Only show the plan", kind: .toggle, help: "Writes which OSDs would restart, in order, to the task log"),
        ], initial: ["scope": "node", "set-noout": "1"], submitTitle: "Restart") { result in
            var params = ["service-type": "osd"]
            for key in ["only-outdated", "dry-run"] where result[key] == "1" { params[key] = "1" }
            if result["scope"] == "node" {
                if result["set-noout"] == "1" { params["set-noout"] = "1" }
                return await session.run("Restart the OSDs on \(node)", .post, "/nodes/\(node.enc)/ceph/restart-bulk", params)
            }
            return await session.run("Restart all OSDs", .post, "/cluster/ceph/restart-bulk", params)
        }
    }
}

private struct CephFilesystems: View {
    @Environment(Session.self) private var session
    let node: String
    let create: () -> Void
    @State private var filesystems: [JSONObject] = []

    var body: some View {
        Card(title: "CephFS", systemImage: "folder") {
            ForEach(Array(filesystems.enumerated()), id: \.offset) { _, fs in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fs.string("name") ?? "").fontWeight(.medium)
                    Text("Data in \(fs.string("data_pool") ?? "?"), metadata in \(fs.string("metadata_pool") ?? "?")").font(.callout).foregroundStyle(.secondary)
                }
            }
            if filesystems.isEmpty { Text("No file systems. Create a metadata server first.").foregroundStyle(.secondary) }
        } accessory: {
            Button("Create…", action: create).buttonStyle(.link)
        }
        .task(id: session.revision) { filesystems = (try? await session.client.list("/nodes/\(node.enc)/ceph/fs")) ?? [] }
    }
}

private struct CephFSSheet: View {
    @Environment(Session.self) private var session
    let node: String

    var body: some View {
        FormSheet(title: "Create CephFS", message: "Needs a metadata server. Proxima creates its data and metadata pools.", fields: [
            FormField(key: "name", label: "Name", prompt: "cephfs", required: true),
            FormField(key: "pg_num", label: "Placement groups", kind: .number, prompt: "128"),
            FormField(key: "add-storage", label: "Add as storage", kind: .toggle),
        ], initial: ["name": "cephfs", "add-storage": "1"], submitTitle: "Create") { result in
            var params = result.changed
            params["name"] = nil
            if params["add-storage"] == "0" { params["add-storage"] = nil }
            return await session.run("Create CephFS \(result["name"])", .post, "/nodes/\(node.enc)/ceph/fs/\(result["name"].enc)", params)
        }
    }
}

/// Read-only views of ceph.conf, the configuration database, the CRUSH map and the cluster log.
private struct CephConfigSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let node: String
    @State private var section = "conf"
    @State private var text = ""
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Ceph configuration").font(.title2.bold())
                Spacer()
                Picker("Show", selection: $section) {
                    Text("ceph.conf").tag("conf")
                    Text("Database").tag("db")
                    Text("CRUSH Map").tag("crush")
                    Text("Log").tag("log")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty && !loading ? "Nothing to show." : text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
            .overlay { if loading { ProgressView().controlSize(.small) } }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 760, height: 560)
        .task(id: section) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let path = "/nodes/\(node.enc)/ceph"
        do {
            switch section {
            case "db":
                text = try await session.client.list(path + "/cfg/db").map { row in
                    "[\(row.string("section") ?? "global")] \(row.string("name") ?? "") = \(row.string("value") ?? "")"
                }.joined(separator: "\n")
            case "crush": text = try await session.client.get(path + "/crush") as? String ?? ""
            case "log": text = try await session.client.list(path + "/log", ["limit": "500"]).compactMap { $0.string("t") }.joined(separator: "\n")
            default: text = try await session.client.get(path + "/cfg/raw") as? String ?? ""
            }
        } catch {
            text = "Couldn't load this: \(error.localizedDescription)"
        }
    }
}

