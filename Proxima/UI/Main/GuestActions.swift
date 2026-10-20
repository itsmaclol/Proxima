import SwiftUI

/// Every guest action lives here so the sidebar, tables, toolbar and menu bar behave the same.
struct GuestActions {
    let session: Session
    let guest: Resource

    var path: String { "/nodes/\(guest.node.enc)/\(guest.type)/\(guest.vmid)" }
    private var name: String { guest.displayName }

    func power(_ action: String) async {
        let verbs = ["start": "Start", "shutdown": "Shut down", "reboot": "Reboot", "stop": "Stop", "reset": "Reset",
                     "suspend": "Pause", "resume": "Resume"]
        await session.run("\(verbs[action] ?? action) \(name)", .post, path + "/status/\(action)")
    }

    func confirmStop() {
        session.confirmation = Confirmation(
            title: "Stop \(name) immediately?",
            message: "This cuts the power like pulling the plug. Unsaved data inside the \(guest.kind?.noun ?? "guest") is lost. Use Shut Down for a clean stop.",
            actionTitle: "Stop", destructive: true) { await power("stop") }
    }

    func confirmReset() {
        session.confirmation = Confirmation(
            title: "Reset \(name)?",
            message: "This restarts the VM without letting the operating system shut down, like pressing a reset button.",
            actionTitle: "Reset", destructive: true) { await power("reset") }
    }

    func openSPICE() async {
        await session.openSPICE(path + "/spiceproxy", name: String(guest.vmid))
    }

    func confirmTemplate() {
        session.confirmation = Confirmation(
            title: "Convert \(name) to a template?",
            message: "Templates can't be started or changed back. You'll create new guests from it with Clone.",
            actionTitle: "Convert", destructive: false) {
                await session.run("Convert \(name) to a template", .post, path + "/template")
            }
    }
}

struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let actionTitle: String
    let destructive: Bool
    let action: () async -> Void
}

/// Start / Shut Down / Reboot / Stop… as menu items, adapted to the current state.
struct GuestPowerItems: View {
    let actions: GuestActions

    var body: some View {
        let guest = actions.guest
        if guest.isTemplate {
            Text("Templates can't be started")
        } else {
            switch guest.power {
            case .stopped:
                Button("Start", systemImage: "play.fill") { Task { await actions.power("start") } }
            case .paused:
                Button("Resume", systemImage: "play.fill") { Task { await actions.power("resume") } }
                Button("Stop…", systemImage: "stop.fill") { actions.confirmStop() }
            default:
                Button("Shut Down", systemImage: "power") { Task { await actions.power("shutdown") } }
                Button("Reboot", systemImage: "arrow.clockwise") { Task { await actions.power("reboot") } }
                if guest.kind == .qemu {
                    Button("Pause", systemImage: "pause.fill") { Task { await actions.power("suspend") } }
                    Button("Reset…", systemImage: "arrow.counterclockwise") { actions.confirmReset() }
                }
                Button("Stop…", systemImage: "stop.fill") { actions.confirmStop() }
            }
        }
    }
}

/// The full context menu for a guest.
struct GuestMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    let actions: GuestActions

    var body: some View {
        let guest = actions.guest
        let session = actions.session
        GuestPowerItems(actions: actions)
        Divider()
        if !guest.isTemplate {
            Button("Open Console", systemImage: "terminal") {
                openWindow(id: "console", value: ConsoleTarget(guest: guest))
            }
            Button("Open in Remote Viewer (SPICE)", systemImage: "display") { Task { await actions.openSPICE() } }
        }
        Button("Clone…", systemImage: "plus.square.on.square") { session.sheet = .clone(guest) }
        if session.isCluster {
            Button("Migrate…", systemImage: "arrow.left.arrow.right") { session.sheet = .migrate(guest) }
        }
        Button("Back Up Now…", systemImage: "clock.arrow.circlepath") { session.sheet = .backup(guest) }
        Button("Take Snapshot…", systemImage: "camera") { session.sheet = .snapshot(guest) }
        if !guest.isTemplate {
            Button("Convert to Template…", systemImage: "square.on.square.dashed") { actions.confirmTemplate() }
                .disabled(guest.power != .stopped)
        }
        Divider()
        Button("Destroy…", systemImage: "trash", role: .destructive) { session.sheet = .destroy(guest) }
    }
}

/// Node-level actions: shell, bulk start/stop, reboot, shut down.
struct NodeMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    let session: Session
    let node: String

    var body: some View {
        Button("Open Shell", systemImage: "terminal") {
            openWindow(id: "console", value: ConsoleTarget(kind: "shell", node: node, vmid: nil, name: node))
        }
        Button("Open Shell in Remote Viewer (SPICE)", systemImage: "display") {
            Task { await session.openSPICE("/nodes/\(node.enc)/spiceshell", name: node) }
        }
        Divider()
        Button("Start Guests…", systemImage: "play.fill") { session.sheet = .bulk(action: "start", node: node, vmids: []) }
        Button("Shut Down Guests…", systemImage: "power") { session.sheet = .bulk(action: "shutdown", node: node, vmids: []) }
        Button("Suspend Guests…", systemImage: "pause.fill") { session.sheet = .bulk(action: "suspend", node: node, vmids: []) }
        if session.isCluster {
            Button("Migrate Guests…", systemImage: "arrow.left.arrow.right") { session.sheet = .bulk(action: "migrate", node: node, vmids: []) }
        }
        Divider()
        Button("Reboot Node…", systemImage: "arrow.clockwise") {
            session.confirmation = Confirmation(title: "Reboot \(node)?",
                                                message: "Running guests are shut down first. The node and its guests are unavailable until it's back.",
                                                actionTitle: "Reboot", destructive: true) {
                await session.run("Reboot \(node)", .post, "/nodes/\(node.enc)/status", ["command": "reboot"])
            }
        }
        Button("Shut Down Node…", systemImage: "power") {
            session.confirmation = Confirmation(title: "Shut down \(node)?",
                                                message: "You'll need physical or out-of-band access to turn it back on.",
                                                actionTitle: "Shut Down", destructive: true) {
                await session.run("Shut down \(node)", .post, "/nodes/\(node.enc)/status", ["command": "shutdown"])
            }
        }
    }
}

extension Session {
    /// Gets a one-time SPICE ticket from `path` (a guest's spiceproxy or a node's spiceshell) and hands it to the Mac's
    /// SPICE client, such as Remote Viewer, like the web UI's .vv download.
    func openSPICE(_ path: String, name: String) async {
        guard let result = await call("Open the SPICE console", .post, path, ["proxy": server.host]),
              let ticket = result as? JSONObject else { return }
        let lines = ["[virt-viewer]"] + ticket.keys.sorted().map { "\($0)=\(ticket.string($0) ?? "")" }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).vv")
        do {
            try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        } catch {
            report(error, doing: "Open the SPICE console")
            return
        }
        guard NSWorkspace.shared.urlForApplication(toOpen: file) != nil else {
            try? FileManager.default.removeItem(at: file)
            alert = AlertItem(title: "No SPICE viewer installed",
                              message: "SPICE consoles open in a separate viewer app. Install Remote Viewer (for example with “brew install virt-viewer”), then try again, or use the built-in console.")
            return
        }
        NSWorkspace.shared.open(file)
    }
}

