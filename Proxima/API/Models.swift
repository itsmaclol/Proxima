import Foundation

nonisolated enum GuestKind: String, Hashable, CaseIterable {
    case qemu, lxc

    var short: String { self == .qemu ? "VM" : "CT" }
    var noun: String { self == .qemu ? "virtual machine" : "container" }
    var symbol: String { self == .qemu ? "desktopcomputer" : "shippingbox" }
}

nonisolated enum PowerState: String, Hashable {
    case running, stopped, paused, unknown

    /// Paused VMs report `status: running` with `qmpstatus: paused`.
    init(status: String?, qmpstatus: String? = nil) {
        if let qmpstatus, ["paused", "suspended", "prelaunch"].contains(qmpstatus) { self = .paused; return }
        switch status {
        case "running": self = .running
        case "stopped": self = .stopped
        case "paused", "suspended": self = .paused
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .running: "Running"
        case .stopped: "Stopped"
        case .paused: "Paused"
        case .unknown: "Unknown"
        }
    }
}

/// One entry of `/cluster/resources`: a node, guest, storage, pool or SDN zone.
nonisolated struct Resource: Identifiable, Hashable {
    let id: String
    let type: String
    let node: String
    let status: String
    let name: String
    let vmid: Int
    let storage: String
    let pool: String
    let cpu: Double
    let maxcpu: Double
    let mem: Int64
    let maxmem: Int64
    let disk: Int64
    let maxdisk: Int64
    let uptime: Int
    let netin: Int64
    let netout: Int64
    let diskread: Int64
    let diskwrite: Int64
    let isTemplate: Bool
    let tags: [String]
    let lock: String?
    let hastate: String?
    let content: [String]
    let plugin: String
    let shared: Bool

    init(_ j: JSONObject) {
        id = j.string("id") ?? UUID().uuidString
        type = j.string("type") ?? ""
        node = j.string("node") ?? ""
        status = j.string("status") ?? ""
        name = j.string("name") ?? ""
        vmid = j.int("vmid") ?? 0
        storage = j.string("storage") ?? ""
        pool = j.string("pool") ?? ""
        cpu = j.double("cpu") ?? 0
        maxcpu = j.double("maxcpu") ?? 0
        mem = j.int64("mem")
        maxmem = j.int64("maxmem")
        disk = j.int64("disk")
        maxdisk = j.int64("maxdisk")
        uptime = j.int("uptime") ?? 0
        netin = j.int64("netin")
        netout = j.int64("netout")
        diskread = j.int64("diskread")
        diskwrite = j.int64("diskwrite")
        isTemplate = j.bool("template")
        tags = j.strings("tags").filter { !$0.isEmpty }
        lock = j.text("lock")
        hastate = j.text("hastate")
        content = j.strings("content")
        plugin = j.string("plugintype") ?? ""
        shared = j.bool("shared")
    }

    var kind: GuestKind? { GuestKind(rawValue: type) }
    var isGuest: Bool { kind != nil }
    var isNode: Bool { type == "node" }
    var isStorage: Bool { type == "storage" }
    var power: PowerState { PowerState(status: status) }
    var isOnline: Bool { status == "online" }

    var displayName: String {
        if !name.isEmpty { return name }
        if let kind { return "\(kind.short) \(vmid)" }
        if isNode { return node }
        if isStorage { return storage }
        return pool.isEmpty ? id : pool
    }

    var cpuFraction: Double { cpu }
    var memFraction: Double { maxmem > 0 ? Double(mem) / Double(maxmem) : 0 }
    var diskFraction: Double { maxdisk > 0 ? Double(disk) / Double(maxdisk) : 0 }
}

