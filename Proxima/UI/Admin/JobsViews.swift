import SwiftUI

// MARK: Backup jobs

struct BackupJobsView: View {
    @Environment(Session.self) private var session
    @State private var editing: Row??
    @State private var detail: Row?
    @State private var uncovered: [JSONObject] = []
    @State private var simulating = false

    var body: some View {
        AdminPage(title: "Backups", subtitle: "Scheduled backup jobs for the whole cluster", symbol: "clock.arrow.circlepath", colors: [.teal, .blue]) {
            Button("Schedule Simulator…", systemImage: "calendar.badge.clock") { simulating = true }
            Button("Add Job", systemImage: "plus") { editing = .some(nil) }
        } content: {
            if !uncovered.isEmpty {
                let names = uncovered.prefix(6).map { "\($0.string("name") ?? "") (\($0.string("vmid") ?? ""))" }.joined(separator: ", ")
                ErrorBanner(message: "\(uncovered.count) guest\(uncovered.count == 1 ? " isn't" : "s aren't") in any backup job: \(names)\(uncovered.count > 6 ? "…" : "")")
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }
            ResourceList(path: "/cluster/backup", id: { $0.string("id") ?? "" },
                         columns: [APIColumn("On", width: 44) { $0["enabled"] == nil || $0.bool("enabled") ? "Yes" : "No" },
                                   APIColumn("Node", width: 80) { $0.string("node") ?? "All" },
                                   APIColumn("Schedule", key: "schedule", width: 120, monospaced: true),
                                   APIColumn("Next run", width: 130) {
                                       Format.epoch($0.int("next-run"))?.formatted(.dateTime.month(.abbreviated).day().hour().minute()) ?? "–"
                                   },
                                   APIColumn("Storage", key: "storage", width: 110),
                                   APIColumn("Guests", width: 160) { job in
                                       // The API lists IDs as "101,110"; read them as "101, 110".
                                       let ids = { (list: String) in list.split(separator: ",").joined(separator: ", ") }
                                       return job.bool("all") ? (job.text("exclude").map { "All except \(ids($0))" } ?? "All")
                                           : (job.text("pool").map { "Pool \($0)" } ?? ids(job.string("vmid") ?? ""))
                                   },
                                   APIColumn("Mode", width: 90) { ($0.string("mode") ?? "snapshot").capitalized },
                                   // "keep-last=3,keep-weekly=4" reads as "last 3, weekly 4".
                                   APIColumn("Keep", width: 150) { ($0.string("prune-backups") ?? "").split(separator: ",")
                                       .map { $0.replacingOccurrences(of: "keep-", with: "").replacingOccurrences(of: "=", with: " ") }.joined(separator: ", ") },
                                   APIColumn("Comment", key: "comment", width: 160)],
                         emptyTitle: "No backup jobs", emptySymbol: "clock.arrow.circlepath",
                         emptyMessage: "Schedule regular backups so a broken disk or bad upgrade is never the end.",
                         open: { editing = .some($0) }) { row in
                Button("Run Now") { runNow(row.json) }
                Button("Edit…") { editing = .some(row) }
                Button("Show Details…") { detail = row }
                Button(row.json["enabled"] == nil || row.json.bool("enabled") ? "Disable" : "Enable") {
                    let enabled = row.json["enabled"] == nil || row.json.bool("enabled")
                    Task { await session.run(enabled ? "Disable the job" : "Enable the job", .put, "/cluster/backup/\(row.id.enc)", ["enabled": enabled ? "0" : "1"]) }
                }
            } delete: { row in
                Deletion { session.confirmDelete("Delete this backup job?", message: "Existing backups stay.", path: "/cluster/backup/\(row.id.enc)") }
            }
        }
        .task(id: session.revision) {
            uncovered = (try? await session.client.list("/cluster/backup-info/not-backed-up")) ?? []
        }
        .sheet(item: Binding(get: { editing.map { SimpleEdit(row: $0) } }, set: { editing = $0.map(\.row) })) { edit in
            BackupJobEditor(job: edit.row)
        }
        .sheet(item: $detail) { BackupJobDetailSheet(job: $0) }
        .sheet(isPresented: $simulating) { ScheduleSimulatorSheet() }
        .debugAction("schedule-simulator") { simulating = true }
        .debugAction("job-detail") {
            Task { if let first = try? await session.client.list("/cluster/backup").first { detail = Row(id: first.string("id") ?? "", json: first) } }
        }
    }

