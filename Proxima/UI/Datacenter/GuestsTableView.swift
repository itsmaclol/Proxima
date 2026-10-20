import SwiftUI

nonisolated extension Resource {
    /// Running first, then paused, stopped, templates — for sorting by status.
    var statusRank: Int {
        if isTemplate { return 3 }
        switch power {
        case .running: return 0
        case .paused: return 1
        case .stopped: return 2
        case .unknown: return 4
        }
    }
    var sortName: String { displayName.lowercased() }
    var tagText: String { tags.joined(separator: " ") }
}

/// Every VM and container in one sortable table.
struct GuestsTableView: View {
    @Environment(Session.self) private var session
    @State private var selection = Set<Resource.ID>()
    @State private var sortOrder = [KeyPathComparator(\Resource.vmid)]
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", running = "Running", stopped = "Stopped", vms = "VMs", containers = "Containers", templates = "Templates"
        var id: String { rawValue }
    }

    var body: some View {
        let rows = filtered.sorted(using: sortOrder)
        VStack(spacing: 0) {
            Hero(title: "Guests", subtitle: "\(Format.count(session.guests.count, "guest")) across \(Format.count(session.nodes.count, "node"))",
                 symbol: "square.stack.3d.up", colors: [.green, .teal]) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("", value: \.statusRank) { guest in StatusGlyph(power: guest.power, isTemplate: guest.isTemplate) }
                    .width(18)
                TableColumn("ID", value: \.vmid) { guest in Text(String(guest.vmid)).monospacedDigit().foregroundStyle(.secondary) }
                    .width(min: 44, ideal: 56)
                TableColumn("Name", value: \.sortName) { guest in
                    Label {
                        Text(guest.displayName).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: guest.isTemplate ? "square.on.square.dashed" : (guest.kind?.symbol ?? "questionmark"))
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 140, ideal: 220)
                TableColumn("Node", value: \.node) { guest in Text(guest.node).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(guest.node) }
                    .width(min: 60, ideal: 90)
                TableColumn("CPU", value: \.cpu) { guest in
                    if guest.power == .running {
                        HStack(spacing: 8) {
                            UsageBar(fraction: guest.cpu, color: Theme.cpu, height: 5)
                            Text(Format.percent(guest.cpu)).monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                .width(min: 90, ideal: 120)
                TableColumn("Memory", value: \.mem) { guest in
                    if guest.power == .running, guest.maxmem > 0 {
                        HStack(spacing: 8) {
                            UsageBar(fraction: guest.memFraction, color: Theme.memory, height: 5)
                            Text(Format.bytes(guest.mem)).monospacedDigit().lineLimit(1).frame(minWidth: 64, alignment: .trailing)
                        }
                        .help("\(Format.bytes(guest.mem)) of \(Format.bytes(guest.maxmem))")
                    } else {
                        Text(Format.bytes(guest.maxmem)).foregroundStyle(.secondary)
                    }
                }
                .width(min: 120, ideal: 190)
                TableColumn("Disk", value: \.maxdisk) { guest in Text(Format.bytes(guest.maxdisk)).monospacedDigit().foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 80)
                TableColumn("Uptime", value: \.uptime) { guest in
                    Text(guest.power == .running ? Format.duration(guest.uptime) : "–").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Tags", value: \.tagText) { guest in TagRow(tags: guest.tags, limit: 2).help(guest.tags.joined(separator: ", ")) }
                    .width(min: 80, ideal: 180)
            }
            .contextMenu(forSelectionType: Resource.ID.self) { ids in
                let picked = rows.filter { ids.contains($0.id) }
                if picked.count == 1, let guest = picked.first {
                    GuestMenuItems(actions: GuestActions(session: session, guest: guest))
                } else if picked.count > 1 {
                    bulkItems(picked)
                }
            } primaryAction: { ids in
                if ids.count == 1, let guest = rows.first(where: { ids.contains($0.id) }) { session.selection = .guest(guest.vmid) }
            }
            .overlay {
                if rows.isEmpty && session.loaded {
                    ContentUnavailableView("No guests", systemImage: "square.stack.3d.up.slash", description: Text("Nothing matches this filter."))
                }
            }
        }
        .toolbar {
            if selection.count > 1 {
                ToolbarItemGroup {
                    let picked = rows.filter { selection.contains($0.id) }
                    Button("Start", systemImage: "play.fill") { bulk(picked, "start") }
                    Button("Shut Down", systemImage: "power") { bulk(picked, "shutdown") }
                    Menu("More", systemImage: "ellipsis") { bulkItems(picked) }
                }
            } else {
                ToolbarItem {
                    Menu("Bulk Actions", systemImage: "square.stack.3d.up") {
                        Button("Start Guests…") { session.sheet = .bulk(action: "start", node: nil, vmids: []) }
                        Button("Shut Down Guests…") { session.sheet = .bulk(action: "shutdown", node: nil, vmids: []) }
                        Button("Suspend Guests…") { session.sheet = .bulk(action: "suspend", node: nil, vmids: []) }
                        if session.isCluster {
                            Button("Migrate Guests…") { session.sheet = .bulk(action: "migrate", node: nil, vmids: []) }
                        }
                    }
                }
            }
        }
    }

    private var filtered: [Resource] {
        session.guests.filter { guest in
            switch filter {
            case .all: true
            case .running: guest.power == .running
            case .stopped: guest.power == .stopped && !guest.isTemplate
            case .vms: guest.kind == .qemu && !guest.isTemplate
            case .containers: guest.kind == .lxc && !guest.isTemplate
            case .templates: guest.isTemplate
            }
        }
    }

    @ViewBuilder private func bulkItems(_ guests: [Resource]) -> some View {
        Button("Start \(guests.count) Guests") { bulk(guests, "start") }
        Button("Shut Down \(guests.count) Guests") { bulk(guests, "shutdown") }
        Button("Reboot \(guests.count) Guests") { bulk(guests, "reboot") }
        Button("Suspend \(guests.count) Guests…") { session.sheet = .bulk(action: "suspend", node: nil, vmids: guests.map(\.vmid)) }
        if session.isCluster {
            Button("Migrate \(guests.count) Guests…") { session.sheet = .bulk(action: "migrate", node: nil, vmids: guests.map(\.vmid)) }
        }
        Divider()
        Button("Stop \(guests.count) Guests…") {
            session.confirmation = Confirmation(title: "Stop \(guests.count) guests immediately?",
                                                message: "This cuts their power without a clean shutdown.",
                                                actionTitle: "Stop All", destructive: true) {
                bulk(guests, "stop")
            }
        }
    }

    private func bulk(_ guests: [Resource], _ action: String) {
        let eligible = guests.filter { guest in
            guard !guest.isTemplate else { return false }
            return action == "start" ? guest.power == .stopped : guest.power == .running || (action == "stop" && guest.power == .paused)
        }
        for guest in eligible {
            Task { await GuestActions(session: session, guest: guest).power(action) }
        }
    }
}
