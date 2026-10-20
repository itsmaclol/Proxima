import Foundation
import Observation

/// What the Overview shows beyond `/cluster/resources`: each node's status and last hour, and the checks behind
/// "Needs attention" (updates, certificates, disk health, backups, HA, Ceph). Slow-changing checks refresh every few minutes.
@MainActor @Observable
final class OverviewData {
    struct Sample {
        let date: Date
        var cpu: Double
        var memUsed: Double
        var memTotal: Double
        var netIn: Double
        var netOut: Double
    }

    /// Where an attention item leads.
    enum Destination: Equatable {
        case node(String, tab: String)
        case storage(node: String, id: String)
        case backups
        case ha
        case task(TaskEntry)
    }

    struct Attention: Identifiable {
        enum Severity: Int, Comparable {
            case info, warning, critical
            static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        }

        let id: String
        let severity: Severity
        let symbol: String
        let title: String
        let detail: String
        let destination: Destination?
    }

    struct GuestRate {
        var net: Double
        var disk: Double
    }

    private(set) var status: [String: NodeStatus] = [:]
    /// The cluster's last hour, one sample a minute: CPU weighted by cores, memory and network summed.
    private(set) var history: [Sample] = []
    private(set) var updates: [String: Int] = [:]
    private(set) var certificateExpiry: [String: Date] = [:]
    private(set) var failingDisks: [(node: String, device: String, model: String, health: String)] = []
    /// Nil until the server has answered: an empty list means every guest is in a backup job.
    private(set) var notBackedUp: [JSONObject]?
    private(set) var nextBackup: Date?
    private(set) var haProblems: [String] = []
    private(set) var cephHealth: (status: String, summary: String)?
    /// Network and disk throughput per guest, from the change in its counters between two refreshes.
    private(set) var rates: [String: GuestRate] = [:]

    private var lastCounters: [String: (net: Int64, disk: Int64, at: Date)] = [:]
    private var slowChecked: Date?

    func refresh(_ session: Session) async {
        let online = session.nodes.filter(\.isOnline).map(\.node)
        guard !online.isEmpty else { return }
        var status: [String: NodeStatus] = [:]
        var perNode: [[RRDPoint]] = []
        for node in online {
            if let object = try? await session.client.object("/nodes/\(node.enc)/status") { status[node] = NodeStatus(object) }
            if let list = try? await session.client.list("/nodes/\(node.enc)/rrddata", ["timeframe": "hour", "cf": "AVERAGE"]) {
                perNode.append(list.map(RRDPoint.init))
            }
        }
        self.status = status
        history = Self.combine(perNode)
        if slowChecked.map({ Date.now.timeIntervalSince($0) > 300 }) ?? true {
            slowChecked = .now
            await refreshSlowChecks(session, nodes: online)
        }
    }

    /// Updates, certificates, disk health, backup coverage, HA and Ceph: things that change over hours, not seconds.
    private func refreshSlowChecks(_ session: Session, nodes: [String]) async {
        var updates: [String: Int] = [:]
        var expiry: [String: Date] = [:]
        var failing: [(node: String, device: String, model: String, health: String)] = []
        for node in nodes {
            updates[node] = ((try? await session.client.list("/nodes/\(node.enc)/apt/update")) ?? []).count
            // The node's own certificate (pve-ssl.pem or an uploaded/ACME one), not the long-lived cluster CA.
            let certificates = (try? await session.client.list("/nodes/\(node.enc)/certificates/info")) ?? []
            if let soonest = certificates.filter({ $0.string("filename") != "pve-root-ca.pem" }).compactMap({ Format.epoch($0.int("notafter")) }).min() {
                expiry[node] = soonest
            }
            for disk in (try? await session.client.list("/nodes/\(node.enc)/disks/list")) ?? [] {
                let health = (disk.string("health") ?? "").uppercased()
                if !["", "PASSED", "OK", "UNKNOWN"].contains(health) {
                    failing.append((node, disk.string("devpath") ?? "", disk.string("model") ?? "", health))
                }
            }
        }
        self.updates = updates
        certificateExpiry = expiry
        failingDisks = failing
        if let list = try? await session.client.list("/cluster/backup-info/not-backed-up") { notBackedUp = list }
        nextBackup = ((try? await session.client.list("/cluster/backup")) ?? [])
            .filter { $0["enabled"] == nil || $0.bool("enabled") }
            .compactMap { Format.epoch($0.int("next-run")) }
            .min()
        haProblems = ((try? await session.client.list("/cluster/ha/status/current")) ?? [])
            .filter { $0.string("type") == "service" && ["error", "fence", "recovery"].contains($0.string("state") ?? "") }
            .compactMap { $0.text("sid") }
        // Not every cluster runs Ceph; the call fails where it isn't installed.
        if let ceph = try? await session.client.object("/cluster/ceph/status"), let health = ceph.object("health") {
            let checks = (health.object("checks") ?? [:]).values.compactMap { ($0 as? JSONObject)?.object("summary")?.string("message") }
            cephHealth = (health.string("status") ?? "", checks.sorted().first ?? "")
        } else {
            cephHealth = nil
        }
    }