    /// The web UI's "Run now": the job's settings, sent as a one-off vzdump to each node it covers.
    private func runNow(_ job: JSONObject) {
        var params: [String: String] = [:]
        for (key, value) in job where !["id", "schedule", "enabled", "type", "node", "comment", "next-run", "repeat-missed", "starttime", "dow", "digest"].contains(key) {
            params[key] = jsonDouble(value).map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? (value as? String ?? "\(value)")
        }
        let nodes = job.text("node").map { [$0] } ?? session.onlineNodes
        session.confirmation = Confirmation(title: "Run this backup job now?", message: "Starts a backup on \(nodes.joined(separator: ", ")).",
                                            actionTitle: "Run Now", destructive: false) {
            for node in nodes { await session.run("Run the backup job on \(node)", .post, "/nodes/\(node.enc)/vzdump", params) }
        }
    }
}

private struct BackupJobEditor: View {
    @Environment(Session.self) private var session
    let job: Row?

    var body: some View {
        Prepared(load: { await session.storageChoices(on: session.onlineNodes.first ?? "", content: "backup") }) { storages in
            let json = job?.json ?? [:]
            FormSheet(title: job == nil ? "Add backup job" : "Edit backup job", message: "Schedules use systemd calendar syntax: daily, sat 02:00, mon..fri 22:30, *-*-* 03:00.", fields: [
                FormField(key: "enabled", label: "Enabled", kind: .toggle),
                FormField(key: "node", label: "Node", kind: .choice(session.nodes.map { FormField.Choice($0.node) })),
                FormField(key: "storage", label: "Storage", kind: .choice(storages), required: true),
                FormField(key: "schedule", label: "Schedule", kind: .suggested(Choices.schedules), prompt: "sat 02:00", required: true),
                FormField(key: "all", label: "All guests", kind: .toggle),
                FormField(key: "vmid", label: "Guests (if not all)", prompt: "100,101,200"),
                FormField(key: "exclude", label: "Exclude (if all)", prompt: "102"),
                FormField(key: "pool", label: "Pool (instead of guests)", kind: .choice(session.pools.map { FormField.Choice($0) })),
                FormField(key: "mode", label: "Mode", kind: .choice(Choices.backupModes), required: true),
                FormField(key: "compress", label: "Compression", kind: .choice(Choices.compression), required: true),
                FormField(key: "prune-backups", label: "Retention", prompt: "keep-last=3,keep-weekly=4"),
                FormField(key: "notes-template", label: "Notes", prompt: "{{guestname}}"),
                FormField(key: "mailto", label: "Email to", prompt: "admin@example.com"),
                FormField(key: "comment", label: "Comment"),
            ], initial: [
                "enabled": json["enabled"] == nil || json.bool("enabled") ? "1" : "0", "node": json.string("node") ?? "",
                "storage": json.string("storage") ?? storages.first?.value ?? "", "schedule": json.string("schedule") ?? "sat 02:00",
                "all": job == nil || json.bool("all") ? "1" : "0", "vmid": json.string("vmid") ?? "", "exclude": json.string("exclude") ?? "",
                "pool": json.string("pool") ?? "", "mode": json.string("mode") ?? "snapshot", "compress": json.string("compress") ?? "zstd",
                "prune-backups": json.string("prune-backups") ?? "", "notes-template": json.string("notes-template") ?? "{{guestname}}",
                "mailto": json.string("mailto") ?? "", "comment": json.string("comment") ?? "",
            ], isEdit: job != nil, submitTitle: job == nil ? "Add" : "Save") { result in
                if let job { return await session.run("Save the backup job", .put, "/cluster/backup/\(job.id.enc)", result.params) }
                var params = result.changed
                if params["all"] == "1" { params["vmid"] = nil; params["pool"] = nil } else { params["all"] = nil; params["exclude"] = nil }
                return await session.run("Add the backup job", .post, "/cluster/backup", params)
            }
        }
    }
}

