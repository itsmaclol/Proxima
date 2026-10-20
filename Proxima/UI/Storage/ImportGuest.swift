import SwiftUI

/// Creates a VM from a guest on an ESXi host or an OVA/OVF file on an import storage, like the web UI's import wizard:
/// the source's own settings, adjusted here, with every disk copied to the storage you pick.
struct ImportGuestSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let node: String
    let storage: String
    let volume: Volume

    private struct Loaded {
        var meta: JSONObject = [:]
        var error: String?
        var storages: [FormField.Choice] = []
        var bridges: [FormField.Choice] = []
        var next = 100
    }

    var body: some View {
        Prepared(load: {
            var loaded = Loaded()
            do {
                loaded.meta = try await session.client.object("/nodes/\(node.enc)/storage/\(storage.enc)/import-metadata", ["volume": volume.volid])
            } catch {
                loaded.error = error.localizedDescription
            }
            loaded.storages = await session.storageChoices(on: node, content: "images")
            loaded.bridges = await session.bridgeChoices(on: node)
            loaded.next = (try? await session.client.get("/cluster/nextid")).flatMap { jsonInt($0) } ?? 100
            return loaded
        }) { loaded in
            if let error = loaded.error {
                VStack(spacing: 12) {
                    ContentUnavailableView("Couldn't read \(volume.fileName)", systemImage: "exclamationmark.triangle", description: Text(error))
                    Button("Close") { dismiss() }.controlSize(.large)
                }
                .padding(24)
                .frame(width: 520, height: 300)
            } else {
                let args = loaded.meta.object("create-args") ?? [:]
                let isOVA = loaded.meta.objects("warnings").contains { $0.string("type") == "ova-needs-extracting" }
                // Like the web UI: Windows guests on UEFI start out prepared for VirtIO SCSI.
                let windows = (args.string("ostype") ?? "").hasPrefix("w")
                FormSheet(title: "Import \(args.text("name") ?? volume.fileName)", message: Self.summary(loaded.meta), fields: fields(loaded, isOVA: isOVA, windows: windows), initial: [
                    "vmid": String(loaded.next), "name": args.string("name") ?? "", "sockets": args.string("sockets") ?? "", "cores": args.string("cores") ?? "",
                    "memory": args.string("memory") ?? "", "ostype": args.string("ostype") ?? "",
                    "storage": loaded.storages.first?.value ?? "", "bridge": loaded.bridges.first?.value ?? "",
                    "virtio-prep": windows && (args.string("bios") ?? "").contains("ovmf") ? "1" : "0",
                ], submitTitle: "Import") { result in
                    await session.run("Import \(result["name"].isEmpty ? volume.fileName : result["name"])", .post, "/nodes/\(node.enc)/qemu",
                                      Self.params(meta: loaded.meta, result: result))
                }
            }
        }
    }

    private func fields(_ loaded: Loaded, isOVA: Bool, windows: Bool) -> [FormField] {
        var fields = [
            FormField(key: "vmid", label: "VM ID", kind: .number, required: true),
            FormField(key: "name", label: "Name"),
            FormField(key: "sockets", label: "Sockets", kind: .number),
            FormField(key: "cores", label: "Cores", kind: .number),
            FormField(key: "memory", label: "Memory (MiB)", kind: .number),
            FormField(key: "ostype", label: "Guest OS", kind: .choice(Choices.ostypes)),
            FormField(key: "storage", label: "Default storage", kind: .choice(loaded.storages), required: true),
            FormField(key: "format", label: "Disk format", kind: .choice([.init("raw", "Raw"), .init("qcow2", "QEMU image (qcow2)"), .init("vmdk", "VMware image (vmdk)")]),
                      prompt: "Storage default"),
        ]
        // One row per source disk: its own storage, the default, or left behind.
        let disks = loaded.meta.object("disks") ?? [:]
        for key in disks.keys.sorted(using: KeyPathComparator(\.self, comparator: .localizedStandard)) where !key.hasPrefix("efidisk") {
            let size = (disks[key] as? JSONObject)?.int64("size") ?? 0
            fields.append(FormField(key: "storage:\(key)", label: size > 0 ? "\(key) (\(Format.bytes(size)))" : key,
                                    kind: .choice([FormField.Choice(Self.skip, "Don't import")] + loaded.storages), prompt: "Default storage"))
        }
        fields += [
            FormField(key: "bridge", label: "Network bridge", kind: .choice(loaded.bridges), required: true),
            FormField(key: "live-restore", label: "Start while importing (live import)", kind: .toggle,
                      help: "The VM boots right away and reads from the source until its disks are copied, so it's slow until then"),
        ]
        if windows {
            fields.append(FormField(key: "virtio-prep", label: "Prepare for VirtIO SCSI", kind: .toggle,
                                    help: "Attaches the SCSI disks as SATA so Windows boots without VirtIO drivers, and sets the controller to VirtIO SCSI for later"))
        }
        if isOVA {
            fields.append(FormField(key: "import-working-storage", label: "Unpack the OVA on", kind: .choice(loaded.storages), prompt: "The source storage"))
        }
        return fields
    }

    /// Which disks come over, and the source's warnings in plain words.
    static func summary(_ meta: JSONObject) -> String {
        let disks = (meta.object("disks") ?? [:]).keys.sorted()
        var lines = [disks.isEmpty ? "The source has no disks to copy." : "Copies \(disks.formatted(.list(type: .and))) to the storages you pick. Network cards keep their MAC addresses."]
        for warning in meta.objects("warnings") {
            switch warning.string("type") {
            case "ova-needs-extracting": lines.append("The OVA is unpacked first, which needs free space.")
            case "guest-is-running": lines.append("The guest is still running on the source. Shut it down first for a consistent copy.")
            case "nvme-unsupported": lines.append("NVMe disks aren't supported; \(warning.string("key") ?? "one disk") is attached as SCSI.")
            default: lines.append(warning.text("message") ?? [warning.string("type"), warning.string("key"), warning.string("value")].compactMap { $0 }.joined(separator: " "))
            }
        }
        return lines.joined(separator: " ")
    }

    static let skip = "__skip__"

    /// The create call: the source's configuration, the choices made here, and each disk imported from the source.
    static func params(meta: JSONObject, result: FormResult) -> [String: String] {
        var params: [String: String] = [:]
        for (key, value) in meta.object("create-args") ?? [:] {
            let text = (value as? String) ?? jsonDouble(value).map { String(Int($0)) } ?? "\(value)"
            // CD drives keep their slot but not the source's ISO, which doesn't exist here.
            params[key] = text.contains("media=cdrom") ? "none,media=cdrom" : text
        }
        let disks = meta.object("disks") ?? [:]
        let renamed = result["virtio-prep"] == "1" ? Self.sataSlots(for: disks.keys, taken: Array(params.keys) + Array(disks.keys)) : [:]
        if !renamed.isEmpty { params["scsihw"] = "virtio-scsi-single" }
        let format = result["format"].isEmpty ? "" : ",format=\(result["format"])"
        for (key, value) in disks {
            let choice = result["storage:\(key)"]
            if choice == Self.skip { continue }
            let target = choice.isEmpty ? result["storage"] : choice
            // "storage:0" plus import-from is Proxmox's way of saying "allocate as big as the source".
            if key.hasPrefix("efidisk") {
                params[key] = "\(target):0,efitype=4m\(format)"
            } else if let source = (value as? JSONObject)?.text("volid") {
                params[renamed[key] ?? key] = "\(target):0,import-from=\(source)\(format)"
            }
        }
        if let boot = params["boot"], !renamed.isEmpty {
            params["boot"] = boot.replacing(/order=([^,]*)/) { match in
                "order=" + match.1.split(separator: ";").map { renamed[String($0)] ?? String($0) }.joined(separator: ";")
            }
        }
        for (key, value) in meta.object("net") ?? [:] {
            let net = value as? JSONObject ?? [:]
            let model = net.text("model") ?? "virtio"
            params[key] = (net.text("macaddr").map { "\(model)=\($0)" } ?? model) + ",bridge=\(result["bridge"])"
        }
        for key in ["vmid", "name", "sockets", "cores", "memory", "ostype", "import-working-storage"] where !result[key].isEmpty {
            params[key] = result[key]
        }
        if result["live-restore"] == "1" { params["live-restore"] = "1" }
        return params
    }

    /// SCSI disks move to the free SATA slots after the highest one in use (sata0–sata5), in order.
    static func sataSlots(for disks: some Collection<String>, taken: some Collection<String>) -> [String: String] {
        var next = (taken.compactMap { $0.hasPrefix("sata") ? Int($0.dropFirst(4)) : nil }.max() ?? -1) + 1
        var renamed: [String: String] = [:]
        for key in disks.filter({ $0.hasPrefix("scsi") }).sorted(using: KeyPathComparator(\.self, comparator: .localizedStandard)) where next <= 5 {
            renamed[key] = "sata\(next)"
            next += 1
        }
        return renamed
    }
}
