import AppKit
import Foundation
import Observation

/// Where the main window is pointed: the sidebar selection.
nonisolated enum Place: Hashable {
    case overview, guests, tasks
    case node(String)
    case guest(Int)
    case storage(node: String, id: String)
    case pool(String)
    case backups, replication, storageConfig, permissions, ha, firewall, sdn, options
}

/// A Proxmox task started from this app, followed until it finishes.
struct Activity: Identifiable, Equatable {
    enum State: Equatable { case running, succeeded, failed(String) }

    let upid: String
    let title: String
    let node: String
    let started: Date
    var state: State = .running
    var finished: Date?

    var id: String { upid }
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// One signed-in connection: live cluster state plus the window's navigation.
@Observable
final class Session {
    let server: ServerProfile
    let client: ProxmoxClient

    // Live state, refreshed every few seconds.
    private(set) var resources: [Resource] = []
    private(set) var clusterTasks: [TaskEntry] = []
    private(set) var clusterName: String?
    private(set) var quorate: Bool?
    private(set) var version = ""
    private(set) var loaded = false
    private(set) var problem: String?
    private(set) var activities: [Activity] = []
    /// Bumped whenever something changed on the server, so open views reload.
    private(set) var revision = 0

    // Navigation and presentation.
    var selection: Place? = .overview
    var guestTab = "summary"
    var nodeTab = "summary"
    var storageTab = "summary"
    var search = ""
    var alert: AlertItem?
    var confirmation: Confirmation?
    var needsReauth = false
    var sheet: SheetRoute?

    enum SheetRoute: Identifiable {
        case createVM(node: String?), createCT(node: String?)
        case clone(Resource), migrate(Resource), destroy(Resource), backup(Resource), snapshot(Resource)
        /// Start, shut down, suspend or migrate many guests; node nil means the whole cluster.
        case bulk(action: String, node: String?, vmids: [Int])

        var id: String {
            switch self {
            case .createVM: "create-vm"
            case .createCT: "create-ct"
            case .clone(let guest): "clone-\(guest.id)"
            case .migrate(let guest): "migrate-\(guest.id)"
            case .destroy(let guest): "destroy-\(guest.id)"
            case .backup(let guest): "backup-\(guest.id)"
            case .snapshot(let guest): "snapshot-\(guest.id)"
            case .bulk(let action, let node, _): "bulk-\(action)-\(node ?? "cluster")"
            }
        }
    }

    private var poller: Task<Void, Never>?
    private var followers: [String: Task<Void, Never>] = [:]

    init(server: ServerProfile, client: ProxmoxClient) {
        self.server = server
        self.client = client
        #if DEBUG
        // Visual checks: PROXIMA_DEBUG_PLACE=guest:100, node:pve1, storage:pve1:local or a datacenter page; PROXIMA_DEBUG_TAB picks the tab.
        let environment = ProcessInfo.processInfo.environment
        if let place = environment["PROXIMA_DEBUG_PLACE"] { debugGo(to: place) }
        if let tab = environment["PROXIMA_DEBUG_TAB"] { guestTab = tab; nodeTab = tab; storageTab = tab }
        debugSheet = environment["PROXIMA_DEBUG_SHEET"]
        if let file = environment["PROXIMA_DEBUG_NAV"] { followDebugNavigation(file) }
        #endif
    }

    #if DEBUG
    private func debugGo(to place: String) {
        let parts = place.split(separator: ":").map(String.init)
        let pages: [String: Place] = ["overview": .overview, "guests": .guests, "tasks": .tasks, "backups": .backups, "replication": .replication,
                                      "storage": .storageConfig, "permissions": .permissions, "ha": .ha, "firewall": .firewall, "sdn": .sdn, "options": .options]
        switch parts.first {
        case "guest": selection = Int(parts.last ?? "").map(Place.guest)
        case "node": selection = .node(parts.last ?? "")
        case "storage" where parts.count == 3: selection = .storage(node: parts[1], id: parts[2])
        case "pool": selection = .pool(parts.last ?? "")
        default: selection = pages[place] ?? .overview
        }
    }

