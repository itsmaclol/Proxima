import SwiftUI
import UniformTypeIdentifiers

/// A storage on one node: usage, its content by type, and permissions.
struct StorageView: View {
    @Environment(Session.self) private var session
    let node: String
    let storage: String
    @State private var info: StorageInfo?

    private var path: String { "/nodes/\(node.enc)/storage/\(storage.enc)" }

    var body: some View {
        @Bindable var session = session
        let resource = session.storage(storage, on: node)
        let contents = (info?.content ?? resource?.content ?? []).compactMap(ContentType.init(rawValue:))
        let tabs = [PageTab(id: "summary", title: "Summary", symbol: "gauge.with.dots.needle.33percent")]
            + contents.map { PageTab(id: $0.rawValue, title: $0.label, symbol: $0.symbol) }
            + [PageTab(id: "permissions", title: "Permissions", symbol: "person.2")]
        let fraction = info?.fraction ?? resource?.diskFraction ?? 0
        VStack(spacing: 0) {
            let type = resource?.plugin ?? info?.type
            Hero(title: storage, subtitle: "\(StorageConfigView.types.first { $0.id == type }?.name ?? type ?? "Storage") on \(node)\(resource?.shared == true ? ", shared" : "")",
                 symbol: resource?.shared == true ? "externaldrive.connected.to.line.below" : "externaldrive",
                 colors: resource?.status == "available" ? [.teal, .mint] : [.red, .orange]) {
                Pill(text: resource?.status == "available" ? "Available" : (resource?.status.capitalized ?? "Unknown"),
                     systemImage: resource?.status == "available" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                     color: resource?.status == "available" ? .green : .orange)
                Pill(text: "\(Format.bytes(info?.used ?? resource?.disk ?? 0)) of \(Format.bytes(info?.total ?? resource?.maxdisk ?? 0)) used", systemImage: "chart.pie")
            } trailing: {
                VStack(spacing: 4) {
                    MetricRing(fraction: fraction, color: Theme.disk, lineWidth: 6).frame(width: 58, height: 58)
                    Text("Used").font(.caption).foregroundStyle(.secondary)
                }
            }
            TabStrip(tabs: tabs, selection: $session.storageTab)
                .padding(.bottom, 6)
            Group {
                let tab = tabs.contains { $0.id == session.storageTab } ? session.storageTab : "summary"
                switch tab {
                case "summary": StorageSummary(node: node, storage: storage, info: info)
                case "permissions": PermissionsList(path: "/storage/\(storage)")
                default: StorageContent(node: node, storage: storage, content: ContentType(rawValue: tab) ?? .iso).id(tab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: "\(node)-\(storage)-\(session.revision)") {
            if let object = try? await session.client.object(path + "/status") { info = StorageInfo(object.merging(["storage": storage]) { a, _ in a }) }
        }
    }
}

private struct StorageSummary: View {
    @Environment(Session.self) private var session
    let node: String
    let storage: String
    let info: StorageInfo?
    @AppStorage("storage.timeframe") private var timeframe = Timeframe.day
    @State private var samples: [RRDPoint] = []

    var body: some View {
        Page {
            Card(title: "Details", systemImage: "info.circle") {
                InfoGrid(rows: [("Type", info?.type ?? "–"), ("Content", info?.content.compactMap { ContentType(rawValue: $0)?.label }.joined(separator: ", ") ?? "–"),
                                ("Used", Format.bytes(info?.used ?? 0)), ("Available", Format.bytes(info?.available ?? 0)),
                                ("Total", Format.bytes(info?.total ?? 0)), ("Shared", info?.shared == true ? "Yes" : "No"),
                                ("Enabled", info?.enabled == false ? "No" : "Yes"), ("Active", info?.active == true ? "Yes" : "No")])
            }
            HStack {
                Text("Usage over time").font(.title3.weight(.semibold))
                Spacer()
                Picker("Timeframe", selection: $timeframe) { ForEach(Timeframe.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            }
            MetricChart(title: "Usage", series: [ChartSeries("Used", color: Theme.disk, from: samples) { $0["used"] }],
                        unit: .bytes, ceiling: samples.compactMap { $0["total"] }.max(), timeframe: timeframe)
        }
        .task(id: "\(storage)-\(timeframe)") {
            if let list = try? await session.client.list("/nodes/\(node.enc)/storage/\(storage.enc)/rrddata", ["timeframe": timeframe.rawValue, "cf": "AVERAGE"]) {
                samples = list.map(RRDPoint.init)
            }
        }
    }
}

/// One content type of a storage, with the actions that make sense for it.
private struct StorageContent: View {
    @Environment(Session.self) private var session
    let node: String
    let storage: String
    let content: ContentType

    @State private var volumes: [Volume] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var selection: Volume.ID?
    @State private var importing = false
    @State private var downloading = false
    @State private var browsingTemplates = false
    @State private var pullingOCI = false
    @State private var restoring: BackupVolume?
    @State private var editingNotes: BackupVolume?
    @State private var showingConfig: BackupVolume?
    @State private var importingGuest: Volume?
    @State private var uploadProgress: Double?

    private var path: String { "/nodes/\(node.enc)/storage/\(storage.enc)" }
    /// ESXi guests (.vmx) and appliances (.ova, .ovf) that the import wizard can turn into VMs.
    private static let importable = ["vmx", "ova", "ovf"]

    var body: some View {
        let selected = volumes.first { $0.id == selection }
        let selectedBackup = selected.map { BackupVolume(storage: storage, volume: $0) }
        // An ESXi storage is a read-only view of the host's guests.
        let readOnly = session.storage(storage, on: node)?.plugin == "esxi"
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Proxmox accepts uploads of ISO images, container templates and import files only.
                if [.iso, .vztmpl, .import].contains(content), !readOnly {
                    Button("Upload", systemImage: "square.and.arrow.up") { importing = true }
                        .buttonStyle(.glassProminent)
                        .disabled(uploadProgress != nil)
                }
                if [.iso, .vztmpl, .import].contains(content), !readOnly {
                    Button("Download from URL", systemImage: "arrow.down.circle") { downloading = true }
                }
                if content == .vztmpl {
                    Button("Templates", systemImage: "square.grid.2x2") { browsingTemplates = true }
                    Button("OCI Image", systemImage: "shippingbox") { pullingOCI = true }
                        .help("Pull a container image from Docker Hub or another OCI registry, to create application containers")
                }
                if content == .import {
                    Button("Import Guest", systemImage: "square.and.arrow.down.on.square") { importingGuest = selected }
                        .disabled(!Self.importable.contains(selected?.format ?? ""))
                        .help("Create a VM from an ESXi guest or an OVA/OVF appliance")
                }
                if content == .backup {
                    Button("Restore", systemImage: "arrow.uturn.backward") { restoring = selectedBackup }.disabled(selected == nil)
                    BackupActions(node: node, selected: selectedBackup, editingNotes: $editingNotes, showingConfig: $showingConfig)
                } else if !readOnly {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        guard let selected else { return }
                        session.confirmDelete("Delete \(selected.fileName)?", message: "The file is removed from \(storage).",
                                              path: "\(path)/content/\(selected.volid.enc)")
                    }
                    .disabled(selected == nil)
                }
                Spacer()
                if let uploadProgress {
                    ProgressView(value: uploadProgress) { Text("Uploading…").font(.caption) }.frame(width: 180)
                }
                Text("\(volumes.count) item\(volumes.count == 1 ? "" : "s"), \(Format.bytes(volumes.reduce(0) { $0 + $1.size }))").foregroundStyle(.secondary)
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            Loadable(loading: !loaded, error: error, isEmpty: volumes.isEmpty, emptyTitle: content.emptyTitle, emptySymbol: content.symbol,
                     emptyMessage: emptyMessage) {
                if content == .backup {
                    BackupTable(backups: volumes.map { BackupVolume(storage: storage, volume: $0) }, selection: $selection)
                } else {
                    Table(volumes, selection: $selection) {
                        TableColumn("Name") { volume in Label(volume.fileName, systemImage: content.symbol).lineLimit(1).truncationMode(.middle) }
                            .width(min: 200, ideal: 340)
                        TableColumn("Format") { volume in Text(volume.format).foregroundStyle(.secondary) }.width(min: 50, ideal: 70)
                        TableColumn("Size") { volume in Text(Format.bytes(volume.size)).monospacedDigit() }.width(min: 60, ideal: 90)
                        if content == .images || content == .rootdir {
                            TableColumn("Guest") { volume in
                                Text(verbatim: volume.vmid.map { session.guest($0).map { "\($0.vmid) \($0.displayName)" } ?? "\($0) (gone)" } ?? "–")
                                    .foregroundStyle(volume.vmid.flatMap { session.guest($0) } == nil ? .orange : .secondary)
                            }
                            .width(min: 100, ideal: 180)
                        }
                        TableColumn("Date") { volume in Text(volume.date.map(Format.dateTime) ?? "").foregroundStyle(.secondary) }.width(min: 100, ideal: 150)
                    }
                }
            }
        }
        .task(id: "\(storage)-\(content.rawValue)-\(session.revision)") { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: allowedTypes) { result in
            if case .success(let url) = result { upload(url) }
        }
        .sheet(isPresented: $downloading) { DownloadURLSheet(node: node, storage: storage, content: content) }
        .sheet(isPresented: $browsingTemplates) { TemplateCatalog(node: node, storage: storage) }
        .sheet(isPresented: $pullingOCI) { OCIPullSheet(node: node, storage: storage) }
        .debugAction("pull-oci") { pullingOCI = true }
        .sheet(item: $restoring) { backup in RestoreSheet(node: node, backup: backup) }
        .sheet(item: $importingGuest) { ImportGuestSheet(node: node, storage: storage, volume: $0) }
        .debugAction("import-guest") {
            Task {
                await load()
                importingGuest = volumes.first { Self.importable.contains($0.format) }
            }
        }
        .sheet(item: $editingNotes) { backup in BackupNotesSheet(node: node, backup: backup) }
        .sheet(item: $showingConfig) { backup in BackupConfigSheet(node: node, backup: backup) }
    }

    private var emptyMessage: String {
        switch content {
        case .iso: "Upload an installer ISO or download one straight to the server from a URL."
        case .vztmpl: "Download a ready-made container template from the Templates catalog."
        case .backup: "Backups made to this storage show up here."
        case .snippets: "Hook scripts and Cloud-Init files go in this storage's snippets folder on the node. Proxmox doesn't take uploads for them, so copy them over SSH."
        case .import: "Upload an OVA or OVF appliance to turn it into a VM."
        case .images, .rootdir: "Disks of guests on this storage show up here."
        }
    }

    private var allowedTypes: [UTType] {
        switch content {
        case .iso: [UTType(filenameExtension: "iso") ?? .diskImage, UTType(filenameExtension: "img") ?? .diskImage]
        case .vztmpl: [.gzip, UTType(filenameExtension: "zst") ?? .data, UTType(filenameExtension: "xz") ?? .data, .archive]
        default: [.data]
        }
    }

    private func load() async {
        do {
            volumes = try await session.client.list("\(path)/content", ["content": content.rawValue]).map(Volume.init)
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func upload(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        uploadProgress = 0
        Task {
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                uploadProgress = nil
            }
            do {
                let result = try await session.client.upload("\(path)/upload", fields: ["content": content.rawValue], file: url) { uploadProgress = $0 }
                if let upid = result as? String { session.track(upid, title: "Upload \(url.lastPathComponent)") } else { session.changed() }
            } catch {
                session.report(error, doing: "Upload \(url.lastPathComponent)")
            }
        }
    }
}

private struct DownloadURLSheet: View {
    @Environment(Session.self) private var session
    let node: String
    let storage: String
    let content: ContentType

    var body: some View {
        FormSheet(title: "Download to \(storage)", message: "The server downloads the file itself — nothing goes through your Mac.", fields: [
            FormField(key: "url", label: "URL", prompt: "https://cdimage.debian.org/…/debian-13-amd64-netinst.iso", required: true),
            FormField(key: "filename", label: "File name", prompt: "Taken from the URL"),
            FormField(key: "checksum-algorithm", label: "Checksum type", kind: .choice(["sha256", "sha512", "sha1", "md5"].map { .init($0) })),
            FormField(key: "checksum", label: "Checksum", prompt: "Optional, verifies the download"),
            FormField(key: "verify-certificates", label: "Verify TLS certificates", kind: .toggle),
        ], initial: ["verify-certificates": "1"], submitTitle: "Download") { result in
            var params = result.changed
            params["content"] = content.rawValue
            if (params["filename"] ?? "").isEmpty {
                let metadata = try? await session.client.object("/nodes/\(node.enc)/query-url-metadata", ["url": result["url"]])
                params["filename"] = metadata?.text("filename") ?? URL(string: result["url"])?.lastPathComponent ?? "download"
            }
            if params["checksum"] == nil { params["checksum-algorithm"] = nil }
            return await session.run("Download \(params["filename"] ?? "")", .post, "/nodes/\(node.enc)/storage/\(storage.enc)/download-url", params)
        }
    }
}

/// Pulls an OCI image (Docker Hub, GitHub, any registry) into the storage, for application containers (PVE 9.1+).
struct OCIPullSheet: View {
    @Environment(Session.self) private var session
    let node: String
    let storage: String

    var body: some View {
        FormSheet(title: "Pull OCI image", message: "The server pulls the image itself. Containers made from it run its application directly.", fields: [
            FormField(key: "reference", label: "Image", prompt: "docker.io/library/nginx", help: "Docker Hub images can be short, like nginx", required: true),
            FormField(key: "tag", label: "Tag", kind: .lookup { values in
                let image = Self.split(values["reference"] ?? "").image
                guard !image.isEmpty else { throw LookupNeeds(message: "Enter the image first.") }
                return try await session.client.get("/nodes/\(node.enc)/query-oci-repo-tags", ["reference": image])
                    .flatMap { $0 as? [Any] }?.compactMap { $0 as? String }.prefix(300).map { FormField.Choice($0) } ?? []
            }, prompt: "latest"),
            FormField(key: "filename", label: "File name", prompt: "image_tag"),
        ], submitTitle: "Pull") { result in
            // "nginx:1.29" in the image field carries its tag; the Tag field wins when both are given.
            let parts = Self.split(result["reference"])
            let tag = result["tag"].isEmpty ? (parts.tag ?? "latest") : result["tag"]
            var params = ["reference": "\(parts.image):\(tag)"]
            if !result["filename"].isEmpty { params["filename"] = result["filename"] }
            return await session.run("Pull \(parts.image):\(tag)", .post, "/nodes/\(node.enc)/storage/\(storage.enc)/oci-registry-pull", params)
        }
    }

    /// A tag follows the last colon after the last slash: "registry:5000/app:1.2" is image "registry:5000/app", tag "1.2".
    static func split(_ reference: String) -> (image: String, tag: String?) {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":"), trimmed.lastIndex(of: "/").map({ $0 < colon }) ?? true else { return (trimmed, nil) }
        return (String(trimmed[..<colon]), String(trimmed[trimmed.index(after: colon)...]))
    }
}

/// The Proxmox appliance catalog of container templates.
private struct TemplateCatalog: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let node: String
    let storage: String
    @State private var templates: [Row] = []
    @State private var selection: Row.ID?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Container templates").font(.title2.bold())
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            let shown = search.isEmpty ? templates : templates.filter { ($0["headline"] ?? "").localizedCaseInsensitiveContains(search) || ($0["package"] ?? "").localizedCaseInsensitiveContains(search) }
            Table(shown, selection: $selection) {
                TableColumn("Section") { row in Text(row["section"] ?? "").foregroundStyle(.secondary) }.width(90)
                TableColumn("Template") { row in Text(row["headline"] ?? row["package"] ?? "") }.width(min: 160, ideal: 240)
                TableColumn("Version") { row in Text(row["version"] ?? "").fontDesign(.monospaced) }.width(90)
                TableColumn("Description") { row in Text(row["description"] ?? "").foregroundStyle(.secondary).lineLimit(1) }.width(min: 160, ideal: 260)
            }
            HStack {
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                Button("Download") {
                    guard let row = templates.first(where: { $0.id == selection }) else { return }
                    Task {
                        if await session.run("Download \(row["headline"] ?? row.id)", .post, "/nodes/\(node.enc)/aplinfo", ["storage": storage, "template": row.id]) { dismiss() }
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 820, height: 540)
        .task {
            templates = ((try? await session.client.list("/nodes/\(node.enc)/aplinfo")) ?? [])
                .map { Row(id: $0.string("template") ?? UUID().uuidString, json: $0) }
                .sorted { ($0["section"] ?? "", $0["package"] ?? "") < ($1["section"] ?? "", $1["package"] ?? "") }
        }
    }
}

/// Restore a backup into a new or existing guest.
private struct RestoreSheet: View {
    @Environment(Session.self) private var session
    let node: String
    let backup: BackupVolume

    var body: some View {
        let isVM = backup.volume.subtype == "qemu" || backup.volume.volid.contains("vzdump-qemu")
        Prepared(load: {
            let next = (try? await session.client.get("/cluster/nextid")).flatMap { jsonInt($0) } ?? 100
            return (next, await session.storageChoices(on: node, content: isVM ? "images" : "rootdir"))
        }) { loaded in
            let (next, storages) = loaded
            let original = backup.volume.vmid
            FormSheet(title: "Restore \(isVM ? "VM" : "container")", message: "From \(backup.volume.fileName). Restoring onto an existing ID replaces that guest.", fields: [
                FormField(key: "vmid", label: "ID", kind: .number, required: true),
                FormField(key: "storage", label: "Target storage", kind: .choice(storages), help: "Empty keeps the storage named in the backup"),
                FormField(key: "unique", label: "New MAC addresses and UUIDs", kind: .toggle),
                FormField(key: "force", label: "Overwrite the existing guest", kind: .toggle),
                FormField(key: "start", label: "Start after restoring", kind: .toggle),
            ], initial: ["vmid": String(original.flatMap { session.guest($0) == nil ? $0 : nil } ?? next), "unique": "1"], submitTitle: "Restore") { result in
                var params = ["vmid": result["vmid"]]
                if isVM { params["archive"] = backup.volume.volid } else { params["ostemplate"] = backup.volume.volid; params["restore"] = "1" }
                for key in ["storage"] where !result[key].isEmpty { params[key] = result[key] }
                for key in ["unique", "force", "start"] where result[key] == "1" { params[key] = "1" }
                return await session.run("Restore \(result["vmid"])", .post, "/nodes/\(node.enc)/\(isVM ? "qemu" : "lxc")", params)
            }
        }
    }
}
