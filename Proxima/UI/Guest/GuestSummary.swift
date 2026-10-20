import AppKit
import SwiftUI

/// A VM or container at a glance: live vitals over the last hour, what it runs and how it's set up, how to reach it,
/// where its disks live, its notes, and its history.
struct GuestSummary: View {
    @Environment(Session.self) private var session
    let guest: Resource
    let kind: GuestKind
    let status: GuestStatus?
    let config: JSONObject

    @AppStorage("chart.timeframe") private var timeframe = Timeframe.hour
    @AppStorage("chart.maximum") private var maximum = false
    @State private var samples: [RRDPoint] = []
    /// The last hour for the tiles, whatever the charts below show.
    @State private var hour: [RRDPoint] = []
    @State private var facts = GuestFacts()
    @State private var editingNotes = false
    @State private var width: CGFloat = 1100

    private var power: PowerState { status?.power ?? guest.power }
    private var running: Bool { power == .running && !guest.isTemplate }
    private var base: String { "/nodes/\(guest.node.enc)/\(guest.type)/\(guest.vmid)" }
    private var agentEnabled: Bool {
        status?.agent ?? jsonBool(PropertyString(config.string("agent") ?? "", defaultKey: "enabled")["enabled"])
    }

    var body: some View {
        Page {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: width >= 940 ? 4 : 2), spacing: 18) {
                cpuTile
                memoryTile
                networkTile
                diskTile
            }
            if width >= 940 {
                // Two columns that fill independently, so a short card leaves no gap beside a tall one.
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) { detailsCard; storageCard }
                    VStack(spacing: 18) { networkCard; notesCard }.frame(width: 400)
                }
            } else {
                detailsCard
                networkCard
                storageCard
                notesCard
            }
            HStack {
                Text("Performance").font(.title3.weight(.semibold))
                Spacer()
                TimeframePicker(timeframe: $timeframe, useMaximum: $maximum)
            }
            .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                MetricChart(title: "CPU", series: [ChartSeries("CPU", color: Theme.cpu, from: samples) { $0["cpu"] }],
                            unit: .percent, ceiling: 1, timeframe: timeframe)
                MetricChart(title: "Memory", series: [ChartSeries("Used", color: Theme.memory, from: samples) { $0["mem"] }],
                            unit: .bytes, ceiling: Double(status?.maxmem ?? guest.maxmem), timeframe: timeframe)
                MetricChart(title: "Network", series: [ChartSeries("In", color: Theme.netIn, from: samples) { $0["netin"] },
                                                       ChartSeries("Out", color: Theme.netOut, from: samples) { $0["netout"] }],
                            unit: .rate, timeframe: timeframe)
                MetricChart(title: "Disk I/O", series: [ChartSeries("Read", color: Theme.read, from: samples) { $0["diskread"] },
                                                        ChartSeries("Write", color: Theme.write, from: samples) { $0["diskwrite"] }],
                            unit: .rate, timeframe: timeframe)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .polling(id: "\(guest.vmid)-\(timeframe)-\(maximum)", every: .seconds(30)) { await loadSamples() }
        .task(id: "\(guest.vmid)-\(power)-\(agentEnabled)-\(session.revision)") { await loadFacts() }
        .sheet(isPresented: $editingNotes) {
            NotesEditor(title: "Notes for \(guest.displayName)", text: config.string("description") ?? "") { text in
                await session.run("Save the notes", .put, base + "/config", text.isEmpty ? ["delete": "description"] : ["description": text])
            }
        }
    }

    // MARK: Live tiles

    private var cpuTile: some View {
        let unit = Format.count(Int(status?.cpus ?? guest.maxcpu), kind == .qemu ? "vCPU" : "core")
        let series = points("cpu")
        return KPITile(title: "CPU", symbol: "cpu", color: Theme.cpu, value: running ? Format.percent(status?.cpu ?? guest.cpu) : unit,
                       detail: running ? "of \(unit)" : "Not running") {
            // An idle guest still shows its rhythm: the scale starts at 5%.
            Sparkline(series: [.init(color: Theme.cpu, points: series)], ceiling: max((series.map(\.value).max() ?? 0) * 1.2, 0.05))
        }
    }

    private var memoryTile: some View {
        let used = status?.mem ?? guest.mem, total = status?.maxmem ?? guest.maxmem
        var detail = running ? "of \(Format.bytes(total)) · \(Format.percent(total > 0 ? Double(used) / Double(total) : 0))" : "Allocated, not running"
        if running, kind == .lxc, let status, status.swap > 0 { detail += " · swap \(Format.bytes(status.swap))" }
        return KPITile(title: "Memory", symbol: "memorychip", color: Theme.memory, value: running ? Format.bytes(used) : Format.bytes(total), detail: detail) {
            Sparkline(series: [.init(color: Theme.memory, points: points("mem"))], ceiling: total > 0 ? Double(total) : nil)
        }
    }

    private var networkTile: some View {
        let received = latest("netin"), sent = latest("netout")
        return KPITile(title: "Network", symbol: "arrow.up.arrow.down", color: Theme.netIn, value: running ? Format.rate(received + sent) : "–",
                       detail: running ? "↓ \(Format.rate(received))  ↑ \(Format.rate(sent))" : "Not running") {
            Sparkline(series: [.init(color: Theme.netIn, points: points("netin")), .init(color: Theme.netOut, points: points("netout"))])
        }
    }

    private var diskTile: some View {
        let read = latest("diskread"), written = latest("diskwrite")
        return KPITile(title: "Disk I/O", symbol: "internaldrive", color: Theme.disk, value: running ? Format.rate(read + written) : "–",
                       detail: running ? "R \(Format.rate(read))  W \(Format.rate(written))" : "Not running") {
            Sparkline(series: [.init(color: Theme.read, points: points("diskread")), .init(color: Theme.write, points: points("diskwrite"))])
        }
    }

    private func points(_ key: String) -> [ChartPoint] {
        hour.compactMap { sample in sample[key].map { ChartPoint(date: sample.time, value: $0) } }
    }

    /// The newest complete sample: the last one is often still being written.
    private func latest(_ key: String) -> Double {
        hour.last { $0[key] != nil }?[key] ?? 0
    }

    // MARK: Details

    private var detailsCard: some View {
        Card(title: "Details", systemImage: "list.bullet.rectangle") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 16) {
                ForEach(details) { FactRow(fact: $0) }
            }
        }
    }

    private var details: [Fact] {
        var items: [Fact] = []
        let ostype = config.string("ostype")
        let windows = kind == .qemu && (ostype ?? "").hasPrefix("w")
        items.append(Fact(symbol: windows ? "pc" : "terminal", color: .blue, title: "Operating system",
                          value: facts.osName ?? Theme.ostypeLabel(ostype) ?? "Not set",
                          detail: facts.kernel.map { "Kernel \($0)" } ?? (kind == .lxc ? config.text("arch") : nil)))
        if guest.isTemplate {
            items.append(Fact(symbol: "square.on.square.dashed", color: .purple, title: "Template", value: "Clone it to make new guests"))
        } else if running {
            let uptime = status?.uptime ?? guest.uptime
            items.append(Fact(symbol: "clock", color: .green, title: "Running for", value: Format.duration(uptime),
                              detail: uptime > 0 ? "Since \(Format.dateTime(Date.now.addingTimeInterval(-Double(uptime))))" : nil))
        } else {
            items.append(Fact(symbol: power == .paused ? "pause.fill" : "stop.fill", color: power == .paused ? .yellow : .gray, title: "State", value: power.label))
        }
        items.append(Fact(symbol: "server.rack", color: .indigo, title: "Node", value: guest.node, detail: guest.pool.isEmpty ? nil : "Pool \(guest.pool)",
                          open: { session.nodeTab = "summary"; session.selection = .node(guest.node) }))
        if kind == .qemu {
            let sockets = config.int("sockets") ?? 1, cores = config.int("cores") ?? 1
            let model = PropertyString(config.string("cpu") ?? "", defaultKey: "cputype")["cputype"] ?? "kvm64"
            items.append(Fact(symbol: "cpu", color: Theme.cpu, title: "Processor", value: "\(Format.count(sockets * cores, "vCPU")) · \(model)",
                              detail: "\(Format.count(sockets, "socket")) × \(Format.count(cores, "core"))" + (config.bool("numa") ? " · NUMA" : "")))
            let machine = (config.string("machine") ?? "").contains("q35") ? "q35" : "i440fx"
            items.append(Fact(symbol: "gearshape.2", color: .gray, title: "Firmware", value: config.string("bios") == "ovmf" ? "UEFI (OVMF)" : "BIOS (SeaBIOS)",
                              detail: [machine, status?.qemuVersion.map { "QEMU \($0)" }].compactMap { $0 }.joined(separator: " · ")))
            items.append(agentFact)
        } else {
            let limit = config.double("cpulimit").flatMap { $0 > 0 ? $0 : nil }
            items.append(Fact(symbol: "cpu", color: Theme.cpu, title: "Processor", value: config.int("cores").map { Format.count($0, "core") } ?? "All host cores",
                              detail: limit.map { "Limited to \($0.formatted()) CPUs" } ?? "No CPU limit"))
            let features = PropertyString(config.string("features") ?? "").pairs.filter { $0.value == "1" }.map(\.key)
            items.append(Fact(symbol: "shield.lefthalf.filled", color: .teal, title: "Isolation", value: config.bool("unprivileged") ? "Unprivileged" : "Privileged",
                              detail: features.isEmpty ? nil : "Features: " + features.joined(separator: ", ")))
        }
        let startup = PropertyString(config.string("startup") ?? "")
        let order = [startup["order"].map { "Order \($0)" }, startup["up"].map { "waits \($0) s" }].compactMap { $0 }.joined(separator: ", ")
        items.append(Fact(symbol: "power", color: config.bool("onboot") ? .green : .gray, title: "Start at boot", value: config.bool("onboot") ? "Yes" : "No",
                          detail: order.isEmpty ? nil : order))
        let protected = config.bool("protection")
        items.append(Fact(symbol: protected ? "lock.fill" : "lock.open", color: protected ? .blue : .gray, title: "Protection", value: protected ? "On" : "Off",
                          detail: protected ? "Can't be removed by mistake" : nil))
        let newest = facts.snapshots.first
        items.append(Fact(symbol: "camera", color: .blue, title: "Snapshots",
                          value: !facts.loaded ? "Checking…" : facts.snapshots.isEmpty ? "None" : Format.count(facts.snapshots.count, "snapshot"),
                          detail: newest.map { snapshot in "Latest: \(snapshot.name)" + (snapshot.date.map { ", " + Format.relative($0) } ?? "") },
                          open: { session.guestTab = "snapshots" }))
        items.append(backupFact)
        if let status, status.haManaged {
            items.append(Fact(symbol: "heart.fill", color: .pink, title: "High availability", value: (status.haState ?? "managed").capitalized,
                              open: { session.selection = .ha }))
        }
        return items
    }

    private var agentFact: Fact {
        let (value, detail, warn): (String, String?, Bool) =
            !agentEnabled ? ("Off", "Turn it on under Options to see addresses and disks", false)
            : !running ? ("On", nil, false)
            : !facts.loaded ? ("Checking…", nil, false)
            : facts.agentResponding ? ("Responding", nil, false)
            : ("Not responding", "Install qemu-guest-agent inside the VM", true)
        return Fact(symbol: "antenna.radiowaves.left.and.right", color: .mint, title: "Guest agent", value: value, detail: detail, warn: warn)
    }

    private var backupFact: Fact {
        guard facts.loaded else { return Fact(symbol: "clock.arrow.circlepath", color: .teal, title: "Last backup", value: "Checking…") }
        let job = facts.inBackupJob.map { covered in
            covered ? facts.nextBackup.map { "Next \(Format.relative($0))" } ?? "In a backup job" : "Not in any backup job"
        }
        return Fact(symbol: "clock.arrow.circlepath", color: .teal, title: "Last backup",
                    value: facts.lastBackup.map { backup in
                        let when = Format.relative(backup.date)
                        return when.prefix(1).uppercased() + when.dropFirst()
                    } ?? "Never",
                    detail: [facts.lastBackup.map { "On \($0.storage)" }, job].compactMap { $0 }.joined(separator: " · "),
                    warn: facts.inBackupJob == false, open: { session.guestTab = "backups" })
    }

    // MARK: Network

    private var networkCard: some View {
        let devices = netDevices
        return Card(title: "Network", systemImage: "network") {
            if devices.isEmpty {
                Text("No network devices.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(devices) { device in
                        NetDeviceRow(device: device)
                        if device.id != devices.last?.id { Divider() }
                    }
                }
                if running, kind == .qemu, facts.loaded, !facts.agentResponding {
                    Label(agentEnabled ? "Addresses appear once the guest agent answers." : "Turn on the guest agent under Options to see addresses.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var netDevices: [NetDevice] {
        config.keys.filter { $0.hasPrefix("net") && Int($0.dropFirst(3)) != nil }
            .sorted(using: KeyPathComparator(\.self, comparator: .localizedStandard))
            .map { key in
                let options = PropertyString(config.string(key) ?? "")
                if kind == .qemu {
                    let model = options.pairs.first { Self.nicModels[$0.key] != nil }
                    let mac = model?.value.lowercased()
                    return NetDevice(id: key, title: key, model: model.flatMap { Self.nicModels[$0.key] }, bridge: options["bridge"], mac: model?.value,
                                     vlan: options["tag"], firewall: options["firewall"] == "1", unplugged: options["link_down"] == "1", configured: [],
                                     live: facts.interfaces.filter { $0.mac == mac }.flatMap(\.addresses))
                }
                let name = options["name"] ?? key
                let mac = options["hwaddr"]?.lowercased()
                let configured = [options["ip"], options["ip6"]].compactMap { $0 }.filter { $0 != "manual" }
                return NetDevice(id: key, title: name, model: nil, bridge: options["bridge"], mac: options["hwaddr"], vlan: options["tag"],
                                 firewall: options["firewall"] == "1", unplugged: options["link_down"] == "1",
                                 configured: configured.map { ["dhcp": "DHCP", "auto": "SLAAC"][$0] ?? $0 },
                                 live: facts.interfaces.filter { $0.name == name || $0.mac == mac }.flatMap(\.addresses))
            }
    }

    private static let nicModels = ["virtio": "VirtIO", "e1000": "Intel E1000", "e1000e": "Intel E1000E", "rtl8139": "Realtek RTL8139",
                                    "vmxnet3": "VMware vmxnet3", "i82551": "Intel 82551", "i82557b": "Intel 82557B", "i82559er": "Intel 82559ER",
                                    "ne2k_pci": "NE2000 PCI", "ne2k_isa": "NE2000 ISA", "pcnet": "AMD PCnet"]

    // MARK: Storage

    private var storageCard: some View {
        let entries = disks
        return Card(title: "Storage", systemImage: "internaldrive") {
            if entries.isEmpty {
                Text("No disks.").foregroundStyle(.secondary)
            }
            ForEach(entries) { DiskRow(entry: $0) }
            if !facts.filesystems.isEmpty {
                Text("Inside the guest").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(facts.filesystems) { FilesystemRow(filesystem: $0) }
            }
        }
    }

    private var disks: [DiskEntry] {
        let boot = PropertyString(config.string("boot") ?? "")["order"]?.split(separator: ";").first.map(String.init)
        var entries: [DiskEntry] = []
        for key in config.keys.sorted(using: KeyPathComparator(\.self, comparator: .localizedStandard)) {
            guard let raw = config.string(key) else { continue }
            if kind == .lxc {
                guard key == "rootfs" || (key.hasPrefix("mp") && Int(key.dropFirst(2)) != nil) else { continue }
                let options = PropertyString(raw, defaultKey: "volume")
                let volume = options["volume"] ?? ""
                let root = key == "rootfs"
                var notes = [root ? "Root disk, mounted at /" : "\(key), mounted at \(options["mp"] ?? "?")"]
                if options["ro"] == "1" { notes.append("Read-only") }
                if !root, options["backup"] != "1" { notes.append("Not in backups") }
                entries.append(DiskEntry(id: key, title: Self.storageName(volume), symbol: volume.hasPrefix("/") ? "folder" : "internaldrive",
                                         size: options["size"].flatMap(Format.parseSize), notes: notes, rank: root ? 0 : 1,
                                         usage: root && running && guest.maxdisk > 0 ? (guest.disk, guest.maxdisk) : nil))
                continue
            }
            let bus = ["scsi", "virtio", "sata", "ide"].first { key.hasPrefix($0) && Int(key.dropFirst($0.count)) != nil }
            guard bus != nil || key == "efidisk0" || key == "tpmstate0" else { continue }
            let options = PropertyString(raw, defaultKey: "file")
            let file = options["file"] ?? ""
            if options["media"] == "cdrom" {
                guard !["", "none", "cdrom"].contains(file) else { continue }
                entries.append(DiskEntry(id: key, title: file.components(separatedBy: "/").last ?? file, symbol: "opticaldisc", size: nil,
                                         notes: ["CD/DVD in \(key)"], rank: 2))
                continue
            }
            var notes = [key == "efidisk0" ? "EFI variables" : key == "tpmstate0" ? "TPM state" : key]
            if options["ssd"] == "1" { notes.append("SSD") }
            if options["iothread"] == "1" { notes.append("IO thread") }
            if options["discard"] == "on" { notes.append("Discard") }
            if let cache = options["cache"], cache != "none" { notes.append("Cache: \(cache)") }
            if options["backup"] == "0" { notes.append("Not in backups") }
            entries.append(DiskEntry(id: key, title: Self.storageName(file),
                                     symbol: key == "tpmstate0" ? "lock.shield" : key == "efidisk0" ? "memorychip" : "internaldrive",
                                     size: options["size"].flatMap(Format.parseSize), notes: notes, rank: key == boot ? 0 : bus == nil ? 3 : 1, boot: key == boot))
        }
        return entries.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// "local-lvm:vm-100-disk-0" lives on local-lvm; passthrough disks and bind mounts are paths.
    private static func storageName(_ volume: String) -> String {
        volume.hasPrefix("/") ? volume : volume.split(separator: ":", maxSplits: 1).first.map(String.init) ?? volume
    }

    // MARK: Notes

    private var notesCard: some View {
        Card(title: "Notes", systemImage: "note.text") {
            if let notes = config.text("description") {
                MarkdownText(source: notes)
            } else {
                Text("No notes yet. Write down what this \(kind.noun) is for, so the next person knows.")
                    .foregroundStyle(.secondary)
            }
        } accessory: {
            Button("Edit") { editingNotes = true }.buttonStyle(.link)
        }
    }

    // MARK: Loading

    private func loadSamples() async {
        let path = base + "/rrddata"
        if let list = try? await session.client.list(path, ["timeframe": timeframe.rawValue, "cf": maximum ? "MAX" : "AVERAGE"]) {
            samples = list.map(RRDPoint.init)
        }
        if timeframe == .hour, !maximum {
            hour = samples
        } else if let list = try? await session.client.list(path, ["timeframe": "hour", "cf": "AVERAGE"]) {
            hour = list.map(RRDPoint.init)
        }
    }

    /// Everything that changes slowly: looked up when the guest opens, starts or stops, and after each task.
    private func loadFacts() async {
        var found = GuestFacts()
        if running, kind == .qemu, agentEnabled {
            if let reply = try? await session.client.object(base + "/agent/network-get-interfaces") {
                found.agentResponding = true
                found.interfaces = reply.objects("result").filter { $0.string("name") != "lo" }.map { item in
                    GuestFacts.Interface(name: item.string("name") ?? "", mac: (item.string("hardware-address") ?? "").lowercased(),
                                         addresses: item.objects("ip-addresses").compactMap { $0.string("ip-address") }.filter(Self.isUseful))
                }
                if let info = (try? await session.client.object(base + "/agent/get-osinfo"))?.object("result") {
                    found.osName = info.text("pretty-name") ?? info.text("name")
                    found.kernel = info.text("kernel-release")
                }
                if let reply = try? await session.client.object(base + "/agent/get-fsinfo") {
                    found.filesystems = Self.filesystems(reply.objects("result"))
                }
            }
        } else if running, kind == .lxc, let list = try? await session.client.list(base + "/interfaces") {
            found.interfaces = list.filter { $0.string("name") != "lo" }.map { item in
                GuestFacts.Interface(name: item.string("name") ?? "", mac: (item.string("hwaddr") ?? "").lowercased(),
                                     addresses: [item.string("inet"), item.string("inet6")].compactMap { $0 }
                                        .map { $0.components(separatedBy: "/").first ?? $0 }.filter(Self.isUseful))
            }
        }
        found.snapshots = ((try? await session.client.list(base + "/snapshot")) ?? [])
            .filter { $0.string("name") != "current" }
            .map { (name: $0.string("name") ?? "", date: Format.epoch($0.int("snaptime"))) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        if let uncovered = try? await session.client.list("/cluster/backup-info/not-backed-up") {
            found.inBackupJob = !uncovered.contains { $0.int("vmid") == guest.vmid }
        }
        found.nextBackup = ((try? await session.client.list("/cluster/backup")) ?? []).filter(covers).compactMap { Format.epoch($0.int("next-run")) }.min()
        for storage in (try? await session.client.list("/nodes/\(guest.node.enc)/storage", ["content": "backup", "enabled": "1"])) ?? [] {
            guard let id = storage.text("storage") else { continue }
            let backups = (try? await session.client.list("/nodes/\(guest.node.enc)/storage/\(id.enc)/content",
                                                          ["content": "backup", "vmid": String(guest.vmid)])) ?? []
            for backup in backups {
                if let date = Format.epoch(backup.int("ctime")), date > (found.lastBackup?.date ?? .distantPast) { found.lastBackup = (date, id) }
            }
        }
        guard !Task.isCancelled else { return }
        found.loaded = true
        facts = found
    }

    /// Whether a backup job includes this guest: every guest but the excluded ones, a pool, or a list of IDs.
    private func covers(_ job: JSONObject) -> Bool {
        guard job["enabled"] == nil || job.bool("enabled") else { return false }
        if let node = job.text("node"), node != guest.node { return false }
        let id = String(guest.vmid)
        if job.bool("all") { return !job.strings("exclude").contains(id) }
        if let pool = job.text("pool") { return pool == guest.pool }
        return job.strings("vmid").contains(id)
    }

    /// Real filesystems, one per device: no snap images, tmpfs, Docker overlays or bind mounts of the same disk.
    static func filesystems(_ items: [JSONObject]) -> [GuestFacts.Filesystem] {
        let skippedTypes: Set = ["squashfs", "tmpfs", "devtmpfs", "overlay", "iso9660", "udf", "ramfs", "autofs", "nsfs", "fuse.lxcfs"]
        let skippedMounts = ["/snap", "/run", "/var/lib/docker", "/var/snap", "/sys", "/proc", "/dev"]
        var seen = Set<String>()
        return items.compactMap { item -> GuestFacts.Filesystem? in
            let mount = item.string("mountpoint") ?? "", type = item.string("type") ?? "", total = item.int64("total-bytes")
            guard total > 0, !mount.isEmpty, !skippedTypes.contains(type.lowercased()),
                  !skippedMounts.contains(where: { mount == $0 || mount.hasPrefix($0 + "/") }) else { return nil }
            return GuestFacts.Filesystem(device: item.string("name") ?? mount, mount: mount, type: type, used: item.int64("used-bytes"), total: total)
        }
        .sorted { $0.mount.count < $1.mount.count }
        .filter { seen.insert($0.device).inserted }
        .sorted { $0.mount.localizedStandardCompare($1.mount) == .orderedAscending }
    }

    private static func isUseful(_ address: String) -> Bool {
        !address.isEmpty && !address.hasPrefix("127.") && address != "::1" && !address.lowercased().hasPrefix("fe80")
    }
}

/// What the summary looks up once per visit, beyond the live status: the guest's own view of its network, OS and
/// filesystems (from the guest agent or the container), its snapshots and its backups.
struct GuestFacts {
    struct Interface {
        let name: String
        let mac: String
        let addresses: [String]
    }

    struct Filesystem: Identifiable {
        let device: String
        let mount: String
        let type: String
        let used: Int64
        let total: Int64
        var id: String { device + mount }
    }

    var interfaces: [Interface] = []
    var osName: String?
    var kernel: String?
    var filesystems: [Filesystem] = []
    var agentResponding = false
    var snapshots: [(name: String, date: Date?)] = []
    var lastBackup: (date: Date, storage: String)?
    var inBackupJob: Bool?
    var nextBackup: Date?
    var loaded = false
}

// MARK: Rows

/// One line of a guest's details.
private struct Fact: Identifiable {
    let symbol: String
    let color: Color
    let title: String
    let value: String
    var detail: String?
    var warn = false
    /// Where clicking the fact leads, if anywhere.
    var open: (() -> Void)?
    var id: String { title }
}

private struct NetDevice: Identifiable {
    let id: String
    let title: String
    let model: String?
    let bridge: String?
    let mac: String?
    let vlan: String?
    let firewall: Bool
    let unplugged: Bool
    /// What the config asks for (a container's static address or DHCP), shown when the guest doesn't report its own.
    let configured: [String]
    let live: [String]
}

private struct DiskEntry: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let size: Int64?
    let notes: [String]
    /// Boot disk first, then data disks, CD/DVD, then EFI and TPM state.
    let rank: Int
    var boot = false
    var usage: (used: Int64, total: Int64)?
}

/// A white symbol on a tinted rounded square, like the icons in System Settings.
private struct SymbolTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(color.gradient, in: .rect(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct FactRow: View {
    let fact: Fact
    @State private var hovering = false

    var body: some View {
        if let open = fact.open {
            Button(action: open) { content(link: true) }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Show \(fact.title.lowercased())")
        } else {
            content(link: false)
        }
    }

    private func content(link: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SymbolTile(symbol: fact.symbol, color: fact.warn ? .orange : fact.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.title).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(fact.value)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(fact.warn ? Color.orange : Color.primary)
                        .lineLimit(2)
                    if link {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .opacity(hovering ? 1 : 0.5)
                    }
                }
                if let detail = fact.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct NetDeviceRow: View {
    let device: NetDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                SymbolTile(symbol: device.unplugged ? "network.slash" : "network", color: device.unplugged ? .orange : Theme.netIn)
                VStack(alignment: .leading, spacing: 2) {
                    Text([device.title, device.model].compactMap { $0 }.joined(separator: " · ")).font(.callout.weight(.medium))
                    Text([device.bridge, device.mac].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    if let vlan = device.vlan { Pill(text: "VLAN \(vlan)", color: .blue) }
                    if device.firewall { Pill(text: "Firewall", systemImage: "shield.lefthalf.filled", color: .green) }
                    if device.unplugged { Pill(text: "Unplugged", color: .orange) }
                }
            }
            if !device.live.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(device.live, id: \.self) { AddressChip(address: $0) }
                }
                .padding(.leading, 36)
            } else if !device.configured.isEmpty {
                Text("Configured: " + device.configured.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 36)
            }
        }
    }
}

/// An address that copies itself when clicked.
private struct AddressChip: View {
    let address: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            HStack(spacing: 5) {
                Text(address).font(.callout.monospaced())
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.1), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy \(address)")
        .accessibilityLabel("Copy \(address)")
    }
}

private struct DiskRow: View {
    let entry: DiskEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SymbolTile(symbol: entry.symbol, color: entry.rank >= 2 ? .gray : Theme.disk)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle).help(entry.title)
                    if entry.boot { Pill(text: "Boot", color: .green) }
                    Spacer(minLength: 8)
                    if let size = entry.size { Text(Format.bytes(size)).font(.callout).monospacedDigit().foregroundStyle(.secondary) }
                }
                if !entry.notes.isEmpty {
                    Text(entry.notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let usage = entry.usage {
                    let fraction = Double(usage.used) / Double(max(usage.total, 1))
                    UsageBar(fraction: fraction, color: Theme.disk, height: 5)
                    Text("\(Format.bytes(usage.used)) used of \(Format.bytes(usage.total)) · \(Format.percent(fraction))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct FilesystemRow: View {
    let filesystem: GuestFacts.Filesystem

    var body: some View {
        let fraction = Double(filesystem.used) / Double(max(filesystem.total, 1))
        HStack(alignment: .top, spacing: 10) {
            SymbolTile(symbol: "folder", color: Theme.usage(fraction, base: .teal))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(filesystem.mount).font(.callout.weight(.medium).monospaced()).lineLimit(1).truncationMode(.middle).help(filesystem.mount)
                    Text(filesystem.type).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(Format.percent(fraction)).font(.callout).monospacedDigit().foregroundStyle(Theme.usage(fraction, base: .secondary))
                }
                UsageBar(fraction: fraction, color: Theme.disk, height: 5)
                Text("\(Format.bytes(filesystem.used)) used of \(Format.bytes(filesystem.total)) · \(Format.bytes(max(0, filesystem.total - filesystem.used))) free")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
