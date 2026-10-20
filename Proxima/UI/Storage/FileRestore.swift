import SwiftUI

/// Browses the files inside a Proxmox Backup Server backup and downloads a file, or a folder as a zip.
struct FileRestoreSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let node: String
    let backup: BackupVolume

    @State private var trail: [Entry] = []
    @State private var entries: [Entry] = []
    @State private var selection: Entry.ID?
    @State private var loading = false
    @State private var error: String?
    @State private var failure: String?
    @State private var downloading = false

    struct Entry: Identifiable, Hashable {
        /// Base64, as the API names paths inside a backup.
        let path: String
        let name: String
        let type: String
        let leaf: Bool
        let size: Int64?
        let modified: Date?
        var id: String { path }

        init(_ json: JSONObject) {
            path = json.string("filepath") ?? ""
            name = json.string("text") ?? ""
            type = json.string("type") ?? "f"
            leaf = jsonBool(json["leaf"])
            size = json["size"] == nil ? nil : json.int64("size")
            modified = Format.epoch(json.int("mtime"))
        }

        var symbol: String {
            switch type {
            case "v": "externaldrive"
            case "l": "arrow.turn.up.right"
            default: leaf ? "doc" : "folder"
            }
        }
    }

    private var subtitle: String {
        let guest = backup.volume.vmid.map { vmid in session.guest(vmid).map { "\($0.displayName) (\(vmid))" } ?? "guest \(vmid)" } ?? backup.volume.fileName
        return "Backup of \(guest)\(backup.volume.date.map { " from \(Format.dateTime($0))" } ?? "") on \(backup.storage)"
    }

    private var api: String { "/nodes/\(node.enc)/storage/\(backup.storage.enc)/file-restore" }
    private var selected: Entry? { entries.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Restore files").font(.title2.bold())
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 10)

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    crumb("Backup", depth: 0)
                    ForEach(Array(trail.enumerated()), id: \.offset) { index, entry in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        crumb(entry.name, depth: index + 1)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.never)
            .padding(.bottom, 8)

            Table(entries, selection: $selection) {
                TableColumn("Name") { entry in
                    Label(entry.name, systemImage: entry.symbol).lineLimit(1).truncationMode(.middle)
                }
                .width(min: 200, ideal: 380)
                TableColumn("Size") { entry in
                    Text(entry.size.map(Format.bytes) ?? "").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 90)
                TableColumn("Modified") { entry in
                    Text(entry.modified.map(Format.dateTime) ?? "").foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 160)
            }
            .contextMenu(forSelectionType: Entry.ID.self) { _ in
                EmptyView()
            } primaryAction: { ids in
                if let entry = entries.first(where: { ids.contains($0.id) }), !entry.leaf { trail.append(entry) }
            }
            .overlay {
                if loading {
                    // Opening a disk image boots a small restore VM on the node, which takes a while the first time.
                    ProgressView(trail.last?.type == "v" ? "Opening the disk…" : "Loading…").controlSize(.small)
                } else if let error {
                    ContentUnavailableView {
                        Label("Couldn't list the files", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else if entries.isEmpty {
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                }
            }

            HStack {
                Text(failure ?? "Double-click a folder to open it. Folders download as zip files.")
                    .font(.callout)
                    .foregroundStyle(failure == nil ? Color.secondary : .red)
                    .lineLimit(2)
                Spacer()
                if downloading { ProgressView().controlSize(.small) }
                Button("Close", role: .cancel) { dismiss() }
                Button(selected?.leaf == false ? "Download as Zip" : "Download") { Task { await download() } }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || downloading)
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 760, height: 560)
        .task(id: trail.last?.path ?? "root") {
            await load()
            #if DEBUG
            // Visual checks: PROXIMA_DEBUG_ACTION=restore-download downloads the first entry, which opens the save panel.
            if ProcessInfo.processInfo.environment["PROXIMA_DEBUG_ACTION"] == "restore-download", trail.isEmpty, let first = entries.first {
                selection = first.id
                await download()
            }
            #endif
        }
    }

    private func crumb(_ title: String, depth: Int) -> some View {
        Button(title) { trail = Array(trail.prefix(depth)) }
            .buttonStyle(.borderless)
            .fontWeight(depth == trail.count ? .semibold : .regular)
            .foregroundStyle(depth == trail.count ? .primary : .secondary)
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let list = try await session.client.list(api + "/list", ["volume": backup.volume.volid,
                                                                     "filepath": trail.last?.path ?? Data("/".utf8).base64EncodedString()])
            entries = list.map(Entry.init).sorted { ($0.leaf ? 1 : 0, $0.name.lowercased()) < ($1.leaf ? 1 : 0, $1.name.lowercased()) }
            selection = nil
        } catch {
            entries = []
            self.error = error.localizedDescription
        }
    }

    private func download() async {
        guard let entry = selected else { return }
        downloading = true
        failure = nil
        defer { downloading = false }
        let file: URL
        do {
            file = try await session.client.download(api + "/download", ["volume": backup.volume.volid, "filepath": entry.path, "tar": "0"],
                                                     name: entry.leaf ? entry.name : entry.name + ".zip")
        } catch {
            failure = "Couldn't download \(entry.name): \(error.localizedDescription)"
            return
        }
        // The download waits in its own temporary folder until it moves where the user picks.
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        // AppKit's panel rather than SwiftUI's fileExporter, which crashed preparing the file (NSFileWrapper on macOS 26).
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.canCreateDirectories = true
        let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        guard response == .OK, let target = panel.url else { return }
        do {
            // The panel has already asked before replacing an existing file.
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: file)
            } else {
                try FileManager.default.moveItem(at: file, to: target)
            }
        } catch {
            failure = "Couldn't save \(file.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