/// `/nodes/{node}/status`.
nonisolated struct NodeStatus: Equatable {
    let cpu: Double
    let ioWait: Double
    let cpuModel: String
    let cpus: Int
    let sockets: Int
    let mhz: String
    let memTotal: Int64
    let memUsed: Int64
    let swapTotal: Int64
    let swapUsed: Int64
    let rootTotal: Int64
    let rootUsed: Int64
    let uptime: Int
    let loadavg: [Double]
    let kernel: String
    let pveVersion: String
    let bootMode: String
    let ksmShared: Int64

    init(_ j: JSONObject) {
        cpu = j.double("cpu") ?? 0
        ioWait = j.double("wait") ?? 0
        let info = j.object("cpuinfo") ?? [:]
        cpuModel = info.string("model") ?? ""
        cpus = info.int("cpus") ?? 0
        sockets = info.int("sockets") ?? 0
        mhz = info.string("mhz") ?? ""
        let memory = j.object("memory") ?? [:]
        memTotal = memory.int64("total")
        memUsed = memory.int64("used")
        let swap = j.object("swap") ?? [:]
        swapTotal = swap.int64("total")
        swapUsed = swap.int64("used")
        let root = j.object("rootfs") ?? [:]
        rootTotal = root.int64("total")
        rootUsed = root.int64("used")
        uptime = j.int("uptime") ?? 0
        loadavg = j.strings("loadavg").compactMap(Double.init)
        let current = j.object("current-kernel")
        kernel = current?.string("release").map { "Linux \($0)" } ?? j.string("kversion")?.components(separatedBy: " #").first ?? ""
        pveVersion = j.string("pveversion").map { $0.split(separator: "/").dropFirst().first.map(String.init) ?? $0 } ?? ""
        let boot = j.object("boot-info") ?? [:]
        bootMode = boot.string("mode").map { $0 == "efi" ? (boot.bool("secureboot") ? "EFI (Secure Boot)" : "EFI") : "Legacy BIOS" } ?? ""
        ksmShared = j.object("ksm")?.int64("shared") ?? 0
    }
}

/// `/nodes/{node}/{qemu|lxc}/{vmid}/status/current`.
nonisolated struct GuestStatus: Equatable {
    let power: PowerState
    let cpu: Double
    let cpus: Double
    let mem: Int64
    let maxmem: Int64
    let maxdisk: Int64
    let swap: Int64
    let maxswap: Int64
    let uptime: Int
    let haManaged: Bool
    let haState: String?
    let agent: Bool
    let qemuVersion: String?
    let machine: String?
    let lock: String?

    init(_ j: JSONObject) {
        power = PowerState(status: j.string("status"), qmpstatus: j.string("qmpstatus"))
        cpu = j.double("cpu") ?? 0
        cpus = j.double("cpus") ?? 0
        mem = j.int64("mem")
        maxmem = j.int64("maxmem")
        maxdisk = j.int64("maxdisk")
        swap = j.int64("swap")
        maxswap = j.int64("maxswap")
        uptime = j.int("uptime") ?? 0
        let ha = j.object("ha") ?? [:]
        haManaged = ha.bool("managed")
        haState = ha.text("state")
        agent = j.bool("agent")
        qemuVersion = j.text("running-qemu")
        machine = j.text("running-machine")
        lock = j.text("lock")
    }
}

/// One sample of `rrddata`. Gaps (node offline) come back with only `time`.
nonisolated struct RRDPoint: Identifiable, Hashable {
    let time: Date
    let values: [String: Double]
    var id: Date { time }

    init(_ j: JSONObject) {
        time = Date(timeIntervalSince1970: j.double("time") ?? 0)
        var values: [String: Double] = [:]
        for (key, value) in j where key != "time" {
            if let number = jsonDouble(value), number.isFinite { values[key] = number }
        }
        self.values = values
    }

    subscript(key: String) -> Double? { values[key] }
}

