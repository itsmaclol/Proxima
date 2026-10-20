import Charts
import SwiftUI

/// The datacenter at a glance: live load with the last hour, what needs attention, nodes, guests, backups, storage and tasks.
struct OverviewView: View {
    @Environment(Session.self) private var session
    @State private var data = OverviewData()
    @State private var openedTask: TaskEntry?
    @State private var topMetric = TopMetric.cpu
    @State private var width: CGFloat = 1100

    enum TopMetric: String, CaseIterable, Identifiable {
        case cpu = "CPU", memory = "Memory", network = "Network", disk = "Disk"
        var id: String { rawValue }
    }

    var body: some View {
        let nodes = session.nodes
        let online = nodes.filter(\.isOnline)
        let guests = session.guests.filter { !$0.isTemplate }
        let running = guests.filter { $0.power == .running }
        let attention = data.attention(session)

        VStack(spacing: 0) {
            Hero(title: session.clusterName ?? session.server.displayName,
                 subtitle: subtitle(nodes: nodes.count),
                 symbol: "building.2", colors: [.orange, .indigo]) {
                health(attention)
                if let quorate = session.quorate {
                    Pill(text: quorate ? "Quorate" : "No quorum", systemImage: quorate ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                         color: quorate ? .green : .red)
                }
                Pill(text: "\(online.count) of \(Format.count(nodes.count, "node")) online", systemImage: "server.rack",
                     color: online.count == nodes.count ? .secondary : .orange)
                Pill(text: "\(running.count) of \(Format.count(guests.count, "guest")) running", systemImage: "play.fill", color: .green)
            } trailing: {
                HStack(spacing: 8) {
                    Button("New VM", systemImage: "desktopcomputer") { session.sheet = .createVM(node: nil) }
                    Button("New Container", systemImage: "shippingbox") { session.sheet = .createCT(node: nil) }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }

            Page {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: width >= 940 ? 4 : 2), spacing: 18) {
                    cpuTile(online)
                    memoryTile(online)
                    networkTile
                    storageTile
                }
                pair(attentionCard(attention), backupsCard(guests), trailing: 370)
                nodesCard(nodes)
                pair(guestsCard(guests), topGuestsCard(running), trailing: nil)
                pair(storageCard, recentTasks, trailing: 400)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        // Restarts when nodes come and go, so the first load doesn't wait for the next round.
        .polling(id: online.map(\.node), every: .seconds(30)) { await data.refresh(session) }
        .onChange(of: session.resources) { data.track(session.guests) }
        .sheet(item: $openedTask) { task in
            TaskLogSheet(upid: task.upid, node: task.node, title: task.title).environment(session)
        }
    }

    private func subtitle(nodes: Int) -> String {
        let version = session.version.isEmpty ? "Proxmox VE" : "Proxmox VE \(session.version)"
        return session.clusterName == nil ? "\(version), single node" : "\(version), \(nodes)-node cluster"
    }

    /// Two cards side by side when there's room, stacked when the window is narrow.
    @ViewBuilder private func pair(_ leading: some View, _ trailing: some View, trailing width: CGFloat?) -> some View {
        if self.width >= 940 {
            HStack(alignment: .top, spacing: 18) {
                leading
                if let width { trailing.frame(width: width) } else { trailing }
            }
        } else {
            VStack(spacing: 18) { leading; trailing }
        }
    }

    @ViewBuilder private func health(_ items: [OverviewData.Attention]) -> some View {
        let critical = items.filter { $0.severity == .critical }.count
        let warnings = items.filter { $0.severity == .warning }.count
        if critical > 0 {
            Pill(text: Format.count(critical, "problem"), systemImage: "exclamationmark.octagon.fill", color: .red)
        } else if warnings > 0 {
            Pill(text: Format.count(warnings, "warning"), systemImage: "exclamationmark.triangle.fill", color: .orange)
        } else if session.loaded {
            Pill(text: "Healthy", systemImage: "checkmark.circle.fill", color: .green)
        }
    }

    private func go(_ destination: OverviewData.Destination?) {
        switch destination {
        case .node(let node, let tab):
            session.nodeTab = tab
            session.selection = .node(node)
        case .storage(let node, let id): session.selection = .storage(node: node, id: id)
        case .backups: session.selection = .backups
        case .ha: session.selection = .ha
        case .task(let task): openedTask = task
        case nil: break
        }
    }

    // MARK: Live tiles

    private func cpuTile(_ online: [Resource]) -> some View {
        let cores = online.reduce(0) { $0 + $1.maxcpu }
        let cpu = cores > 0 ? online.reduce(0) { $0 + $1.cpu * $1.maxcpu } / cores : 0
        let statuses = online.compactMap { data.status[$0.node] }
        let wait = statuses.isEmpty ? nil : statuses.map(\.ioWait).reduce(0, +) / Double(statuses.count)
        let load = statuses.count == 1 ? statuses[0].loadavg.first.map { "load \($0.formatted(.number.precision(.fractionLength(2))))" } : nil
        return KPITile(title: "CPU", symbol: "cpu", color: Theme.cpu, value: Format.percent(cpu),
                       detail: (["\(Int(cores)) threads", load, wait.map { "IO delay \(Format.percent($0))" }].compactMap { $0 }).joined(separator: " · ")) {
            Sparkline(series: [.init(color: Theme.cpu, points: data.history.map { ChartPoint(date: $0.date, value: $0.cpu) })], ceiling: 1)
        }
    }

    private func memoryTile(_ online: [Resource]) -> some View {
        let used = online.reduce(Int64(0)) { $0 + $1.mem }
        let total = online.reduce(Int64(0)) { $0 + $1.maxmem }
        return KPITile(title: "Memory", symbol: "memorychip", color: Theme.memory, value: Format.percent(total > 0 ? Double(used) / Double(total) : 0),
                       detail: "\(Format.bytes(used)) of \(Format.bytes(total))") {
            Sparkline(series: [.init(color: Theme.memory, points: data.history.compactMap { sample in
                sample.memTotal > 0 ? ChartPoint(date: sample.date, value: sample.memUsed / sample.memTotal) : nil
            })], ceiling: 1)
        }
    }

    private var networkTile: some View {
        let latest = data.history.last
        return KPITile(title: "Network", symbol: "arrow.up.arrow.down", color: Theme.netIn,
                       value: latest.map { Format.rate($0.netIn + $0.netOut) } ?? "–",
                       detail: latest.map { "↓ \(Format.rate($0.netIn))  ↑ \(Format.rate($0.netOut))" } ?? "Last hour") {
            Sparkline(series: [.init(color: Theme.netIn, points: data.history.map { ChartPoint(date: $0.date, value: $0.netIn) }),
                               .init(color: Theme.netOut, points: data.history.map { ChartPoint(date: $0.date, value: $0.netOut) })])
        }
    }

    private var storageTile: some View {
        let storages = uniqueStorages.filter { $0.status == "available" && $0.maxdisk > 0 }
        let used = storages.reduce(Int64(0)) { $0 + $1.disk }
        let total = storages.reduce(Int64(0)) { $0 + $1.maxdisk }
        let fullest = storages.sorted { $0.diskFraction > $1.diskFraction }.prefix(2)
        return KPITile(title: "Storage", symbol: "externaldrive", color: Theme.disk, value: Format.percent(total > 0 ? Double(used) / Double(total) : 0),
                       detail: "\(Format.bytes(used)) of \(Format.bytes(total)) across \(Format.count(storages.count, "storage"))") {
            VStack(spacing: 7) {
                ForEach(Array(fullest)) { storage in
                    HStack(spacing: 8) {
                        // Local storages often share a name across nodes ("local-lvm"), so say whose it is.
                        Text(storage.shared || session.nodes.count < 2 ? storage.storage : "\(storage.storage) · \(storage.node)")
                            .font(.caption).lineLimit(1).truncationMode(.middle).frame(width: 104, alignment: .leading)
                        UsageBar(fraction: storage.diskFraction, color: Theme.disk, height: 5)
                        Text(Format.percent(storage.diskFraction)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// Shared storage shows up once per node; count it once.
    private var uniqueStorages: [Resource] {
        var seen = Set<String>()
        return session.resources.filter(\.isStorage).filter { seen.insert($0.shared ? $0.storage : $0.id).inserted }
    }

    // MARK: Attention and backups

    private func attentionCard(_ items: [OverviewData.Attention]) -> some View {
        Card(title: "Needs attention", systemImage: "exclamationmark.bubble") {
            if items.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Everything looks healthy").fontWeight(.medium)
                        Text("Nodes, storage, disks, certificates, backups and recent tasks all check out.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            VStack(spacing: 4) {
                ForEach(items.prefix(8)) { item in
                    Button { go(item.destination) } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.title3)
                                .foregroundStyle(color(item.severity))
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                Text(item.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            if item.destination != nil { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(color(item.severity).opacity(item.severity == .critical ? 0.07 : 0), in: .rect(cornerRadius: 10))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(item.detail)
                }
                if items.count > 8 {
                    Text("and \(items.count - 8) more").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } accessory: {
            if !items.isEmpty { Text("\(items.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
        }
    }

    private func color(_ severity: OverviewData.Attention.Severity) -> Color {
        switch severity {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    private func backupsCard(_ guests: [Resource]) -> some View {
        let known = data.notBackedUp != nil
        let covered = max(0, guests.count - (data.notBackedUp?.count ?? 0))
        let backups = session.clusterTasks.filter { $0.type == "vzdump" }
        let week = backups.filter { $0.start > .now.addingTimeInterval(-7 * 86_400) && !$0.isRunning }
        let failed = week.filter { !$0.succeeded && !$0.hasWarnings }.count
        return Card(title: "Backups", systemImage: "clock.arrow.circlepath") {
            HStack(spacing: 16) {
                MetricRing(fraction: !known || guests.isEmpty ? 0 : Double(covered) / Double(guests.count),
                           color: !known ? .secondary : covered == guests.count ? .green : .orange,
                           lineWidth: 7, label: known ? "\(covered)/\(guests.count)" : "–", fullIsBad: false)
                    .frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 3) {
                    Text(!known ? "Checking backup jobs…" : covered == guests.count ? "Every guest is covered" : "\(Format.count(guests.count - covered, "guest")) not covered")
                        .fontWeight(.medium)
                    Text("by a scheduled backup job").font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 8) {
                fact("Last backup", backups.first.map { task in
                    task.isRunning ? "Running now" : "\(Format.relative(task.start)) · \(task.succeeded ? "OK" : task.hasWarnings ? "with warnings" : "failed")"
                } ?? "None recently", color: backups.first.map { $0.isRunning || $0.succeeded ? Color.secondary : .orange } ?? .secondary)
                fact("Next run", data.nextBackup.map { "\($0.formatted(.dateTime.weekday(.abbreviated).hour().minute())) · \(Format.relative($0))" } ?? "No job scheduled")
                fact("Last 7 days", week.isEmpty ? "No backups" : "\(week.count - failed) succeeded\(failed > 0 ? " · \(failed) failed" : "")",
                     color: failed > 0 ? .orange : .secondary)
            }
        } accessory: {
            Button("Jobs") { session.selection = .backups }.buttonStyle(.link)
        }
    }

    private func fact(_ title: String, _ value: String, color: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(color == .secondary ? Color.primary : color).lineLimit(1).monospacedDigit()
        }
        .font(.callout)
    }

    // MARK: Nodes and guests

    private func nodesCard(_ nodes: [Resource]) -> some View {
        Card(title: "Nodes", systemImage: "server.rack") {
            VStack(spacing: 0) {
                ForEach(nodes) { node in
                    NodeBlade(node: node, guests: session.guests(on: node.node), status: data.status[node.node], updates: data.updates[node.node] ?? 0)
                    if node.id != nodes.last?.id { Divider().padding(.vertical, 12) }
                }
            }
        }
    }

    private func guestsCard(_ guests: [Resource]) -> some View {
        let running = guests.filter { $0.power == .running }.count
        let paused = guests.filter { $0.power == .paused }.count
        let stopped = guests.count - running - paused
        let vms = guests.filter { $0.kind == .qemu }, cts = guests.filter { $0.kind == .lxc }
        let slices: [(label: String, count: Int, color: Color)] = [("Running", running, .green), ("Paused", paused, .yellow), ("Stopped", stopped, Color.secondary.opacity(0.45))]
        let tags = Dictionary(grouping: session.guests.flatMap(\.tags), by: { $0 }).map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        return Card(title: "Guests", systemImage: "square.stack.3d.up") {
            HStack(spacing: 22) {
                Chart(slices.filter { $0.count > 0 }, id: \.label) { slice in
                    SectorMark(angle: .value("Guests", slice.count), innerRadius: .ratio(0.64), angularInset: 1.5)
                        .foregroundStyle(slice.color)
                        .cornerRadius(3)
                }
                .chartLegend(.hidden)
                .frame(width: 118, height: 118)
                .overlay {
                    VStack(spacing: 0) {
                        Text("\(guests.count)").font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                        Text("guests").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("\(running) running, \(paused) paused, \(stopped) stopped")
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(slices, id: \.label) { slice in
                        HStack(spacing: 8) {
                            Circle().fill(slice.color).frame(width: 8, height: 8)
                            Text(slice.label)
                            Spacer(minLength: 8)
                            Text("\(slice.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    HStack(spacing: 14) {
                        Label("\(vms.filter { $0.power == .running }.count)/\(vms.count) VMs", systemImage: "desktopcomputer")
                        Label("\(cts.filter { $0.power == .running }.count)/\(cts.count) CTs", systemImage: "shippingbox")
                        if session.guests.contains(where: \.isTemplate) {
                            Label("\(session.guests.filter(\.isTemplate).count)", systemImage: "square.on.square.dashed").help("Templates")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                }
                .frame(maxWidth: 280)
            }
            if !tags.isEmpty {
                // Clicking a tag filters the sidebar to the guests that carry it.
                FlowLayout(spacing: 6) {
                    ForEach(tags.prefix(14), id: \.name) { tag in
                        Button { session.search = tag.name } label: {
                            HStack(spacing: 4) {
                                TagChip(tag: tag.name)
                                Text("\(tag.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Show guests tagged \(tag.name)")
                    }
                }
            }
        }
    }

    private func topGuestsCard(_ running: [Resource]) -> some View {
        let ranked: [(guest: Resource, value: Double, text: String)] = running.compactMap { guest in
            switch topMetric {
            case .cpu: return (guest, guest.cpu, Format.percent(guest.cpu))
            case .memory: return (guest, guest.memFraction, Format.bytes(guest.mem))
            case .network: return data.rates[guest.id].map { (guest, $0.net, Format.rate($0.net)) }
            case .disk: return data.rates[guest.id].map { (guest, $0.disk, Format.rate($0.disk)) }
            }
        }
        .sorted { $0.value > $1.value }
        let top = Array(ranked.prefix(6))
        let peak = max(top.first?.value ?? 0, 1)
        let color: Color = switch topMetric {
        case .cpu: Theme.cpu
        case .memory: Theme.memory
        case .network: Theme.netIn
        case .disk: Theme.write
        }
        return Card(title: "Top guests", systemImage: "chart.bar.xaxis") {
            if top.isEmpty {
                Text(running.isEmpty ? "Nothing is running." : "Measuring… rates appear after the next refresh.").foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                ForEach(top, id: \.guest.id) { entry in
                    Button { session.selection = .guest(entry.guest.vmid) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: entry.guest.kind?.symbol ?? "questionmark").foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.guest.displayName).lineLimit(1).truncationMode(.middle)
                                Text(verbatim: "\(entry.guest.vmid) on \(entry.guest.node)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .help(entry.guest.displayName)
                            Spacer(minLength: 8)
                            // Percentages fill against 100%; rates against the busiest guest.
                            UsageBar(fraction: topMetric == .network || topMetric == .disk ? entry.value / peak : entry.value, color: color, height: 5)
                                .frame(width: 90)
                            Text(entry.text)
                                .font(.callout.monospacedDigit())
                                .frame(width: 76, alignment: .trailing)
                                .contentTransition(.numericText())
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        } accessory: {
            Picker("Rank by", selection: $topMetric) {
                ForEach(TopMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
    }

    // MARK: Storage and tasks

    private var recentTasks: some View {
        Card(title: "Recent tasks", systemImage: "list.bullet.rectangle.portrait") {
            VStack(spacing: 9) {
                ForEach(session.clusterTasks.prefix(8)) { task in
                    Button { openedTask = task } label: {
                        HStack(spacing: 10) {
                            TaskStatusIcon(task: task).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(task.title).lineLimit(1)
                                Text("\(task.node) · \(task.user)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(Format.relative(task.start)).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                if session.clusterTasks.isEmpty { Text("No recent tasks.").foregroundStyle(.secondary) }
            }
        } accessory: {
            Button("All Tasks") { session.selection = .tasks }.buttonStyle(.link)
        }
    }

    private var storageCard: some View {
        let storages = uniqueStorages.sorted { $0.diskFraction > $1.diskFraction }
        return Card(title: "Storage", systemImage: "externaldrive") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 18)], alignment: .leading, spacing: 16) {
                ForEach(storages) { storage in
                    Button { session.selection = .storage(node: storage.node, id: storage.storage) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: storage.shared ? "externaldrive.connected.to.line.below" : "externaldrive")
                                    .foregroundStyle(.secondary)
                                Text(storage.storage).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(StorageConfigView.types.first { $0.id == storage.plugin }?.name ?? storage.plugin)
                                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            UsageBar(fraction: storage.diskFraction, color: Theme.disk)
                            HStack {
                                Text(storage.status == "available" ? "\(Format.bytes(max(0, storage.maxdisk - storage.disk))) free" : "Unavailable")
                                    .foregroundStyle(storage.status == "available" ? Color.secondary : .orange)
                                Spacer()
                                Text("\(Format.percent(storage.diskFraction)) of \(Format.bytes(storage.maxdisk))").foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .monospacedDigit()
                            Text(storage.shared ? "Shared" : storage.node).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// A headline number with a detail line and a small picture of the last hour.
struct KPITile<Picture: View>: View {
    let title: String
    let symbol: String
    let color: Color
    let value: String
    let detail: String
    @ViewBuilder var picture: Picture

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(color)
                }
                Text(value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(detail)
                picture
                    .frame(height: 46)
                    .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A tiny area chart without axes, for the Overview's tiles.
struct Sparkline: View {
    struct Series {
        let color: Color
        let points: [ChartPoint]
    }

    let series: [Series]
    var ceiling: Double?

    var body: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { index, item in
                ForEach(item.points) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Value", point.value), series: .value("Series", index), stacking: .unstacked)
                        .foregroundStyle(LinearGradient(colors: [item.color.opacity(0.3), item.color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.date), y: .value("Value", point.value), series: .value("Series", index))
                        .foregroundStyle(item.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...yMax)
        .overlay {
            if series.allSatisfy({ $0.points.isEmpty }) {
                Text("Collecting the last hour…").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityHidden(true)
    }

    private var yMax: Double {
        if let ceiling { return ceiling }
        let peak = series.flatMap(\.points).map(\.value).max() ?? 0
        return peak > 0 ? peak * 1.15 : 1
    }
}

/// A node drawn like the front of a server: status, load meters and one light per guest.
struct NodeBlade: View {
    @Environment(Session.self) private var session
    let node: Resource
    let guests: [Resource]
    var status: NodeStatus?
    var updates = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 18) {
                Button { session.nodeTab = "summary"; session.selection = .node(node.node) } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(node.isOnline ? Color.green : Color.red)
                            .frame(width: 9, height: 9)
                            .shadow(color: (node.isOnline ? Color.green : Color.red).opacity(0.6), radius: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.node).font(.headline).lineLimit(1).truncationMode(.middle).help(node.node)
                            Text(node.isOnline ? "Up \(Format.duration(node.uptime))" : "Offline")
                                .font(.caption).foregroundStyle(node.isOnline ? Color.secondary : Color.red)
                        }
                    }
                    .frame(width: 170, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Meter(title: "CPU", fraction: node.cpu, color: Theme.cpu).frame(width: 130)
                Meter(title: "Memory", fraction: node.memFraction, color: Theme.memory, detail: Format.percent(node.memFraction)).frame(width: 130)

                FlowLayout(spacing: 5) {
                    ForEach(guests) { guest in
                        GuestLight(guest: guest)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let status, node.isOnline {
                // The hardware and health behind the meters, as in the node's summary.
                FlowLayout(spacing: 6) {
                    spec("cpu", status.cpuModel.isEmpty ? "\(status.cpus) threads" : "\(Self.shortModel(status.cpuModel)) · \(status.cpus) threads")
                    if let load = status.loadavg.first {
                        spec("gauge.with.dots.needle.50percent", "Load \(status.loadavg.prefix(3).map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " "))",
                             warn: load > Double(max(status.cpus, 1)))
                    }
                    spec("hourglass", "IO delay \(Format.percent(status.ioWait))", warn: status.ioWait > 0.1)
                    if status.swapTotal > 0 {
                        spec("memorychip", "Swap \(Format.bytes(status.swapUsed)) of \(Format.bytes(status.swapTotal))",
                             warn: Double(status.swapUsed) / Double(status.swapTotal) > 0.5)
                    }
                    spec("internaldrive", "Root \(Format.bytes(status.rootUsed)) of \(Format.bytes(status.rootTotal))",
                         warn: status.rootTotal > 0 && Double(status.rootUsed) / Double(status.rootTotal) > 0.85)
                    if !status.kernel.isEmpty { spec("terminal", "Kernel \(status.kernel.replacingOccurrences(of: "Linux ", with: ""))") }
                    if updates > 0 {
                        Button { session.nodeTab = "updates"; session.selection = .node(node.node) } label: {
                            spec("arrow.down.circle", Format.count(updates, "update"), tint: .blue)
                        }
                        .buttonStyle(.plain)
                        .help("Show the updates for \(node.node)")
                    }
                }
                .padding(.leading, 19)
            }
        }
        .opacity(node.isOnline ? 1 : 0.6)
    }

    private func spec(_ symbol: String, _ text: String, warn: Bool = false, tint: Color? = nil) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(warn ? Color.orange : tint ?? .secondary)
            .background((warn ? Color.orange : tint ?? .primary).opacity(warn || tint != nil ? 0.12 : 0.05), in: .capsule)
    }

    /// "Intel(R) Core(TM) i5-4570 CPU @ 3.20GHz" reads as "Intel Core i5-4570 @ 3.20GHz".
    static func shortModel(_ model: String) -> String {
        model.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "").replacingOccurrences(of: " CPU", with: "")
            .split(separator: " ").joined(separator: " ")
    }
}

/// One guest as a small status light; click to open it.
struct GuestLight: View {
    @Environment(Session.self) private var session
    let guest: Resource
    @State private var hovering = false

    var body: some View {
        Button { session.selection = .guest(guest.vmid) } label: {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(fill)
                .strokeBorder(stroke, lineWidth: guest.power == .running && !guest.isTemplate ? 0 : 1.3)
                .frame(width: 13, height: 13)
                .shadow(color: guest.power == .running && !guest.isTemplate ? Color.green.opacity(0.55) : .clear, radius: 2.5)
                .scaleEffect(hovering ? 1.25 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(guest.displayName) (\(guest.kind?.short ?? "") \(guest.vmid)) — \(guest.isTemplate ? "Template" : guest.power.label)")
        .accessibilityLabel("\(guest.displayName), \(guest.power.label)")
    }

    private var fill: Color {
        if guest.isTemplate { return .clear }
        switch guest.power {
        case .running: return .green
        case .paused: return .yellow
        case .unknown: return .red.opacity(0.8)
        case .stopped: return .clear
        }
    }

    private var stroke: Color {
        guest.isTemplate ? .purple : (guest.power == .stopped ? Color.secondary.opacity(0.7) : .clear)
    }
}

/// Wraps children onto new lines, left to right.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