    /// Visual checks: PROXIMA_DEBUG_NAV=<file> moves the running app whenever the file changes. The file holds
    /// "<place> [tab]" (as for PROXIMA_DEBUG_PLACE) or "appearance light|dark".
    private func followDebugNavigation(_ file: String) {
        Task { [weak self] in
            var last = ""
            while let self {
                let line = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if line != last, !line.isEmpty {
                    last = line
                    let words = line.split(separator: " ").map(String.init)
                    if words.first == "appearance" {
                        NSApplication.shared.appearance = NSAppearance(named: words.last == "light" ? .aqua : .darkAqua)
                    } else {
                        if let tab = words.dropFirst().first { guestTab = tab; nodeTab = tab; storageTab = tab }
                        DebugNavigator.shared.go(tab: words.dropFirst().first)
                        debugGo(to: words.first ?? "overview")
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
    #endif

    #if DEBUG
    /// PROXIMA_DEBUG_SHEET=createVM, createCT, or clone/migrate/destroy/backup/snapshot:<vmid>; opened once resources load.
    private var debugSheet: String?

    private func openDebugSheet() {
        guard let request = debugSheet else { return }
        debugSheet = nil
        let parts = request.split(separator: ":").map(String.init)
        let guest = parts.count > 1 ? Int(parts[1]).flatMap(self.guest) : nil
        switch parts.first {
        case "createVM": sheet = .createVM(node: nil)
        case "createCT": sheet = .createCT(node: nil)
        case "clone": sheet = guest.map(SheetRoute.clone)
        case "migrate": sheet = guest.map(SheetRoute.migrate)
        case "destroy": sheet = guest.map(SheetRoute.destroy)
        case "backup": sheet = guest.map(SheetRoute.backup)
        case "snapshot": sheet = guest.map(SheetRoute.snapshot)
        case "bulk": sheet = .bulk(action: parts.count > 1 ? parts[1] : "start", node: parts.count > 2 ? parts[2] : nil, vmids: [])
        default: break
        }
    }
    #endif

    var userid: String { client.userid }
    var usesToken: Bool { server.usesToken }

    // MARK: Lookups

    var nodes: [Resource] { resources.filter(\.isNode).sorted { $0.node.localizedStandardCompare($1.node) == .orderedAscending } }
    var guests: [Resource] { resources.filter(\.isGuest).sorted { $0.vmid < $1.vmid } }
    var pools: [String] { resources.filter { $0.type == "pool" }.map(\.pool).sorted() }
    var onlineNodes: [String] { nodes.filter(\.isOnline).map(\.node) }
    var runningTaskCount: Int { clusterTasks.filter(\.isRunning).count }
    var isCluster: Bool { nodes.count > 1 }

    func guests(on node: String) -> [Resource] { guests.filter { $0.node == node } }
    func storages(on node: String) -> [Resource] {
        resources.filter { $0.isStorage && $0.node == node }.sorted { $0.storage < $1.storage }
    }
    func guest(_ vmid: Int) -> Resource? { resources.first { $0.isGuest && $0.vmid == vmid } }
    func node(_ name: String) -> Resource? { resources.first { $0.isNode && $0.node == name } }
    func storage(_ id: String, on node: String) -> Resource? {
        resources.first { $0.isStorage && $0.storage == id && $0.node == node }
    }
    var allTags: [String] { Array(Set(guests.flatMap(\.tags))).sorted() }

    // MARK: Polling

    func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshResources()
                if tick % 2 == 0 { await self.refreshTasks() }
                if tick % 20 == 0 { await self.refreshCluster() }
                tick += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
        followers.values.forEach { $0.cancel() }
        followers.removeAll()
    }

    func refresh() async {
        await refreshResources()
        await refreshTasks()
        await refreshCluster()
        revision += 1
    }

    func refreshResources() async {
        do {
            let list = try await client.list("/cluster/resources").map(Resource.init)
            if list != resources { resources = list }
            loaded = true
            problem = nil
            #if DEBUG
            openDebugSheet()
            #endif
        } catch {
            handleBackground(error)
        }
    }

    func refreshTasks() async {
        guard let list = try? await client.list("/cluster/tasks") else { return }
        let tasks = list.map(TaskEntry.init).sorted { $0.start > $1.start }
        if tasks != clusterTasks { clusterTasks = tasks }
    }

    private func refreshCluster() async {
        if let info = try? await client.object("/version") { version = info.string("version") ?? "" }
        if let status = try? await client.list("/cluster/status"),
           let cluster = status.first(where: { $0.string("type") == "cluster" }) {
            clusterName = cluster.text("name")
            quorate = cluster.bool("quorate")
        } else {
            clusterName = nil
            quorate = nil
        }
    }

    private func handleBackground(_ error: Error) {
        if case PVEError.unauthorized = error {
            needsReauth = true
        } else if !(error is CancellationError) {
            problem = error.localizedDescription
        }
    }

    // MARK: Actions

    /// Runs an API call that changes something. Tasks it starts are followed in the activity pill;
    /// failures surface as an alert titled "Couldn't <title>".
    @discardableResult
    func run(_ title: String, _ method: HTTPMethod, _ path: String, _ params: [String: String] = [:]) async -> Bool {
        do {
            let data = try await client.call(method, path, params).data
            if let upid = data as? String, upid.hasPrefix("UPID:") {
                track(upid, title: title)
            } else {
                changed()
            }
            return true
        } catch {
            report(error, doing: title)
            return false
        }
    }

    /// Like `run`, but hands back the response (for calls that return data, e.g. a new API token).
    func call(_ title: String, _ method: HTTPMethod, _ path: String, _ params: [String: String] = [:]) async -> Any?? {
        do {
            let data = try await client.call(method, path, params).data
            changed()
            return .some(data)
        } catch {
            report(error, doing: title)
            return nil
        }
    }

    func report(_ error: Error, doing title: String) {
        if case PVEError.unauthorized = error {
            needsReauth = true
            return
        }
        guard !(error is CancellationError) else { return }
        let verb = title.prefix(1).lowercased() + title.dropFirst()
        alert = AlertItem(title: "Couldn't \(verb)", message: error.localizedDescription)
    }

    func changed() {
        revision += 1
        Task { await refreshResources() }
    }

    func track(_ upid: String, title: String) {
        guard let parsed = UPID(upid), followers[upid] == nil else { return }
        activities.insert(Activity(upid: upid, title: title, node: parsed.node, started: .now), at: 0)
        if activities.count > 20 { activities.removeLast(activities.count - 20) }
        followers[upid] = Task { [weak self] in await self?.follow(upid, node: parsed.node) }
    }

    func dismissActivity(_ id: String) {
        activities.removeAll { $0.id == id }
    }

    private func follow(_ upid: String, node: String) async {
        var failures = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(900))
            do {
                let status = try await client.object("/nodes/\(node.enc)/tasks/\(upid.enc)/status")
                guard status.string("status") == "stopped" else { continue }
                let exit = status.string("exitstatus") ?? "OK"
                let ok = exit == "OK" || exit.hasPrefix("WARNINGS")
                update(upid) {
                    $0.state = ok ? .succeeded : .failed(exit)
                    $0.finished = .now
                }
                followers[upid] = nil
                changed()
                await refreshTasks()
                return
            } catch {
                failures += 1
                if failures > 20 {
                    followers[upid] = nil
                    return
                }
            }
        }
    }

    private func update(_ id: String, _ change: (inout Activity) -> Void) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        change(&activities[index])
    }
}
