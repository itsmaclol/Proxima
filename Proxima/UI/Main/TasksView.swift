import AppKit
import SwiftUI

/// Datacenter → Tasks: the cluster task log, newest first.
struct TasksView: View {
    @Environment(Session.self) private var session
    @State private var filter = Filter.all
    @State private var opened: TaskEntry?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", running = "Running", failed = "Failed"
        var id: String { rawValue }
    }

    var body: some View {
        let tasks = session.clusterTasks.filter { task in
            switch filter {
            case .all: true
            case .running: task.isRunning
            case .failed: !task.isRunning && !task.succeeded && !task.hasWarnings
            }
        }
        VStack(spacing: 0) {
            Hero(title: "Tasks", subtitle: "Everything Proxmox has done recently, across all nodes",
                 symbol: "list.bullet.rectangle.portrait", colors: [.blue, .indigo]) {
                Pill(text: "\(session.runningTaskCount) running", systemImage: "gearshape.2", color: session.runningTaskCount > 0 ? .blue : .secondary)
            }
            TaskTable(tasks: tasks, showNode: true) { opened = $0 }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .sheet(item: $opened) { task in
            TaskLogSheet(upid: task.upid, node: task.node, title: task.title).environment(session)
        }
    }
}

/// The task table shared by the datacenter, node and guest pages.
struct TaskTable: View {
    let tasks: [TaskEntry]
    var showNode = false
    let open: (TaskEntry) -> Void
    @State private var selection: TaskEntry.ID?

    var body: some View {
        Table(tasks, selection: $selection) {
            TableColumn("") { task in TaskStatusIcon(task: task) }
                .width(22)
            TableColumn("Started") { task in
                Text(task.start, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 150, ideal: 175)
            TableColumn("Task") { task in Text(task.title).lineLimit(1) }
                .width(min: 180, ideal: 260)
            if showNode {
                TableColumn("Node") { task in Text(task.node).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 90)
            }
            TableColumn("User") { task in Text(task.user).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 80, ideal: 120)
            TableColumn("Duration") { task in
                // Proxmox logs whole seconds, so a quick task ends in the second it started; "–" read as unknown.
                Text(task.isRunning ? "Running" : task.duration < 1 ? "<1s" : Format.duration(Int(task.duration.rounded())))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Status") { task in
                Text(task.isRunning ? "" : (task.succeeded ? "OK" : (task.status ?? "")))
                    .foregroundStyle(task.succeeded || task.isRunning ? Color.secondary : (task.hasWarnings ? .orange : .red))
                    .lineLimit(1)
                    .help(task.status ?? "")
            }
            .width(min: 80, ideal: 220)
        }
        .contextMenu(forSelectionType: TaskEntry.ID.self) { ids in
            if let id = ids.first, let task = tasks.first(where: { $0.id == id }) {
                Button("Show Log") { open(task) }
                Button("Copy Task ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(task.upid, forType: .string)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let task = tasks.first(where: { $0.id == id }) { open(task) }
        }
        .overlay {
            if tasks.isEmpty {
                ContentUnavailableView("No tasks", systemImage: "checkmark.circle", description: Text("Nothing matches this filter."))
            }
        }
    }
}

struct TaskStatusIcon: View {
    let task: TaskEntry

    var body: some View {
        Group {
            if task.isRunning {
                ProgressView().controlSize(.mini)
            } else if task.succeeded {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if task.hasWarnings {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .accessibilityLabel(task.isRunning ? "Running" : (task.succeeded ? "Succeeded" : "Failed"))
    }
}

/// Task history for one node, optionally narrowed to one guest.
struct TaskHistory: View {
    @Environment(Session.self) private var session
    let node: String
    var vmid: Int?
    @State private var tasks: [TaskEntry] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var opened: TaskEntry?
    @State private var errorsOnly = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Errors only", isOn: $errorsOnly).toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            Loadable(loading: !loaded, error: error, isEmpty: tasks.isEmpty, emptyTitle: "No tasks yet", emptySymbol: "list.bullet.rectangle") {
                TaskTable(tasks: tasks) { opened = $0 }
            }
        }
        .polling(id: "\(session.revision)-\(errorsOnly)", every: .seconds(5)) { await load() }
        .sheet(item: $opened) { task in
            TaskLogSheet(upid: task.upid, node: task.node, title: task.title).environment(session)
        }
    }

    private func load() async {
        var query = ["limit": "200", "source": "all"]
        if let vmid { query["vmid"] = String(vmid) }
        if errorsOnly { query["errors"] = "1" }
        do {
            // Newest first, like the cluster task list, whatever order the server sends.
            tasks = try await session.client.list("/nodes/\(node.enc)/tasks", query).map(TaskEntry.init).sorted { $0.start > $1.start }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// A task's live log, refreshed every second while it runs.
struct TaskLogSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let upid: String
    let node: String
    let title: String

    @State private var lines: [String] = []
    @State private var status: JSONObject = [:]
    @State private var error: String?

    private var running: Bool { status.string("status") != "stopped" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.bold())
                    Text("\(node) · \(status.string("user") ?? UPID(upid)?.user ?? "") · started \(Format.dateTime(UPID(upid)?.start ?? .now))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if running {
                    Label("Running", systemImage: "gearshape.2").foregroundStyle(.blue)
                } else if let exit = status.string("exitstatus") {
                    Label(exit == "OK" ? "Finished" : exit, systemImage: exit == "OK" ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(exit == "OK" ? .green : .red)
                        .lineLimit(2)
                }
            }
            .padding(20)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("TASK ERROR") ? .red : (line.hasPrefix("TASK OK") ? .green : .primary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(16)
                }
                .background(Color.primary.opacity(0.03))
                .onChange(of: lines.count) { _, count in
                    if running { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            if let error { ErrorBanner(message: error).padding(12) }
            Divider()
            HStack {
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                if running {
                    Button("Stop Task", role: .destructive) {
                        Task { await session.run("Stop the task", .delete, "/nodes/\(node.enc)/tasks/\(upid.enc)") }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 760, height: 520)
        .task {
            while !Task.isCancelled {
                await load()
                if !running { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func load() async {
        do {
            status = try await session.client.object("/nodes/\(node.enc)/tasks/\(upid.enc)/status")
            let log = try await session.client.list("/nodes/\(node.enc)/tasks/\(upid.enc)/log", ["start": "0", "limit": "5000"])
            lines = log.map { $0.string("t") ?? "" }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
