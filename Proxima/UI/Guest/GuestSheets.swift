import SwiftUI

/// Presents whichever app-wide sheet the session asks for.
struct SheetHost: View {
    @Environment(Session.self) private var session
    let route: Session.SheetRoute

    var body: some View {
        switch route {
        case .createVM(let node): CreateVMWizard(initialNode: node)
        case .createCT(let node): CreateCTWizard(initialNode: node)
        case .clone(let guest): CloneSheet(guest: guest)
        case .migrate(let guest): MigrateSheet(guest: guest)
        case .destroy(let guest): DestroySheet(guest: guest)
        case .backup(let guest): BackupNowSheet(guest: guest)
        case .snapshot(let guest): SnapshotSheet(guest: guest)
        case .bulk(let action, let node, let vmids): BulkActionSheet(action: action, node: node, preselected: vmids)
        }
    }
}

private struct CloneSheet: View {
    @Environment(Session.self) private var session
    let guest: Resource

    var body: some View {
        Prepared(load: {
            let next = (try? await session.client.get("/cluster/nextid")).flatMap { jsonInt($0) } ?? 100
            let storages = await session.storageChoices(on: guest.node, content: guest.kind == .qemu ? "images" : "rootdir")
            return (next, storages)
        }) { loaded in
            let (next, storages) = loaded
            let nodes = session.onlineNodes.map { FormField.Choice($0) }
            let isVM = guest.kind == .qemu
            FormSheet(title: "Clone \(guest.displayName)",
                      message: guest.isTemplate ? "A linked clone shares the template's disks and is created instantly. A full clone copies everything."
                                                : "A full copy of the disks is made. Only templates can be linked-cloned.",
                      fields: [
                        FormField(key: "target", label: "Target node", kind: .choice(nodes), required: true),
                        FormField(key: "newid", label: isVM ? "VM ID" : "CT ID", kind: .number, required: true),
                        FormField(key: "name", label: isVM ? "Name" : "Hostname", prompt: "\(guest.displayName)-clone"),
                        FormField(key: "full", label: "Full clone", kind: .toggle),
                        FormField(key: "storage", label: "Target storage", kind: .choice(storages), help: "Only for full clones; empty keeps the source storage"),
                      ],
                      initial: ["target": guest.node, "newid": String(next), "name": "\(guest.displayName)-clone", "full": guest.isTemplate ? "0" : "1"],
                      submitTitle: "Clone") { result in
                var params = ["newid": result["newid"], "full": guest.isTemplate ? result["full"] : "1"]
                params[isVM ? "name" : "hostname"] = result["name"].isEmpty ? nil : result["name"]
                if result["target"] != guest.node { params["target"] = result["target"] }
                if params["full"] == "1", !result["storage"].isEmpty { params["storage"] = result["storage"] }
                return await session.run("Clone \(guest.displayName)", .post, "/nodes/\(guest.node.enc)/\(guest.type)/\(guest.vmid)/clone", params)
            }
        }
    }
}

private struct MigrateSheet: View {
    @Environment(Session.self) private var session
    let guest: Resource

    var body: some View {
        // Proxmox's own checks first, like the web UI: nodes missing the guest's storage, local disks and devices.
        Prepared(load: { (try? await session.client.object("/nodes/\(guest.node.enc)/\(guest.type)/\(guest.vmid)/migrate")) ?? [:] }) { checks in
            form(checks)
        }
    }

