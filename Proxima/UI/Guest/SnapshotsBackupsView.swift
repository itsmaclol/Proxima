import SwiftUI

// MARK: Snapshots

/// Snapshots as a timeline ending at "now".
struct SnapshotsView: View {
    @Environment(Session.self) private var session
    let guest: Resource
    @State private var snapshots: [Snapshot] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: Snapshot?

    private var path: String { "/nodes/\(guest.node.enc)/\(guest.type)/\(guest.vmid)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Take Snapshot", systemImage: "camera") { session.sheet = .snapshot(guest) }
                    .buttonStyle(.glassProminent)
                    .disabled(guest.isTemplate)
                Spacer()
                Text("\(snapshots.filter { !$0.isCurrent }.count) snapshot\(snapshots.count == 2 ? "" : "s")").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            Loadable(loading: !loaded, error: error, isEmpty: false) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(ordered.enumerated()), id: \.element.0.id) { index, entry in
                            SnapshotRow(snapshot: entry.0, depth: entry.1, isLast: index == ordered.count - 1, guest: guest,
                                        rollback: { rollback(entry.0) }, edit: { editing = entry.0 }, delete: { delete(entry.0) })
                        }
                        if ordered.count == 1 {
                            Text("No snapshots yet. A snapshot saves the disks (and optionally memory) so you can return to this moment, for example before an upgrade.")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 40)
                                .padding(.top, 12)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: "\(guest.vmid)-\(session.revision)") { await load() }
        .sheet(item: $editing) { snapshot in
            FormSheet(title: "Edit \(snapshot.name)", fields: [FormField(key: "description", label: "Description", kind: .multiline)],
                      initial: ["description": snapshot.description], isEdit: true) { result in
                await session.run("Save the snapshot description", .put, path + "/snapshot/\(snapshot.name.enc)/config", ["description": result["description"]])
            }
        }
    }

    /// Depth-first through the parent links, oldest first, with "current" last in its branch.
    private var ordered: [(Snapshot, Int)] {
        let children = Dictionary(grouping: snapshots) { $0.parent ?? "" }
        var result: [(Snapshot, Int)] = []
        func walk(_ parent: String, _ depth: Int) {
            let kids = (children[parent] ?? []).sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return rhs.isCurrent }
                return (lhs.date ?? .distantFuture) < (rhs.date ?? .distantFuture)
            }
            for (index, kid) in kids.enumerated() {
                result.append((kid, depth))
                walk(kid.name, kids.count > 1 && index < kids.count - 1 ? depth + 1 : depth)
            }
        }
        walk("", 0)
        return result
    }

    private func load() async {
        do {
            snapshots = try await session.client.list(path + "/snapshot").map(Snapshot.init)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func rollback(_ snapshot: Snapshot) {
        session.confirmation = Confirmation(
            title: "Roll back \(guest.displayName) to “\(snapshot.name)”?",
            message: "The current state of the disks\(snapshot.includesRAM ? " and memory" : "") is replaced by the snapshot. Changes since then are lost.",
            actionTitle: "Roll Back", destructive: true) {
                await session.run("Roll back to \(snapshot.name)", .post, path + "/snapshot/\(snapshot.name.enc)/rollback")
            }
    }

    private func delete(_ snapshot: Snapshot) {
        session.confirmation = Confirmation(title: "Delete snapshot “\(snapshot.name)”?", message: "The guest keeps running as it is; you just can't return to this point anymore.",
                                            actionTitle: "Delete", destructive: true) {
            await session.run("Delete snapshot \(snapshot.name)", .delete, path + "/snapshot/\(snapshot.name.enc)")
        }
    }
}

private struct SnapshotRow: View {
    let snapshot: Snapshot
    let depth: Int
    let isLast: Bool
    let guest: Resource
    let rollback: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .top) {
                if !isLast {
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2).padding(.top, 14)
                }
                if snapshot.isCurrent {
                    Circle().fill(Color.accentColor).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.accentColor.opacity(0.35), lineWidth: 5))
                } else {
                    Circle().fill(Theme.cardFill).frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(Color.secondary, lineWidth: 2))
                }
            }
            .frame(width: 18)
            .padding(.leading, CGFloat(depth) * 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(snapshot.isCurrent ? "Now" : snapshot.name).font(.headline)
                    if snapshot.isCurrent {
                        Text("You are here").font(.callout).foregroundStyle(.secondary)
                    }
                    if snapshot.includesRAM { Pill(text: "Includes memory", systemImage: "memorychip") }
                }
                if !snapshot.isCurrent {
                    if let date = snapshot.date {
                        Text("\(Format.dateTime(date)), \(Format.relative(date))").font(.callout).foregroundStyle(.secondary)
                    }
                    if !snapshot.description.isEmpty {
                        Text(snapshot.description).font(.callout).textSelection(.enabled)
                    }
                }
            }
            .padding(.bottom, 22)
            Spacer()
            if !snapshot.isCurrent {
                HStack(spacing: 6) {
                    Button("Roll Back", action: rollback)
                    Button("Edit", action: edit)
                    Button("Delete", role: .destructive, action: delete)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .opacity(hovering ? 1 : 0.55)
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

// MARK: Backups

struct BackupVolume: Identifiable, Hashable {
    let storage: String
    let volume: Volume
    var id: String { volume.volid }
}

/// Backups of one guest across every backup storage the node can reach.
struct GuestBackupsView: View {
    @Environment(Session.self) private var session
    let guest: Resource
    @State private var backups: [BackupVolume] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var selection: BackupVolume.ID?
    @State private var editingNotes: BackupVolume?
    @State private var showingConfig: BackupVolume?

    var body: some View {
        let selected = backups.first { $0.id == selection }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Back Up Now", systemImage: "clock.arrow.circlepath") { session.sheet = .backup(guest) }
                    .buttonStyle(.glassProminent)
                Button("Restore", systemImage: "arrow.uturn.backward") { if let selected { restore(selected) } }
                    .disabled(selected == nil || guest.power != .stopped)
                    .help(guest.power != .stopped ? "Stop the guest before restoring over it" : "Replace the guest with this backup")
                BackupActions(node: guest.node, selected: selected, editingNotes: $editingNotes, showingConfig: $showingConfig)
                Spacer()
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            Loadable(loading: !loaded, error: error, isEmpty: backups.isEmpty, emptyTitle: "No backups yet", emptySymbol: "clock.arrow.circlepath",
                     emptyMessage: "Back up now, or add this guest to a backup job under Datacenter → Backups.") {
                BackupTable(backups: backups, selection: $selection)
            }
        }
        .task(id: "\(guest.vmid)-\(session.revision)") { await load() }
        .sheet(item: $editingNotes) { backup in BackupNotesSheet(node: guest.node, backup: backup) }
        .sheet(item: $showingConfig) { backup in BackupConfigSheet(node: guest.node, backup: backup) }
    }

    private func load() async {
        do {
            var found: [BackupVolume] = []
            for storage in try await session.client.list("/nodes/\(guest.node.enc)/storage", ["content": "backup", "enabled": "1"]) {
                guard let id = storage.text("storage") else { continue }
                let list = (try? await session.client.list("/nodes/\(guest.node.enc)/storage/\(id.enc)/content",
                                                           ["content": "backup", "vmid": String(guest.vmid)])) ?? []
                found += list.map { BackupVolume(storage: id, volume: Volume($0)) }
            }
            backups = found.sorted { ($0.volume.date ?? .distantPast) > ($1.volume.date ?? .distantPast) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func restore(_ backup: BackupVolume) {
        let date = backup.volume.date.map(Format.dateTime) ?? backup.volume.fileName
        session.confirmation = Confirmation(
            title: "Restore \(guest.displayName) from the backup of \(date)?",
            message: "The guest's current disks and configuration are replaced by the backup. Anything newer is lost.",
            actionTitle: "Restore", destructive: true) {
                let params = guest.kind == .qemu
                    ? ["vmid": String(guest.vmid), "archive": backup.volume.volid, "force": "1"]
                    : ["vmid": String(guest.vmid), "ostemplate": backup.volume.volid, "restore": "1", "force": "1"]
                await session.run("Restore \(guest.displayName)", .post, "/nodes/\(guest.node.enc)/\(guest.type)", params)
            }
    }
}

/// Backups table shared by guest and storage pages.
struct BackupTable: View {
    let backups: [BackupVolume]
    @Binding var selection: BackupVolume.ID?

    var body: some View {
        Table(backups, selection: $selection) {
            TableColumn("Date") { backup in
                Text(backup.volume.date.map(Format.dateTime) ?? "–").monospacedDigit()
            }
            .width(min: 150, ideal: 185)
            TableColumn("Guest") { backup in
                Text(verbatim: backup.volume.vmid.map(String.init) ?? "–").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 56)
            TableColumn("Notes") { backup in Text(backup.volume.notes).lineLimit(1) }
                .width(min: 100, ideal: 200)
            TableColumn("Storage") { backup in Text(backup.storage).foregroundStyle(.secondary) }
                .width(min: 70, ideal: 100)
            TableColumn("Size") { backup in Text(Format.bytes(backup.volume.size)).monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("") { backup in
                HStack(spacing: 6) {
                    if backup.volume.isProtected { Image(systemName: "lock.fill").foregroundStyle(.orange).help("Protected") }
                    if backup.volume.verification == "ok" { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("Verified") }
                    if backup.volume.verification == "failed" { Image(systemName: "xmark.seal.fill").foregroundStyle(.red).help("Verification failed") }
                }
            }
            .width(44)
            TableColumn("File") { backup in Text(backup.volume.fileName).fontDesign(.monospaced).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 120, ideal: 300)
        }
    }
}

/// Notes, protection, configuration and delete for the selected backup.
struct BackupActions: View {
    @Environment(Session.self) private var session
    let node: String
    let selected: BackupVolume?
    @Binding var editingNotes: BackupVolume?
    @Binding var showingConfig: BackupVolume?
    @State private var restoringFiles: BackupVolume?
    @State private var pruning: BackupVolume?

    var body: some View {
        Group {
            Button("Restore Files", systemImage: "doc.on.doc") { restoringFiles = selected }
                .disabled(selected?.volume.format.hasPrefix("pbs") != true)
                .help("Browse the backup and download single files (Proxmox Backup Server backups)")
            Button("Notes", systemImage: "note.text") { editingNotes = selected }
            Button(selected?.volume.isProtected == true ? "Unprotect" : "Protect", systemImage: "lock") {
                guard let selected else { return }
                Task {
                    await session.run(selected.volume.isProtected ? "Remove protection" : "Protect the backup", .put,
                                      "/nodes/\(node.enc)/storage/\(selected.storage.enc)/content/\(selected.volume.volid.enc)",
                                      ["protected": selected.volume.isProtected ? "0" : "1"])
                }
            }
            Button("Configuration", systemImage: "doc.text.magnifyingglass") { showingConfig = selected }
            Button("Prune…", systemImage: "scissors") { pruning = selected }
                .help("Keep the newest backups of this guest by retention rules and remove the rest")
            Button("Delete", systemImage: "trash", role: .destructive) {
                guard let selected else { return }
                session.confirmDelete("Delete this backup?", message: selected.volume.isProtected ? "It's protected; remove protection first." : "The backup file is deleted from \(selected.storage).",
                                      path: "/nodes/\(node.enc)/storage/\(selected.storage.enc)/content/\(selected.volume.volid.enc)")
            }
        }
        .disabled(selected == nil)
        .sheet(item: $restoringFiles) { FileRestoreSheet(node: node, backup: $0) }
        .sheet(item: $pruning) { PruneSheet(node: node, backup: $0) }
        .debugAction("prune") {
            Task {
                // Visual checks: the newest backup with a guest on the first backup storage that has one.
                for storage in (try? await session.client.list("/nodes/\(node.enc)/storage", ["content": "backup"])) ?? [] {
                    let id = storage.string("storage") ?? ""
                    if let first = try? await session.client.list("/nodes/\(node.enc)/storage/\(id.enc)/content", ["content": "backup"]).first(where: { $0.int("vmid") != nil }) {
                        pruning = BackupVolume(storage: id, volume: Volume(first))
                        return
                    }
                }
            }
        }
        .debugAction("restore-files", "restore-download") {
            Task {
                // Visual checks: the first Proxmox Backup Server backup on this node.
                for storage in (try? await session.client.list("/nodes/\(node.enc)/storage", ["content": "backup"])) ?? [] where storage.string("type") == "pbs" {
                    let id = storage.string("storage") ?? ""
                    if let first = try? await session.client.list("/nodes/\(node.enc)/storage/\(id.enc)/content", ["content": "backup"]).first {
                        restoringFiles = BackupVolume(storage: id, volume: Volume(first))
                        return
                    }
                }
            }
        }
    }
}

/// Keeps the newest backups of one guest by retention rules and removes the rest, with a preview of which go,
/// like the web UI's Prune Group.
struct PruneSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let node: String
    let backup: BackupVolume

    @State private var keep: [String: String] = [:]
    @State private var keepAll = false
    @State private var preview: [Row] = []
    @State private var error: String?
    @State private var busy = false

    private static let rules = [("keep-last", "Last"), ("keep-hourly", "Hourly"), ("keep-daily", "Daily"),
                                ("keep-weekly", "Weekly"), ("keep-monthly", "Monthly"), ("keep-yearly", "Yearly")]

    /// The retention setting as Proxmox writes it, e.g. "keep-last=3,keep-weekly=4".
    private var setting: String {
        keepAll ? "keep-all=1" : Self.rules.compactMap { key, _ in keep[key].flatMap(Int.init).map { "\(key)=\($0)" } }.joined(separator: ",")
    }

    private var api: String { "/nodes/\(node.enc)/storage/\(backup.storage.enc)/prunebackups" }

    /// Only this guest's backups ("prune group"), with the rules chosen here.
    private var params: [String: String] {
        var params = ["prune-backups": setting]
        if let vmid = backup.volume.vmid { params["vmid"] = String(vmid) }
        if let type = backup.volume.subtype { params["type"] = type }
        return params
    }

    private var guestName: String {
        backup.volume.vmid.map { vmid in session.guest(vmid).map { "\($0.displayName) (\(vmid))" } ?? "guest \(vmid)" } ?? backup.volume.fileName
    }

    private var removing: Int { preview.filter { $0["mark"] == "remove" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Prune backups of \(guestName)").font(.title2.bold())
                Text("Keeps the newest backup in each period you set and removes the rest from \(backup.storage). Protected backups always stay.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 16) {
                Form {
                    Section("Keep") {
                        ForEach(Self.rules, id: \.0) { key, title in
                            TextField(title, text: Binding { keep[key] ?? "" } set: { keep[key] = $0.filter(\.isNumber) }, prompt: Text("–"))
                                .monospacedDigit()
                                .disabled(keepAll)
                        }
                        Toggle("Keep all backups", isOn: $keepAll)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(width: 270)
                Table(preview) {
                    TableColumn("Backup time") { row in Text(Format.epoch(row.json.int("ctime")).map(Format.dateTime) ?? "") }
                        .width(min: 140, ideal: 170)
                    TableColumn("File") { row in Text(Volume(row.json).fileName).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
                    TableColumn("Result") { row in
                        let mark = row["mark"] ?? ""
                        Label(["keep": "Keep", "remove": "Remove", "protected": "Protected", "renamed": "Keep (renamed)"][mark] ?? mark,
                              systemImage: ["keep": "checkmark.circle.fill", "remove": "trash.fill", "protected": "lock.fill"][mark] ?? "circle")
                            .foregroundStyle(mark == "remove" ? .red : mark == "protected" ? .orange : .green)
                    }
                    .width(min: 110, ideal: 130)
                }
                .overlay {
                    if let error { ContentUnavailableView("No preview", systemImage: "exclamationmark.triangle", description: Text(error)) }
                    else if preview.isEmpty { ContentUnavailableView("No backups to prune", systemImage: "archivebox") }
                }
            }
            HStack {
                Text(setting.isEmpty ? "Set at least one rule." : removing == 0 ? "Nothing would be removed." : "\(Format.count(removing, "backup")) would be removed.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Prune") {
                    Task {
                        busy = true
                        if await session.run("Prune backups of \(guestName)", .delete, api, params) { dismiss() }
                        busy = false
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || setting.isEmpty || removing == 0)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 840, height: 520)
        .task {
            // Start from the storage's own retention settings.
            let config = (try? await session.client.object("/storage/\(backup.storage.enc)"))?.string("prune-backups") ?? ""
            for pair in PropertyString(config).pairs where pair.key == "keep-all" { keepAll = pair.value == "1" }
            for pair in PropertyString(config).pairs where pair.key != "keep-all" { keep[pair.key] = pair.value }
        }
        .task(id: setting) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !setting.isEmpty, !Task.isCancelled else { preview = []; return }
            do {
                preview = try await session.client.list(api, params).map { Row(id: $0.string("volid") ?? "", json: $0) }
                    .sorted { ($0.json.int("ctime") ?? 0) > ($1.json.int("ctime") ?? 0) }
                error = nil
            } catch {
                preview = []
                self.error = error.localizedDescription
            }
        }
    }
}

struct BackupNotesSheet: View {
    @Environment(Session.self) private var session
    let node: String
    let backup: BackupVolume

    var body: some View {
        FormSheet(title: "Backup notes", fields: [FormField(key: "notes", label: "Notes", kind: .multiline)],
                  initial: ["notes": backup.volume.notes], isEdit: true) { result in
            await session.run("Save the backup notes", .put, "/nodes/\(node.enc)/storage/\(backup.storage.enc)/content/\(backup.volume.volid.enc)",
                              ["notes": result["notes"]])
        }
    }
}

struct BackupConfigSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let node: String
    let backup: BackupVolume
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration in \(backup.volume.fileName)").font(.title3.bold()).lineLimit(1).truncationMode(.middle)
            ScrollView {
                Text(error ?? (text.isEmpty ? "Loading…" : text))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(error == nil ? Color.primary : .red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 640, height: 480)
        .task {
            do {
                text = try await session.client.get("/nodes/\(node.enc)/vzdump/extractconfig", ["volume": backup.volume.volid]) as? String ?? ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
