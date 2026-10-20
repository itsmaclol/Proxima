import SwiftUI

/// A VM or container: header, section tabs and the selected section.
struct GuestView: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    let vmid: Int
    let kind: GuestKind

    @State private var status: GuestStatus?
    @State private var config: JSONObject = [:]
    @State private var pending: [JSONObject] = []
    @State private var configError: String?

    var body: some View {
        if let guest = session.guest(vmid) {
            page(guest)
        }
    }

    private func tabs(_ guest: Resource) -> [PageTab] {
        var tabs = [PageTab(id: "summary", title: "Summary", symbol: "gauge.with.dots.needle.33percent")]
        if !guest.isTemplate { tabs.append(PageTab(id: "console", title: "Console", symbol: "terminal")) }
        if kind == .qemu {
            tabs += [PageTab(id: "hardware", title: "Hardware", symbol: "cpu"),
                     PageTab(id: "cloudinit", title: "Cloud-Init", symbol: "cloud")]
        } else {
            tabs += [PageTab(id: "resources", title: "Resources", symbol: "cpu"),
                     PageTab(id: "network", title: "Network", symbol: "network"),
                     PageTab(id: "dns", title: "DNS", symbol: "globe")]
        }
        tabs.append(PageTab(id: "options", title: "Options", symbol: "slider.horizontal.3"))
        if kind == .qemu, guest.power == .running { tabs.append(PageTab(id: "monitor", title: "Monitor", symbol: "chevron.left.forwardslash.chevron.right")) }
        tabs += [
                 PageTab(id: "snapshots", title: "Snapshots", symbol: "camera"),
                 PageTab(id: "backups", title: "Backups", symbol: "clock.arrow.circlepath"),
                 PageTab(id: "replication", title: "Replication", symbol: "arrow.triangle.2.circlepath"),
                 PageTab(id: "tasks", title: "Tasks", symbol: "list.bullet.rectangle.portrait"),
                 PageTab(id: "firewall", title: "Firewall", symbol: "shield.lefthalf.filled"),
                 PageTab(id: "permissions", title: "Permissions", symbol: "person.2")]
        return tabs
    }

    private func page(_ guest: Resource) -> some View {
        @Bindable var session = session
        let tabs = tabs(guest)
        let power = status?.power ?? guest.power
        let tab = resolvedTab(tabs)
        return VStack(spacing: 0) {
            Hero(title: guest.displayName,
                 subtitle: "\(kind == .qemu ? "Virtual machine" : "Container") \(String(vmid)) on \(guest.node)",
                 symbol: guest.isTemplate ? "square.on.square.dashed" : kind.symbol,
                 colors: guest.isTemplate ? [.purple, .indigo] : Theme.aura(power)) {
                StatusBadge(power: power, isTemplate: guest.isTemplate)
                if power == .running { Pill(text: "Up \(Format.duration(status?.uptime ?? guest.uptime))", systemImage: "clock") }
                if let lock = status?.lock ?? guest.lock { Pill(text: "Locked: \(lock)", systemImage: "lock.fill", color: .orange) }
                if guest.hastate != nil || status?.haManaged == true { Pill(text: "HA", systemImage: "heart.fill", color: .pink) }
                if !config.isEmpty, !pending.filter({ $0["pending"] != nil || $0["delete"] != nil }).isEmpty {
                    Pill(text: "Changes pending reboot", systemImage: "arrow.clockwise.circle", color: .orange)
                }
                TagRow(tags: guest.tags, limit: 4)
            } trailing: {
                if power == .running {
                    HStack(spacing: 14) {
                        liveRing("CPU", fraction: status?.cpu ?? guest.cpu, color: Theme.cpu)
                        liveRing("Memory", fraction: memoryFraction(guest), color: Theme.memory)
                    }
                }
            }
            TabStrip(tabs: tabs, selection: $session.guestTab)
                .padding(.bottom, 6)
            if let configError, config.isEmpty {
                ErrorBanner(message: configError) { Task { await loadConfig(guest) } }.padding(24)
            }
            content(tab, guest: guest)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar(guest, power: power) }
        .polling(id: "\(vmid)-\(guest.node)-\(session.revision)", every: .seconds(3)) { await loadStatus(guest) }
        .task(id: "\(vmid)-\(guest.node)-\(session.revision)") { await loadConfig(guest) }
    }

    private func resolvedTab(_ tabs: [PageTab]) -> String {
        if tabs.contains(where: { $0.id == session.guestTab }) { return session.guestTab }
        let equivalents = ["hardware": "resources", "resources": "hardware", "cloudinit": "network", "network": "hardware", "dns": "options"]
        if let other = equivalents[session.guestTab], tabs.contains(where: { $0.id == other }) { return other }
        return "summary"
    }

    @ViewBuilder private func content(_ tab: String, guest: Resource) -> some View {
        switch tab {
        case "console": ConsoleView(target: ConsoleTarget(guest: guest)).id(guest.vmid)
        case "hardware": VMHardwareView(guest: guest, config: config, pending: pending)
        case "cloudinit": CloudInitView(guest: guest, config: config)
        case "resources": CTResourcesView(guest: guest, config: config, pending: pending)
        case "network": CTNetworkView(guest: guest, config: config)
        case "dns": CTDNSView(guest: guest, config: config)
        case "options": GuestOptionsView(guest: guest, config: config)
        case "monitor": MonitorView(guest: guest)
        case "snapshots": SnapshotsView(guest: guest)
        case "backups": GuestBackupsView(guest: guest)
        case "replication": ReplicationList(guest: guest.vmid)
        case "tasks": TaskHistory(node: guest.node, vmid: guest.vmid)
        case "firewall": FirewallView(scope: .guest(guest))
        case "permissions": PermissionsList(path: "/vms/\(guest.vmid)")
        default: GuestSummary(guest: guest, kind: kind, status: status, config: config)
        }
    }

    private func liveRing(_ title: String, fraction: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            MetricRing(fraction: fraction, color: color, lineWidth: 6)
                .frame(width: 58, height: 58)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func memoryFraction(_ guest: Resource) -> Double {
        guard let status, status.maxmem > 0 else { return guest.memFraction }
        return Double(status.mem) / Double(status.maxmem)
    }

    @ToolbarContentBuilder
    private func toolbar(_ guest: Resource, power: PowerState) -> some ToolbarContent {
        let actions = GuestActions(session: session, guest: guest)
        if !guest.isTemplate {
            ToolbarItemGroup {
                switch power {
                case .stopped:
                    Button("Start", systemImage: "play.fill") { Task { await actions.power("start") } }
                        .buttonStyle(.glassProminent)
                case .paused:
                    Button("Resume", systemImage: "play.fill") { Task { await actions.power("resume") } }
                        .buttonStyle(.glassProminent)
                default:
                    Button("Shut Down", systemImage: "power") { Task { await actions.power("shutdown") } }
                    Button("Reboot", systemImage: "arrow.clockwise") { Task { await actions.power("reboot") } }
                }
                Menu("Power", systemImage: "bolt.fill") { GuestPowerItems(actions: actions) }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Menu {
                    Button("Console Window", systemImage: "macwindow") { openWindow(id: "console", value: ConsoleTarget(guest: guest)) }
                    Button("SPICE in Remote Viewer", systemImage: "display") { Task { await actions.openSPICE() } }
                } label: {
                    Label("Console", systemImage: "macwindow")
                } primaryAction: {
                    openWindow(id: "console", value: ConsoleTarget(guest: guest))
                }
                .help("Open the console in its own window")
            }
        }
        ToolbarItem {
            Menu("More", systemImage: "ellipsis") { GuestMenuItems(actions: actions) }
        }
    }

    private func loadStatus(_ guest: Resource) async {
        guard let object = try? await session.client.object("/nodes/\(guest.node.enc)/\(guest.type)/\(vmid)/status/current") else { return }
        let fresh = GuestStatus(object)
        if fresh != status { status = fresh }
    }

    private func loadConfig(_ guest: Resource) async {
        do {
            let path = "/nodes/\(guest.node.enc)/\(guest.type)/\(vmid)"
            config = try await session.client.object(path + "/config")
            pending = (try? await session.client.list(path + "/pending")) ?? []
            configError = nil
        } catch {
            configError = error.localizedDescription
        }
    }
}

/// Markdown notes editor shared by guests, nodes and the datacenter.
struct NotesEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var text: String
    let save: (String) async -> Bool
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            Text("Markdown works: # headings, - lists, **bold**, `code`, [links](https://…).")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
                .frame(minHeight: 260)
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    Task {
                        busy = true
                        if await save(text.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                        busy = false
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 620, height: 460)
    }
}