    private func form(_ checks: JSONObject) -> some View {
        let online = session.onlineNodes.filter { $0 != guest.node }
        // VMs answer with allowed_nodes, containers with allowed-nodes.
        let allowed = checks["allowed_nodes"] != nil || checks["allowed-nodes"] != nil
            ? Set(checks.strings("allowed_nodes") + checks.strings("allowed-nodes")) : Set(online)
        let blocked = (checks.object("not_allowed_nodes") ?? checks.object("not-allowed-nodes") ?? [:])
        let targets = online.filter(allowed.contains).map { FormField.Choice($0) }
        let running = guest.power == .running
        let isVM = guest.kind == .qemu
        let localResources = checks.strings("local_resources")
        let localDisks = checks.objects("local_disks").filter { !$0.bool("cdrom") || ($0.string("volid") ?? "").contains("cloudinit") }

        var notes: [String] = []
        for (node, reason) in blocked.sorted(by: { $0.key < $1.key }) {
            let storages = (reason as? JSONObject)?.strings("unavailable_storages") ?? []
            notes.append(storages.isEmpty ? "\(node) can't take it." : "\(node) lacks the storage \(storages.joined(separator: ", ")).")
        }
        if !localResources.isEmpty {
            notes.append("Uses devices of \(guest.node) (\(localResources.joined(separator: ", "))), so it can only move while stopped.")
        }
        if !localDisks.isEmpty {
            notes.append("Copies \(localDisks.count == 1 ? "a local disk" : "\(localDisks.count) local disks"), which can take a while.")
        }

        var fields = [FormField(key: "target", label: "Target node", kind: .choice(targets), required: true)]
        if running && isVM { fields.append(FormField(key: "online", label: "Live migration", kind: .toggle, help: "Keeps the VM running during the move")) }
        if running && isVM && checks.bool("has-dbus-vmstate") {
            fields.append(FormField(key: "with-conntrack-state", label: "Keep network connections", kind: .toggle,
                                    help: "Moves the firewall's connection tracking along, so open connections survive"))
        }
        if running && !isVM { fields.append(FormField(key: "restart", label: "Restart mode", kind: .toggle, help: "Shuts the container down, moves it, and starts it again")) }
        if isVM { fields.append(FormField(key: "with-local-disks", label: "Copy local disks", kind: .toggle)) }
        fields.append(FormField(key: "targetstorage", label: "Target storage", prompt: "Same storage IDs on the target"))
        let intro = targets.isEmpty ? "There's no node this \(guest.kind?.noun ?? "guest") can move to right now."
            : "Moves the \(guest.kind?.noun ?? "guest") from \(guest.node) to another node."
        return FormSheet(title: "Migrate \(guest.displayName)", message: ([intro] + notes).joined(separator: "\n"),
                         fields: fields, initial: ["target": targets.first?.value ?? "", "online": "1", "restart": "1", "with-conntrack-state": "1",
                                                   "with-local-disks": localDisks.isEmpty ? "0" : "1"],
                         submitTitle: "Migrate") { result in
            var params = ["target": result["target"]]
            if running && isVM { params["online"] = result["online"] }
            if running && isVM && checks.bool("has-dbus-vmstate") { params["with-conntrack-state"] = result["with-conntrack-state"] == "1" ? "1" : "0" }
            if running && !isVM, result["restart"] == "1" { params["restart"] = "1" }
            if isVM, result["with-local-disks"] == "1" { params["with-local-disks"] = "1" }
            if !result["targetstorage"].isEmpty { params[isVM ? "targetstorage" : "target-storage"] = result["targetstorage"] }
            return await session.run("Migrate \(guest.displayName)", .post, "/nodes/\(guest.node.enc)/\(guest.type)/\(guest.vmid)/migrate", params)
        }
    }
}

private struct BackupNowSheet: View {
    @Environment(Session.self) private var session
    let guest: Resource