/// When a schedule runs next, as the server works it out: the web UI's schedule simulator.
struct ScheduleSimulatorSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var schedule = "mon..fri 02:00"
    @State private var runs: [Date] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Schedule Simulator").font(.title2.bold())
                Text("The next times a schedule runs, shown in this Mac's time zone.").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField("Schedule", text: $schedule, prompt: Text("mon..fri 02:00"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { Task { await simulate() } }
                Menu {
                    ForEach(Choices.schedules, id: \.self) { choice in
                        Button(choice.label) { schedule = choice.value; Task { await simulate() } }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Choose an example schedule")
                Button("Simulate") { Task { await simulate() } }
            }
            Group {
                if let error {
                    ContentUnavailableView("Not a valid schedule", systemImage: "calendar.badge.exclamationmark", description: Text(error))
                } else {
                    List(Array(runs.enumerated()), id: \.offset) { index, date in
                        HStack {
                            Text(date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).year()))
                            Spacer()
                            Text(date.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                            Text(index == 0 ? Format.relative(date) : "").foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxHeight: .infinity)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .controlSize(.large)
        .padding(24)
        .frame(width: 560, height: 520)
        .task { await simulate() }
    }

    private func simulate() async {
        do {
            runs = try await session.client.list("/cluster/jobs/schedule-analyze", ["schedule": schedule, "iterations": "10"])
                .compactMap { Format.epoch($0.int("timestamp")) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Replication

struct ReplicationView: View {
    var body: some View {
        AdminPage(title: "Replication", subtitle: "Keep copies of guest disks on other nodes (ZFS)", symbol: "arrow.triangle.2.circlepath", colors: [.cyan, .blue]) {
            EmptyView()
        } content: {
            ReplicationList(guest: nil)
        }
    }
}

/// Replication jobs for the cluster or one guest, with last/next sync from the source node.
struct ReplicationList: View {
    @Environment(Session.self) private var session
    let guest: Int?
    @State private var adding = false
    @State private var status: [String: JSONObject] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add Job", systemImage: "plus") { adding = true }.disabled(!session.isCluster)
                Spacer()
                if !session.isCluster { Text("Replication needs a cluster with at least two nodes.").font(.callout).foregroundStyle(.secondary) }
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            ResourceList(path: "/cluster/replication", id: { $0.string("id") ?? "" },
                         columns: [APIColumn("Guest", key: "guest", width: 70), APIColumn("Job", key: "id", width: 80, monospaced: true),
                                   APIColumn("Target", key: "target", width: 100), APIColumn("Schedule", key: "schedule", width: 100, monospaced: true),
                                   APIColumn("Enabled", width: 70) { $0.bool("disable") ? "No" : "Yes" },
                                   APIColumn("Last sync", width: 150) { [status] job in Format.epoch(status[job.string("id") ?? ""]?.int("last_sync")).map(Format.dateTime) ?? "–" },
                                   APIColumn("Next sync", width: 150) { [status] job in Format.epoch(status[job.string("id") ?? ""]?.int("next_sync")).map(Format.dateTime) ?? "–" },
                                   APIColumn("Status", width: 200) { [status] job in
                                       let state = status[job.string("id") ?? ""]
                                       return state?.text("error") ?? ((state?.int("fail_count") ?? 0) > 0 ? "\(state!.int("fail_count")!) failures" : (state == nil ? "" : "OK"))
                                   },
                                   APIColumn("Comment", key: "comment", width: 200)],
                         emptyTitle: "No replication jobs", emptySymbol: "arrow.triangle.2.circlepath",
                         emptyMessage: "Replication copies ZFS disks to another node on a schedule, for fast failover.",
                         transform: { list in guest.map { id in list.filter { $0.int("guest") == id } } ?? list }) { row in
                Button("Run Now") {
                    let node = session.guest(Int(row["guest"] ?? "") ?? 0)?.node ?? row["source"] ?? ""
                    Task { await session.run("Run replication \(row.id)", .post, "/nodes/\(node.enc)/replication/\(row.id.enc)/schedule_now") }
                }
                Button(row.json.bool("disable") ? "Enable" : "Disable") {
                    Task { await session.run("Change the replication job", .put, "/cluster/replication/\(row.id.enc)", ["disable": row.json.bool("disable") ? "0" : "1"]) }
                }
            } delete: { row in
                Deletion { session.confirmDelete("Delete replication job \(row.id)?", path: "/cluster/replication/\(row.id.enc)") }
            }
        }
        .task(id: session.revision) { await loadStatus() }
        .sheet(isPresented: $adding) {
            let guests = session.guests.filter { !$0.isTemplate && (guest == nil || $0.vmid == guest) }
            FormSheet(title: "Add replication job", fields: [
                FormField(key: "guest", label: "Guest", kind: .choice(guests.map { FormField.Choice(String($0.vmid), "\($0.vmid) \($0.displayName)") }), required: true),
                FormField(key: "target", label: "Target node", kind: .choice(session.onlineNodes.map { FormField.Choice($0) }), required: true),
                FormField(key: "schedule", label: "Schedule", kind: .suggested(Choices.schedules), prompt: "*/15 (every 15 minutes)"),
                FormField(key: "rate", label: "Rate limit (MB/s)", kind: .number, prompt: "Unlimited"),
                FormField(key: "comment", label: "Comment"),
            ], initial: ["guest": guest.map(String.init) ?? guests.first.map { String($0.vmid) } ?? "", "schedule": "*/15"], submitTitle: "Add") { result in
                let existing = (try? await session.client.list("/cluster/replication")) ?? []
                let used = Set(existing.filter { $0.string("guest") == result["guest"] }.compactMap { $0.int("jobnum") })
                let number = (0...9).first { !used.contains($0) } ?? 0
                var params = result.changed
                params["id"] = "\(result["guest"])-\(number)"
                params["type"] = "local"
                params.removeValue(forKey: "guest")
                return await session.run("Add the replication job", .post, "/cluster/replication", params)
            }
        }
    }

    private func loadStatus() async {
        var result: [String: JSONObject] = [:]
        for node in session.onlineNodes {
            for entry in (try? await session.client.list("/nodes/\(node.enc)/replication")) ?? [] {
                if let id = entry.string("id") { result[id] = entry }
            }
        }
        status = result
    }
}

// MARK: High availability

struct HAView: View {
    @Environment(Session.self) private var session
    @State private var section = "status"
    @State private var editing: Row??
    @State private var migrating: Row?
    /// "armed" or "disarmed" (PVE 9.1+), from the status's fencing entry; nil on older servers.
    @State private var armedState: String?

    var body: some View {
        AdminPage(title: "High Availability", subtitle: "Restart or move guests automatically when a node fails", symbol: "heart.text.square", colors: [.pink, .red]) {
            Button("Add Resource", systemImage: "plus") { editing = .some(nil) }
        } content: {
            TabStrip(tabs: [PageTab(id: "status", title: "Status", symbol: "waveform.path.ecg"),
                            PageTab(id: "resources", title: "Resources", symbol: "square.stack.3d.up"),
                            PageTab(id: "rules", title: "Rules & Groups", symbol: "list.bullet.indent")], selection: $section)
                .padding(.bottom, 6)
            switch section {
            case "resources":
                ResourceList(path: "/cluster/ha/resources", id: { $0.string("sid") ?? "" },
                             columns: [APIColumn("Resource", key: "sid", width: 100, monospaced: true),
                                       APIColumn("Name", width: 180) { [session] in session.guest(Int(($0.string("sid") ?? "").split(separator: ":").last ?? "") ?? 0)?.displayName ?? "" },
                                       APIColumn("State", key: "state", width: 90), APIColumn("Group", key: "group", width: 110),
                                       APIColumn("Max restart", key: "max_restart", width: 90), APIColumn("Max relocate", key: "max_relocate", width: 100),
                                       APIColumn("Comment", key: "comment", width: 220)],
                             emptyTitle: "No HA resources", emptySymbol: "heart.text.square",
                             emptyMessage: "Add a guest so the cluster restarts it elsewhere if its node goes down.", open: { editing = .some($0) }) { row in
                    Button("Edit…") { editing = .some(row) }
                    Button("Migrate…") { migrating = row }
                } delete: { row in
                    Deletion(title: "Remove…") { session.confirmDelete("Remove \(row.id) from HA?", message: "The guest keeps running; it just isn't managed anymore.", path: "/cluster/ha/resources/\(row.id.enc)") }
                }
            case "rules":
                HARulesSection()
            default:
                if let armedState {
                    HStack {
                        if armedState == "disarmed" {
                            Button("Arm HA", systemImage: "link") { arm() }
                            Text("HA is disarmed: failed guests aren't recovered until you arm it again.").font(.callout).foregroundStyle(.orange)
                        } else {
                            Menu("Disarm HA", systemImage: "link.badge.plus") {
                                Button("Freeze", systemImage: "snowflake") { disarm(mode: "freeze") }
                                Button("Ignore", systemImage: "eye.slash") { disarm(mode: "ignore") }
                            }
                            .fixedSize()
                            Text("Disarm before maintenance that would otherwise make HA fence nodes.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .buttonStyle(.glass)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }
                ResourceList(path: "/cluster/ha/status/current", id: { $0.string("id") ?? UUID().uuidString },
                             columns: [APIColumn("Type", width: 80) { ["lrm": "LRM", "crm": "CRM"][$0.string("type") ?? ""] ?? ($0.string("type") ?? "").capitalized },
                                       APIColumn("Status", key: "status", width: 420), APIColumn("Node", key: "node", width: 100)],
                             emptyTitle: "HA isn't active", emptySymbol: "heart.slash") { _ in EmptyView() }
            }
        }
        .task(id: session.revision) {
            let status = (try? await session.client.list("/cluster/ha/status/current")) ?? []
            armedState = status.first { $0.string("type") == "fencing" }?.text("armed-state")
        }
        .sheet(item: Binding(get: { editing.map { SimpleEdit(row: $0) } }, set: { editing = $0.map(\.row) })) { edit in
            let guests = session.guests.filter { !$0.isTemplate }
            FormSheet(title: edit.row == nil ? "Add HA resource" : "Edit \(edit.row!.id)", fields: [
                FormField(key: "sid", label: "Guest", kind: .choice(guests.map { FormField.Choice("\($0.kind == .qemu ? "vm" : "ct"):\($0.vmid)", "\($0.vmid) \($0.displayName)") }),
                          required: true, lockedOnEdit: true),
                FormField(key: "state", label: "Requested state", kind: .choice([.init("started", "Started"), .init("stopped", "Stopped"), .init("disabled", "Disabled"), .init("ignored", "Ignored")]), required: true),
                FormField(key: "max_restart", label: "Max restarts", kind: .number, prompt: "1"),
                FormField(key: "max_relocate", label: "Max relocations", kind: .number, prompt: "1"),
                FormField(key: "group", label: "Group (PVE 8)"),
                FormField(key: "comment", label: "Comment"),
            ], initial: edit.row.map { row in ["sid": row.id, "state": row["state"] ?? "started", "max_restart": row["max_restart"] ?? "",
                                                "max_relocate": row["max_relocate"] ?? "", "group": row["group"] ?? "", "comment": row["comment"] ?? ""] }
                ?? ["state": "started", "max_restart": "1", "max_relocate": "1"],
                      isEdit: edit.row != nil) { result in
                if let row = edit.row { return await session.run("Save \(row.id)", .put, "/cluster/ha/resources/\(row.id.enc)", result.params) }
                return await session.run("Add \(result["sid"]) to HA", .post, "/cluster/ha/resources", result.changed)
            }
        }
        .sheet(item: $migrating) { row in
            FormSheet(title: "Migrate \(row.id)", message: "HA moves the guest (live, for running VMs).",
                      fields: [FormField(key: "node", label: "Target node", kind: .choice(session.onlineNodes.map { FormField.Choice($0) }), required: true)],
                      initial: ["node": session.onlineNodes.first ?? ""], submitTitle: "Migrate") { result in
                await session.run("Migrate \(row.id)", .post, "/cluster/ha/resources/\(row.id.enc)/migrate", ["node": result["node"]])
            }
        }
    }

    /// Like the web UI: freeze keeps every guest in its current state; ignore lets guests change without HA reacting.
    private func disarm(mode: String) {
        let details = mode == "freeze" ? "Every guest is frozen: HA allows no change to its operational state."
                                       : "HA is bypassed entirely when a guest's operational state changes."
        session.confirmation = Confirmation(title: "Disarm HA (\(mode == "freeze" ? "Freeze" : "Ignore"))?",
                                            message: "\(details) While disarmed, HA doesn't protect your guests: failures aren't recovered automatically.",
                                            actionTitle: "Disarm", destructive: true) {
            await session.run("Disarm HA", .post, "/cluster/ha/status/disarm-ha", ["resource-mode": mode])
        }
    }

    private func arm() {
        session.confirmation = Confirmation(title: "Arm HA again?", message: "HA resumes protecting your guests and recovers failures automatically.",
                                            actionTitle: "Arm", destructive: false) {
            await session.run("Arm HA", .post, "/cluster/ha/status/arm-ha")
        }
    }
}

/// What a backup job covers: its settings, and every guest with the disks that go into the backup (and why others don't),
/// like the web UI's Job Detail window.
struct BackupJobDetailSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let job: Row

    private struct Line: Identifiable {
        let id: Int
        let guest: Bool
        let json: JSONObject
    }

    var body: some View {
        Prepared(load: { () -> [Line]? in
            guard let tree = try? await session.client.object("/cluster/backup/\(job.id.enc)/included_volumes") else { return nil }
            var lines: [Line] = []
            for guest in tree.objects("children") {
                lines.append(Line(id: lines.count, guest: true, json: guest))
                for volume in guest.objects("children") { lines.append(Line(id: lines.count, guest: false, json: volume)) }
            }
            return lines
        }) { lines in
            VStack(alignment: .leading, spacing: 14) {
                Text("Backup job \(job.id)").font(.title2.bold())
                let json = job.json
                InfoGrid(rows: [
                    ("Schedule", json.string("schedule") ?? ""),
                    ("Next run", Format.epoch(json.int("next-run")).map(Format.dateTime) ?? "–"),
                    ("Node", json.string("node") ?? "All"),
                    ("Storage", json.string("storage") ?? ""),
                    ("Mode", (json.string("mode") ?? "snapshot").capitalized),
                    ("Compression", json.string("compress") ?? "zstd"),
                    ("Keep", (json.string("prune-backups") ?? "From the storage").replacingOccurrences(of: "keep-", with: "").replacingOccurrences(of: "=", with: " ").replacingOccurrences(of: ",", with: ", ")),
                ])
                if let lines {
                    Table(lines) {
                        TableColumn("Guest / disk") { line in
                            if line.guest {
                                Label("\(line.json.string("id") ?? "") \(line.json.string("name") ?? "")",
                                      systemImage: line.json.string("type") == "lxc" ? "shippingbox" : "desktopcomputer")
                                    .fontWeight(.medium)
                            } else {
                                Text("\(line.json.string("id") ?? "")  \(Text(line.json.string("name") ?? "").foregroundStyle(.secondary))")
                                    .lineLimit(1).truncationMode(.middle).padding(.leading, 26)
                            }
                        }
                        .width(min: 260, ideal: 380)
                        TableColumn("Included") { line in
                            if !line.guest {
                                Image(systemName: line.json.bool("included") ? "checkmark.circle.fill" : "minus.circle")
                                    .foregroundStyle(line.json.bool("included") ? .green : .secondary)
                            }
                        }
                        .width(70)
                        TableColumn("Why") { line in
                            Text(line.guest ? "" : Self.reason(line.json.string("reason") ?? "")).foregroundStyle(.secondary)
                        }
                    }
                    .overlay { if lines.isEmpty { ContentUnavailableView("No guests", systemImage: "square.stack.3d.up.slash") } }
                } else {
                    ContentUnavailableView("Couldn't read the job", systemImage: "exclamationmark.triangle")
                }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
            .controlSize(.large)
            .padding(24)
            .frame(width: 720, height: 560)
        }
    }

    /// Proxmox's reasons in plain words.
    static func reason(_ reason: String) -> String {
        ["default": "Included by default", "enabled": "Backup turned on for this disk", "disabled": "Backup turned off for this disk",
         "efidisk but no OMVF BIOS": "EFI disk, but the VM doesn't boot with UEFI"][reason] ?? reason
    }
}