    /// Network and disk rates per guest from two consecutive `/cluster/resources` snapshots.
    func track(_ guests: [Resource]) {
        let now = Date.now
        var rates: [String: GuestRate] = [:]
        var counters: [String: (net: Int64, disk: Int64, at: Date)] = [:]
        for guest in guests where guest.power == .running {
            let net = guest.netin + guest.netout, disk = guest.diskread + guest.diskwrite
            counters[guest.id] = (net, disk, now)
            if let last = lastCounters[guest.id], now.timeIntervalSince(last.at) > 0.5, net >= last.net, disk >= last.disk {
                let seconds = now.timeIntervalSince(last.at)
                rates[guest.id] = GuestRate(net: Double(net - last.net) / seconds, disk: Double(disk - last.disk) / seconds)
            }
        }
        lastCounters = counters
        // Keep the previous rates when nothing changed between two identical snapshots.
        if !rates.isEmpty { self.rates = rates }
    }

    /// Lines the per-node samples up by minute and adds them together.
    static func combine(_ nodes: [[RRDPoint]]) -> [Sample] {
        var byTime: [Date: Sample] = [:]
        var cores: [Date: Double] = [:]
        for points in nodes {
            for point in points {
                guard let cpu = point["cpu"], let maxcpu = point["maxcpu"], maxcpu > 0 else { continue }
                var sample = byTime[point.time] ?? Sample(date: point.time, cpu: 0, memUsed: 0, memTotal: 0, netIn: 0, netOut: 0)
                sample.cpu += cpu * maxcpu
                sample.memUsed += point["memused"] ?? 0
                sample.memTotal += point["memtotal"] ?? 0
                sample.netIn += point["netin"] ?? 0
                sample.netOut += point["netout"] ?? 0
                byTime[point.time] = sample
                cores[point.time, default: 0] += maxcpu
            }
        }
        return byTime.values.sorted { $0.date < $1.date }.map { sample in
            var sample = sample
            sample.cpu /= cores[sample.date] ?? 1
            return sample
        }
    }