    var body: some View {
        Prepared(load: {
            // The node's /etc/vzdump.conf, like the web UI: its storage, mode, compression and notes come first.
            (await session.storageChoices(on: guest.node, content: "backup"), (try? await session.client.object("/nodes/\(guest.node.enc)/vzdump/defaults")) ?? [:])
        }) { loaded in
            let (storages, defaults) = loaded
            FormSheet(title: "Back up \(guest.displayName)", fields: [
                FormField(key: "storage", label: "Storage", kind: .choice(storages), required: true),
                FormField(key: "mode", label: "Mode", kind: .choice(Choices.backupModes),
                          help: "Snapshot keeps the guest running; Stop gives the most consistent backup", required: true),
                FormField(key: "compress", label: "Compression", kind: .choice(Choices.compression), required: true),
                FormField(key: "notes-template", label: "Notes", prompt: "{{guestname}}", help: "Variables: {{guestname}}, {{vmid}}, {{node}}, {{cluster}}"),
                FormField(key: "protected", label: "Protect from pruning and deletion", kind: .toggle),
            ], initial: ["storage": defaults.text("storage").flatMap { name in storages.first { $0.value == name }?.value } ?? storages.first?.value ?? "",
                         "mode": defaults.text("mode") ?? "snapshot", "compress": defaults.text("compress") ?? "zstd",
                         "notes-template": defaults.text("notes-template") ?? "{{guestname}}", "protected": defaults.bool("protected") ? "1" : "0"],
                      submitTitle: "Back Up") { result in
                var params = result.changed
                params["vmid"] = String(guest.vmid)
                if params["protected"] == "0" { params["protected"] = nil }
                return await session.run("Back up \(guest.displayName)", .post, "/nodes/\(guest.node.enc)/vzdump", params)
            }
        }
    }
}

private struct SnapshotSheet: View {
    @Environment(Session.self) private var session
    let guest: Resource

    var body: some View {
        var fields = [FormField(key: "snapname", label: "Name", prompt: "before-upgrade",
                                help: "Letters, digits, - and _; must start with a letter", required: true),
                      FormField(key: "description", label: "Description", kind: .multiline)]
        if guest.kind == .qemu, guest.power == .running {
            fields.append(FormField(key: "vmstate", label: "Include memory", kind: .toggle, help: "Saves the running state so a rollback resumes exactly here"))
        }
        let suggested = "snap-" + Date.now.formatted(.iso8601.year().month().day()).replacingOccurrences(of: "-", with: "")
        return FormSheet(title: "Take snapshot of \(guest.displayName)", fields: fields, initial: ["snapname": suggested], submitTitle: "Take Snapshot") { result in
            guard result["snapname"].wholeMatch(of: /[A-Za-z][A-Za-z0-9_\-]{1,39}/) != nil else {
                session.alert = AlertItem(title: "That name won't work", message: "Use 2–40 letters, digits, - or _, starting with a letter.")
                return false
            }
            var params = result.changed
            if params["vmstate"] == "0" { params["vmstate"] = nil }
            return await session.run("Take snapshot \(result["snapname"])", .post, "/nodes/\(guest.node.enc)/\(guest.type)/\(guest.vmid)/snapshot", params)
        }
    }
}

/// Destroying asks for the ID, like the Proxmox web UI.
private struct DestroySheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let guest: Resource
    @State private var typed = ""
    @State private var purge = true
    @State private var unreferenced = true
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "trash.fill").font(.system(size: 30)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Destroy \(guest.displayName)?").font(.title2.bold())
                    Text("Its configuration and all of its disks are deleted. Backups stay.").foregroundStyle(.secondary)
                }
            }
            if guest.power != .stopped {
                ErrorBanner(message: "\(guest.displayName) is \(guest.power.label.lowercased()). Stop it first.")
            }
            Toggle("Remove from backup, replication and HA jobs", isOn: $purge)
            Toggle("Also delete unreferenced disks owned by this guest", isOn: $unreferenced)
            TextField("Type \(String(guest.vmid)) to confirm", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Destroy", role: .destructive) {
                    Task {
                        busy = true
                        var params: [String: String] = [:]
                        if purge { params["purge"] = "1" }
                        if unreferenced { params["destroy-unreferenced-disks"] = "1" }
                        if await session.run("Destroy \(guest.displayName)", .delete, "/nodes/\(guest.node.enc)/\(guest.type)/\(guest.vmid)", params) {
                            session.selection = .node(guest.node)
                            dismiss()
                        }
                        busy = false
                    }
                }
                .disabled(typed != String(guest.vmid) || guest.power != .stopped || busy)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 480)
    }
}
