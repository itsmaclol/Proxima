import SwiftUI

/// The resource tree: overview items, then nodes with their guests and storage, then datacenter settings.
struct SidebarView: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebar.grouping") private var grouping = Grouping.nodes
    @AppStorage("sidebar.templates") private var showTemplates = true
    @State private var collapsedNodes: Set<String> = []

    enum Grouping: String, CaseIterable, Identifiable {
        case nodes = "Nodes", types = "Type", tags = "Tags", pools = "Pools"
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var session = session
        List(selection: $session.selection) {
            Section {
                Label("Overview", systemImage: "square.grid.2x2").tag(Place.overview)
                Label("Guests", systemImage: "square.stack.3d.up").badge(session.guests.count).tag(Place.guests)
                Label("Tasks", systemImage: "list.bullet.rectangle.portrait")
                    .badge(session.runningTaskCount)
                    .tag(Place.tasks)
            }

            if !session.search.isEmpty {
                searchResults
            } else {
                switch grouping {
                case .nodes: nodeTree
                case .types: typeSections
                case .tags: tagSections
                case .pools: poolSections
                }
            }

            Section("Datacenter") {
                Label("Backups", systemImage: "clock.arrow.circlepath").tag(Place.backups)
                Label("Replication", systemImage: "arrow.triangle.2.circlepath").tag(Place.replication)
                Label("Storage", systemImage: "externaldrive.connected.to.line.below").tag(Place.storageConfig)
                Label("Permissions", systemImage: "person.2").tag(Place.permissions)
                Label("High Availability", systemImage: "heart.text.square").tag(Place.ha)
                Label("Firewall", systemImage: "shield.lefthalf.filled").tag(Place.firewall)
                Label("SDN", systemImage: "point.3.connected.trianglepath.dotted").tag(Place.sdn)
                Label("Options", systemImage: "gearshape").tag(Place.options)
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: Place.self) { places in
            if let place = places.first, places.count == 1 { menu(for: place) }
        } primaryAction: { places in
            guard places.count == 1, case .guest(let vmid) = places.first, let guest = session.guest(vmid), !guest.isTemplate else { return }
            openWindow(id: "console", value: ConsoleTarget(guest: guest))
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Group by", selection: $grouping) {
                        ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Toggle("Show Templates", isOn: $showTemplates)
                } label: {
                    Label("View Options", systemImage: "line.3.horizontal.decrease")
                }
                .menuIndicator(.hidden)
            }
        }
        .overlay {
            if !session.loaded {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: Groupings

    private var visibleGuests: [Resource] {
        session.guests.filter { showTemplates || !$0.isTemplate }
    }

    /// Node rows stay selectable; their own chevron collapses the guests and storage beneath.
    private var nodeTree: some View {
        Section("Nodes") {
            ForEach(session.nodes) { node in
                let open = !collapsedNodes.contains(node.node)
                HStack(spacing: 4) {
                    Button {
                        if open { collapsedNodes.insert(node.node) } else { collapsedNodes.remove(node.node) }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 14, height: 14)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(open ? "Collapse \(node.node)" : "Expand \(node.node)")
                    NodeRow(node: node)
                }
                .tag(Place.node(node.node))
                if open {
                    ForEach(visibleGuests.filter { $0.node == node.node }) { guest in
                        GuestRow(guest: guest).padding(.leading, 18).tag(Place.guest(guest.vmid))
                    }
                    ForEach(session.storages(on: node.node)) { storage in
                        StorageRow(storage: storage).padding(.leading, 18).tag(Place.storage(node: storage.node, id: storage.storage))
                    }
                }
            }
        }
    }

    @ViewBuilder private var typeSections: some View {
        Section("Nodes") {
            ForEach(session.nodes) { NodeRow(node: $0).tag(Place.node($0.node)) }
        }
        Section("Virtual Machines") {
            ForEach(visibleGuests.filter { $0.kind == .qemu && !$0.isTemplate }) { GuestRow(guest: $0, showNode: true).tag(Place.guest($0.vmid)) }
        }
        Section("Containers") {
            ForEach(visibleGuests.filter { $0.kind == .lxc && !$0.isTemplate }) { GuestRow(guest: $0, showNode: true).tag(Place.guest($0.vmid)) }
        }
        if showTemplates, session.guests.contains(where: \.isTemplate) {
            Section("Templates") {
                ForEach(session.guests.filter(\.isTemplate)) { GuestRow(guest: $0, showNode: true).tag(Place.guest($0.vmid)) }
            }
        }
        Section("Storage") {
            ForEach(session.resources.filter(\.isStorage).sorted { ($0.storage, $0.node) < ($1.storage, $1.node) }) { storage in
                StorageRow(storage: storage, showNode: true).tag(Place.storage(node: storage.node, id: storage.storage))
            }
        }
    }

    @ViewBuilder private var tagSections: some View {
        ForEach(session.allTags, id: \.self) { tag in
            Section {
                ForEach(visibleGuests.filter { $0.tags.contains(tag) }) { GuestRow(guest: $0, showNode: true).tag(Place.guest($0.vmid)) }
            } header: {
                HStack(spacing: 6) {
                    Circle().fill(Theme.tag(tag)).frame(width: 7, height: 7)
                    Text(tag)
                }
            }
        }
        let untagged = visibleGuests.filter(\.tags.isEmpty)
        if !untagged.isEmpty {
            Section("No Tags") {
                ForEach(untagged) { GuestRow(guest: $0, showNode: true).tag(Place.guest($0.vmid)) }
            }
        }
    }

    @ViewBuilder private var poolSections: some View {
        ForEach(session.pools, id: \.self) { pool in
            Section {
                Label("Pool details", systemImage: "tray.2").foregroundStyle(.secondary).tag(Place.pool(pool))
                ForEach(visibleGuests.filter { $0.pool == pool }) { GuestRow(guest: $0, showNode: true).tag(Place.guest($0.vmid)) }
            } header: {
                Text(pool)
            }
        }
        let loose = visibleGuests.filter(\.pool.isEmpty)
        if !loose.isEmpty {
            Section("Not in a Pool") {
                ForEach(loose) { GuestRow(guest: $0, showNode: true).tag(Place.guest($0.vmid)) }
            }
        }
    }

    private var searchResults: some View {
        let query = session.search.lowercased()
        let guests = session.guests.filter { guest in
            guest.displayName.lowercased().contains(query) || String(guest.vmid).hasPrefix(query)
                || guest.tags.contains { $0.lowercased().contains(query) } || guest.node.lowercased().contains(query)
        }
        let nodes = session.nodes.filter { $0.node.lowercased().contains(query) }
        let storages = session.resources.filter { $0.isStorage && $0.storage.lowercased().contains(query) }
        return Section("Results") {
            ForEach(nodes) { NodeRow(node: $0).tag(Place.node($0.node)) }
            ForEach(guests) { GuestRow(guest: $0, showNode: true).tag(Place.guest($0.vmid)) }
            ForEach(storages) { StorageRow(storage: $0, showNode: true).tag(Place.storage(node: $0.node, id: $0.storage)) }
            if guests.isEmpty && nodes.isEmpty && storages.isEmpty {
                Text("No matches for “\(session.search)”").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func menu(for place: Place) -> some View {
        switch place {
        case .guest(let vmid):
            if let guest = session.guest(vmid) { GuestMenuItems(actions: GuestActions(session: session, guest: guest)) }
        case .node(let name):
            NodeMenuItems(session: session, node: name)
            Divider()
            Button("New Virtual Machine…", systemImage: "desktopcomputer") { session.sheet = .createVM(node: name) }
            Button("New Container…", systemImage: "shippingbox") { session.sheet = .createCT(node: name) }
        default:
            EmptyView()
        }
    }
}

// MARK: Rows

struct NodeRow: View {
    let node: Resource

    var body: some View {
        Label {
            HStack {
                Text(node.node).lineLimit(1).truncationMode(.middle).help(node.node)
                Spacer(minLength: 4)
                if node.isOnline {
                    Text(Format.percent(node.cpu))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Offline").font(.caption).foregroundStyle(.red)
                }
            }
        } icon: {
            Image(systemName: "server.rack")
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(node.isOnline ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(.background, lineWidth: 1))
                        .offset(x: 2, y: 2)
                }
        }
    }
}

struct GuestRow: View {
    let guest: Resource
    var showNode = false

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(guest.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(guest.power == .stopped || guest.isTemplate ? .secondary : .primary)
                if guest.lock != nil {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange).help("Locked: \(guest.lock ?? "")")
                }
                if guest.hastate != nil {
                    Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink.opacity(0.8)).help("Managed by HA")
                }
                Spacer(minLength: 4)
                if showNode {
                    Text(guest.node).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(String(guest.vmid))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        } icon: {
            Image(systemName: guest.isTemplate ? "square.on.square.dashed" : (guest.kind?.symbol ?? "questionmark"))
                .foregroundStyle(guest.isTemplate ? Color.purple : (guest.power == .running ? Color.primary : Color.secondary))
                .overlay(alignment: .bottomTrailing) {
                    if !guest.isTemplate {
                        StatusGlyph(power: guest.power, size: 6)
                            .background(Circle().fill(.background).padding(-1.5))
                            .offset(x: 3, y: 2)
                    }
                }
        }
        .help("\(guest.kind?.short ?? "") \(guest.vmid) · \(guest.power.label)")
    }
}

struct StorageRow: View {
    let storage: Resource
    var showNode = false

    var body: some View {
        Label {
            HStack {
                Text(storage.storage).lineLimit(1)
                Spacer(minLength: 4)
                if showNode { Text(storage.node).font(.caption).foregroundStyle(.tertiary) }
                if storage.maxdisk > 0 {
                    Text(Format.percent(storage.diskFraction))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.usage(storage.diskFraction, base: .secondary))
                }
            }
        } icon: {
            Image(systemName: storage.shared ? "externaldrive.connected.to.line.below" : "externaldrive")
                .foregroundStyle(storage.status == "available" ? .secondary : Color.red)
        }
    }
}