nonisolated enum Timeframe: String, CaseIterable, Identifiable {
    case hour, day, week, month, year
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// A row of `/cluster/tasks` or `/nodes/{node}/tasks`.
nonisolated struct TaskEntry: Identifiable, Hashable {
    let upid: String
    let node: String
    let type: String
    let objectID: String
    let user: String
    let start: Date
    let end: Date?
    let status: String?

    var id: String { upid }

    init(_ j: JSONObject) {
        upid = j.string("upid") ?? UUID().uuidString
        let parsed = UPID(upid)
        node = j.string("node") ?? parsed?.node ?? ""
        type = j.string("type") ?? parsed?.type ?? ""
        objectID = j.string("id") ?? parsed?.id ?? ""
        user = j.string("user") ?? parsed?.user ?? ""
        start = Format.epoch(j.int("starttime")) ?? parsed?.start ?? .now
        end = Format.epoch(j.int("endtime"))
        let raw = j.text("status")
        status = raw == "RUNNING" ? nil : raw
    }

    var isRunning: Bool { end == nil }
    var succeeded: Bool { status == "OK" }
    var hasWarnings: Bool { status?.hasPrefix("WARNINGS") ?? false }
    var title: String { TaskNames.describe(type: type, id: objectID) }
    var duration: TimeInterval { (end ?? .now).timeIntervalSince(start) }
}

nonisolated struct Snapshot: Identifiable, Hashable {
    let name: String
    let description: String
    let date: Date?
    let includesRAM: Bool
    let parent: String?

    var id: String { name }
    var isCurrent: Bool { name == "current" }

    init(_ j: JSONObject) {
        name = j.string("name") ?? ""
        description = j.string("description") ?? ""
        date = Format.epoch(j.int("snaptime"))
        includesRAM = j.bool("vmstate")
        parent = j.text("parent")
    }
}

/// A storage as seen from one node (`/nodes/{node}/storage`).
nonisolated struct StorageInfo: Identifiable, Hashable {
    let storage: String
    let type: String
    let content: [String]
    let total: Int64
    let used: Int64
    let available: Int64
    let active: Bool
    let enabled: Bool
    let shared: Bool

    var id: String { storage }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    init(_ j: JSONObject) {
        storage = j.string("storage") ?? ""
        type = j.string("type") ?? ""
        content = j.strings("content")
        total = j.int64("total")
        used = j.int64("used")
        available = j.int64("avail")
        active = j.bool("active")
        enabled = j["enabled"] == nil || j.bool("enabled")
        shared = j.bool("shared")
    }
}

/// A file or volume on a storage (`…/storage/{id}/content`).
nonisolated struct Volume: Identifiable, Hashable {
    let volid: String
    let content: String
    let format: String
    let size: Int64
    let date: Date?
    let vmid: Int?
    let notes: String
    let isProtected: Bool
    let verification: String?
    let subtype: String?

    var id: String { volid }
    var fileName: String {
        let path = volid.split(separator: ":", maxSplits: 1).last.map(String.init) ?? volid
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    init(_ j: JSONObject) {
        volid = j.string("volid") ?? ""
        content = j.string("content") ?? ""
        format = j.string("format") ?? ""
        size = j.int64("size")
        date = Format.epoch(j.int("ctime"))
        vmid = j.int("vmid")
        notes = j.string("notes") ?? ""
        isProtected = j.bool("protected")
        verification = j.object("verification")?.text("state")
        subtype = j.text("subtype")
    }
}

nonisolated enum ContentType: String, CaseIterable, Identifiable {
    case backup, iso, vztmpl, images, rootdir, snippets, `import`

    var id: String { rawValue }
    var label: String {
        switch self {
        case .backup: "Backups"
        case .iso: "ISO Images"
        case .vztmpl: "CT Templates"
        case .images: "VM Disks"
        case .rootdir: "CT Volumes"
        case .snippets: "Snippets"
        case .import: "Import"
        }
    }
    /// The empty state's title; lowercasing the label gave "No ct volumes".
    var emptyTitle: String {
        switch self {
        case .backup: "No backups"
        case .iso: "No ISO images"
        case .vztmpl: "No CT templates"
        case .images: "No VM disks"
        case .rootdir: "No CT volumes"
        case .snippets: "No snippets"
        case .import: "No import files"
        }
    }
    var symbol: String {
        switch self {
        case .backup: "clock.arrow.circlepath"
        case .iso: "opticaldisc"
        case .vztmpl: "shippingbox"
        case .images: "internaldrive"
        case .rootdir: "cylinder"
        case .snippets: "doc.text"
        case .import: "square.and.arrow.down"
        }
    }
}