    /// Everything worth a look, worst first.
    func attention(_ session: Session) -> [Attention] {
        var items: [Attention] = []
        for node in session.nodes where !node.isOnline {
            items.append(.init(id: "offline-\(node.node)", severity: .critical, symbol: "bolt.horizontal.circle", title: "\(node.node) is offline",
                               detail: "Its guests are unreachable until it's back.", destination: .node(node.node, tab: "summary")))
        }
        for disk in failingDisks {
            items.append(.init(id: "disk-\(disk.node)-\(disk.device)", severity: .critical, symbol: "externaldrive.trianglebadge.exclamationmark",
                               title: "\(disk.device) on \(disk.node) failed its health check",
                               detail: [disk.model, "S.M.A.R.T. says \(disk.health)"].filter { !$0.isEmpty }.joined(separator: " · "),
                               destination: .node(disk.node, tab: "disks")))
        }
        var seen = Set<String>()
        for storage in session.resources.filter({ $0.isStorage && $0.status == "available" && $0.maxdisk > 0 })
            .filter({ seen.insert($0.shared ? $0.storage : $0.id).inserted }) where storage.diskFraction >= 0.8 {
            items.append(.init(id: "storage-\(storage.id)", severity: storage.diskFraction >= 0.9 ? .critical : .warning, symbol: "externaldrive.badge.exclamationmark",
                               title: "\(storage.storage) is \(Format.percent(storage.diskFraction)) full",
                               detail: "\(Format.bytes(max(0, storage.maxdisk - storage.disk))) free of \(Format.bytes(storage.maxdisk))\(storage.shared ? "" : " on \(storage.node)")",
                               destination: .storage(node: storage.node, id: storage.storage)))
        }
        if let ceph = cephHealth, ceph.status != "HEALTH_OK", !ceph.status.isEmpty {
            items.append(.init(id: "ceph", severity: ceph.status == "HEALTH_ERR" ? .critical : .warning, symbol: "circle.hexagongrid",
                               title: "Ceph reports \(ceph.status.replacingOccurrences(of: "HEALTH_", with: "").lowercased())",
                               detail: ceph.summary, destination: session.nodes.first.map { .node($0.node, tab: "ceph") }))
        }
        if !haProblems.isEmpty {
            items.append(.init(id: "ha", severity: .warning, symbol: "heart.text.square", title: "High availability needs a look",
                               detail: haProblems.joined(separator: ", "), destination: .ha))
        }
        for (node, expires) in certificateExpiry {
            let days = Int(expires.timeIntervalSinceNow / 86_400)
            if days < 30 {
                items.append(.init(id: "cert-\(node)", severity: days < 0 ? .critical : .warning, symbol: "lock.trianglebadge.exclamationmark",
                                   title: days < 0 ? "\(node)'s certificate has expired" : "\(node)'s certificate expires \(Format.relative(expires))",
                                   detail: "Renew it under System → Certificates.", destination: .node(node, tab: "system")))
            }
        }
        if let notBackedUp, !notBackedUp.isEmpty {
            let names = notBackedUp.prefix(4).map { "\($0.string("name") ?? "") (\($0.string("vmid") ?? ""))" }.joined(separator: ", ")
            items.append(.init(id: "backups", severity: .warning, symbol: "clock.badge.exclamationmark",
                               title: "\(Format.count(notBackedUp.count, "guest")) not in any backup job",
                               detail: names + (notBackedUp.count > 4 ? "…" : ""), destination: .backups))
        }
        let dayAgo = Date.now.addingTimeInterval(-86_400)
        for task in session.clusterTasks.filter({ !$0.isRunning && !$0.succeeded && !$0.hasWarnings && $0.start > dayAgo }).prefix(3) {
            items.append(.init(id: "task-\(task.upid)", severity: .warning, symbol: "exclamationmark.triangle", title: "\(task.title) failed",
                               detail: "\(Format.relative(task.start)) on \(task.node)\(task.status.map { ": \($0)" } ?? "")", destination: .task(task)))
        }
        for (node, info) in status.sorted(by: { $0.key < $1.key }) {
            if info.swapTotal > 0, Double(info.swapUsed) / Double(info.swapTotal) > 0.5 {
                items.append(.init(id: "swap-\(node)", severity: .warning, symbol: "memorychip", title: "\(node) is swapping heavily",
                                   detail: "\(Format.bytes(info.swapUsed)) of \(Format.bytes(info.swapTotal)) swap in use", destination: .node(node, tab: "summary")))
            }
            if info.rootTotal > 0, Double(info.rootUsed) / Double(info.rootTotal) > 0.85 {
                items.append(.init(id: "root-\(node)", severity: .warning, symbol: "internaldrive", title: "\(node)'s system disk is nearly full",
                                   detail: "\(Format.bytes(info.rootTotal - info.rootUsed)) free of \(Format.bytes(info.rootTotal))", destination: .node(node, tab: "summary")))
            }
        }
        for (node, count) in updates.sorted(by: { $0.key < $1.key }) where count > 0 {
            items.append(.init(id: "updates-\(node)", severity: .info, symbol: "arrow.down.circle", title: "\(Format.count(count, "update")) for \(node)",
                               detail: "Install them under Updates.", destination: .node(node, tab: "updates")))
        }
        return items.sorted { $0.severity > $1.severity }
    }
}
