import SwiftUI

/// One row of the hardware list.
struct HardwareItem: Identifiable {
    enum Kind { case memory, processors, bios, display, machine, scsihw, disk, cdrom, cloudinit, efi, tpm, net, unused, other }

    let key: String
    let kind: Kind
    let title: String
    let symbol: String
    let value: String
    let pending: String?
    let pendingDelete: Bool

    var id: String { key }
    var removable: Bool { ![.memory, .processors, .bios, .display, .machine, .scsihw].contains(kind) }
}

/// VM → Hardware: every device, with editors for each kind.
struct VMHardwareView: View {
    @Environment(Session.self) private var session
    let guest: Resource
    let config: JSONObject
    let pending: [JSONObject]

    @State private var selection: HardwareItem.ID?
    @State private var editor: Editor?
    @State private var waitingEditor: Editor?

    enum Editor: Identifiable {
        case memory, processors, machine, display, choice(String), disk(String), resize(String), move(String), media(String), network(String?)
        case addDisk, addCDROM, addEFI, addTPM, addUSB, addPCI, addSerial, addAudio, addRNG, addCloudInit, addVirtiofs, raw(String?)

        var id: String {
            switch self {
            case .memory: "memory"
            case .processors: "processors"
            case .machine: "machine"
            case .display: "display"
            case .choice(let key): "choice-\(key)"
            case .disk(let key): "disk-\(key)"
            case .resize(let key): "resize-\(key)"
            case .move(let key): "move-\(key)"
            case .media(let key): "media-\(key)"
            case .network(let key): "net-\(key ?? "new")"
            case .addDisk: "add-disk"
            case .addCDROM: "add-cdrom"
            case .addEFI: "add-efi"
            case .addTPM: "add-tpm"
            case .addUSB: "add-usb"
            case .addPCI: "add-pci"
            case .addSerial: "add-serial"
            case .addAudio: "add-audio"
            case .addRNG: "add-rng"
            case .addCloudInit: "add-cloudinit"
            case .addVirtiofs: "add-virtiofs"
            case .raw(let key): "raw-\(key ?? "new")"
            }
        }
    }

    private var path: String { "/nodes/\(guest.node.enc)/qemu/\(guest.vmid)" }

    /// Mappings that cover this node, then the node's own devices, for the passthrough pickers.
    private func passthroughChoices(_ kind: String) async -> [FormField.Choice] {
        var choices: [FormField.Choice] = kind == "usb" ? [.init("spice", "SPICE USB port")] : []
        for mapping in (try? await session.client.list("/cluster/mapping/\(kind)")) ?? []
        where mapping.strings("map").contains(where: { $0.split(separator: ",").contains { $0 == "node=\(guest.node)" } }) {
            let id = mapping.string("id") ?? ""
            choices.append(.init("mapping=\(id)", "Mapping \(id)" + (mapping.text("description").map { " – \($0)" } ?? "")))
        }
        for device in (try? await session.client.list("/nodes/\(guest.node.enc)/hardware/\(kind)")) ?? [] {
            if kind == "pci" {
                let id = device.string("id") ?? ""
                let group = device.int("iommugroup").map { " · IOMMU group \($0)" } ?? ""
                choices.append(.init(id, "\(id)  \(device.text("device_name") ?? device.text("vendor_name") ?? "")\(group)"))
            } else {
                let ids = "\(device.string("vendid") ?? ""):\(device.string("prodid") ?? "")".replacingOccurrences(of: "0x", with: "")
                let name = device.text("product") ?? device.text("manufacturer") ?? ids
                choices.append(.init("host=\(ids)", "\(name) (\(ids))"))
                if let port = device.text("usbpath") { choices.append(.init("host=\(port)", "Port \(port) – currently \(name)")) }
            }
        }
        return choices
    }

    var body: some View {
        let items = Self.items(config: config, pending: pending)
        let selected = items.first { $0.id == selection }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu("Add", systemImage: "plus") {
                    Button("Hard Disk…") { editor = .addDisk }
                    Button("CD/DVD Drive…") { editor = .addCDROM }
                    Button("Network Device…") { editor = .network(nil) }
                    Divider()
                    Button("EFI Disk…") { editor = .addEFI }.disabled(config["efidisk0"] != nil)
                    Button("TPM State…") { editor = .addTPM }.disabled(config["tpmstate0"] != nil)
                    Button("CloudInit Drive…") { editor = .addCloudInit }
                    Divider()
                    Button("USB Device…") { editor = .addUSB }
                    Button("PCI Device…") { editor = .addPCI }
                    Button("Serial Port…") { editor = .addSerial }
                    Button("Audio Device…") { editor = .addAudio }.disabled(config["audio0"] != nil)
                    Button("VirtIO RNG…") { editor = .addRNG }.disabled(config["rng0"] != nil)
                    Button("Shared Folder (Virtiofs)…") { editor = .addVirtiofs }
                    Divider()
                    Button("Other Setting…") { editor = .raw(nil) }
                }
                .fixedSize()
                Button("Edit", systemImage: "pencil") { if let selected { edit(selected) } }
                    .disabled(selected == nil)
                Button("Resize", systemImage: "arrow.up.left.and.arrow.down.right") { if let selected { editor = .resize(selected.key) } }
                    .disabled(selected?.kind != .disk)
                Button("Remove", systemImage: "minus") { if let selected { remove(selected) } }
                    .disabled(selected?.removable != true)
                if let selected, selected.pending != nil || selected.pendingDelete {
                    Button("Revert", systemImage: "arrow.uturn.backward") {
                        Task { await session.run("Revert the pending change", .put, path + "/config", ["revert": selected.key]) }
                    }
                }
                Spacer()
                if items.contains(where: { $0.pending != nil || $0.pendingDelete }) {
                    Label("Orange values apply after the next reboot", systemImage: "arrow.clockwise.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)

            Table(items, selection: $selection) {
                TableColumn("Device") { item in
                    Label(item.title, systemImage: item.symbol)
                        .foregroundStyle(item.pendingDelete ? .secondary : .primary)
                        .strikethrough(item.pendingDelete)
                }
                // The table opens columns at their minimum: wide enough for "Unused Disk (unused0)" or "Cloud-Init Drive (scsi10)".
                .width(min: 210, ideal: 230, max: 320)
                TableColumn("Value") { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.value).fontDesign(.monospaced).lineLimit(2).textSelection(.enabled)
                            .strikethrough(item.pending != nil || item.pendingDelete)
                            .foregroundStyle(item.pending != nil || item.pendingDelete ? .secondary : .primary)
                        if let pending = item.pending {
                            Text(pending).fontDesign(.monospaced).foregroundStyle(.orange).lineLimit(2)
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: HardwareItem.ID.self) { ids in
                if let item = items.first(where: { ids.contains($0.id) }) {
                    Button("Edit…") { edit(item) }
                    if item.kind == .disk {
                        Button("Resize…") { editor = .resize(item.key) }
                        Button("Move Storage…") { editor = .move(item.key) }
                    }
                    Button("Edit Raw Value…") { editor = .raw(item.key) }
                    if item.removable {
                        Divider()
                        Button(item.kind == .unused ? "Delete Disk…" : (item.kind == .disk ? "Detach" : "Remove"), role: .destructive) { remove(item) }
                    }
                }
            } primaryAction: { ids in
                if let item = items.first(where: { ids.contains($0.id) }) { edit(item) }
            }
        }
        .sheet(item: $editor) { editor in sheet(for: editor) }
        .debugAction("add-pci") { editor = .addPCI }
        .debugAction("edit-processors") { waitingEditor = .processors }
        .debugAction("edit-machine") { waitingEditor = .machine }
        // Editors take their values from the config, so visual checks wait for it before opening one.
        .task(id: "\(config.isEmpty)-\(waitingEditor?.id ?? "")") {
            if !config.isEmpty, let waiting = waitingEditor {
                editor = waiting
                waitingEditor = nil
            }
        }
        .debugAction("add-usb") { editor = .addUSB }
        .debugAction("add-virtiofs") { editor = .addVirtiofs }
    }

    // MARK: Actions

    private func edit(_ item: HardwareItem) {
        switch item.kind {
        case .memory: editor = .memory
        case .processors: editor = .processors
        case .machine: editor = .machine
        case .display: editor = .display
        case .bios, .scsihw: editor = .choice(item.key)
        case .disk: editor = .disk(item.key)
        case .cdrom: editor = .media(item.key)
        case .net: editor = .network(item.key)
        default: editor = .raw(item.key)
        }
    }

    private func remove(_ item: HardwareItem) {
        let message: String
        switch item.kind {
        case .unused: message = "The disk image and all data on it will be deleted from storage."
        case .disk: message = "The disk is detached and kept as an unused disk. Its data stays on the storage until you delete it."
        default: message = "The device is removed from the VM's configuration."
        }
        session.confirmation = Confirmation(title: item.kind == .unused ? "Delete \(item.title)?" : "Remove \(item.title)?",
                                            message: message, actionTitle: item.kind == .unused ? "Delete" : "Remove", destructive: true) {
            await apply("Remove \(item.title)", ["delete": item.key])
        }
    }

    @discardableResult
    private func apply(_ title: String, _ params: [String: String]) async -> Bool {
        var params = params
        if let digest = config.string("digest") { params["digest"] = digest }
        return await session.run(title, .put, path + "/config", params)
    }

    // MARK: Editors

    @ViewBuilder private func sheet(for editor: Editor) -> some View {
        switch editor {
        case .memory: memoryEditor
        case .processors: processorEditor
        case .machine: machineEditor
        case .display: displayEditor
        case .choice(let key): choiceEditor(key)
        case .disk(let key): diskEditor(key)
        case .resize(let key):
            FormSheet(title: "Resize \(key)", message: "Disks can only grow. Afterwards, extend the partition and file system inside the guest.",
                      fields: [FormField(key: "size", label: "Add (GiB)", kind: .number, prompt: "10", required: true)],
                      submitTitle: "Resize") { result in
                await session.run("Resize \(key)", .put, path + "/resize", ["disk": key, "size": "+\(result["size"])G"])
            }
        case .move(let key):
            Prepared(load: { await session.storageChoices(on: guest.node, content: "images") }) { storages in
                FormSheet(title: "Move \(key) to another storage", message: "Works while the VM runs. The old copy can be kept as an unused disk.",
                          fields: [FormField(key: "storage", label: "Target storage", kind: .choice(storages), required: true),
                                   FormField(key: "format", label: "Format", kind: .choice([.init("raw"), .init("qcow2"), .init("vmdk")])),
                                   FormField(key: "delete", label: "Delete the source after moving", kind: .toggle)],
                          initial: ["delete": "1"], submitTitle: "Move") { result in
                    var params = result.changed
                    params["disk"] = key
                    if params["delete"] == "0" { params["delete"] = nil }
                    return await session.run("Move \(key)", .post, path + "/move_disk", params)
                }
            }
        case .media(let key): MediaPicker(guest: guest, key: key, current: config.string(key) ?? "") { value in
            await apply("Change the media in \(key)", [key: value])
        }
        case .network(let key): networkEditor(key)
        case .addDisk: addDiskEditor
        case .addCDROM:
            MediaPicker(guest: guest, key: firstFree(["ide2", "ide0", "ide1", "ide3", "sata0", "sata1"]), current: "", isNew: true) { value in
                await apply("Add a CD/DVD drive", [firstFree(["ide2", "ide0", "ide1", "ide3", "sata0", "sata1"]): value])
            }
        case .addEFI:
            Prepared(load: { await session.storageChoices(on: guest.node, content: "images") }) { storages in
                FormSheet(title: "Add EFI disk", message: "Stores UEFI variables such as boot order and Secure Boot keys.",
                          fields: [FormField(key: "storage", label: "Storage", kind: .choice(storages), required: true),
                                   FormField(key: "keys", label: "Pre-enroll Secure Boot keys", kind: .toggle)],
                          initial: ["storage": storages.first?.value ?? "", "keys": "1"], submitTitle: "Add") { result in
                    await apply("Add an EFI disk", ["efidisk0": "\(result["storage"]):1,efitype=4m\(result["keys"] == "1" ? ",pre-enrolled-keys=1" : "")"])
                }
            }
        case .addTPM:
            Prepared(load: { await session.storageChoices(on: guest.node, content: "images") }) { storages in
                FormSheet(title: "Add TPM state", message: "A virtual TPM 2.0 chip, required by Windows 11.",
                          fields: [FormField(key: "storage", label: "Storage", kind: .choice(storages), required: true),
                                   FormField(key: "version", label: "Version", kind: .choice([.init("v2.0", "2.0"), .init("v1.2", "1.2")]), required: true)],
                          initial: ["storage": storages.first?.value ?? "", "version": "v2.0"], submitTitle: "Add") { result in
                    await apply("Add TPM state", ["tpmstate0": "\(result["storage"]):1,version=\(result["version"])"])
                }
            }
        case .addCloudInit:
            Prepared(load: { await session.storageChoices(on: guest.node, content: "images") }) { storages in
                FormSheet(title: "Add CloudInit drive", fields: [
                    FormField(key: "bus", label: "Bus", kind: .choice([.init("ide2", "IDE 2"), .init("ide0", "IDE 0"), .init("scsi30", "SCSI 30"), .init("sata5", "SATA 5")]), required: true),
                    FormField(key: "storage", label: "Storage", kind: .choice(storages), required: true),
                ], initial: ["bus": config["ide2"] == nil ? "ide2" : "ide0", "storage": storages.first?.value ?? ""], submitTitle: "Add") { result in
                    await apply("Add a CloudInit drive", [result["bus"]: "\(result["storage"]):cloudinit"])
                }
            }
        case .addUSB:
            Prepared(load: { await passthroughChoices("usb") }) { devices in
                FormSheet(title: "Add USB device", message: "Pass through a device plugged into \(guest.node) (by ID, or by port so any device there works), a resource mapping, or a SPICE port.",
                          fields: [FormField(key: "host", label: "Device", kind: devices.count > 1 ? .choice(devices) : .text, prompt: "046d:c52b, 1-2 or spice", required: true),
                                   FormField(key: "usb3", label: "USB 3", kind: .toggle)],
                          initial: ["host": devices.dropFirst().first?.value ?? ""], submitTitle: "Add") { result in
                    let host = result["host"]
                    let value = host == "spice" || host.contains("=") ? host : "host=\(host)"
                    return await apply("Add a USB device", [Session.nextKey("usb", in: config, max: 13): value + (result["usb3"] == "1" ? ",usb3=1" : "")])
                }
            }
        case .addPCI:
            Prepared(load: { await passthroughChoices("pci") }) { devices in
                FormSheet(title: "Add PCI device", message: "Pass through a PCI device of \(guest.node), such as a GPU or NIC. Needs IOMMU enabled on the host.",
                          fields: [FormField(key: "device", label: "Device", kind: devices.isEmpty ? .text : .choice(devices), prompt: "0000:01:00.0 or mapping=name", required: true),
                                   FormField(key: "mdev", label: "Mediated device", kind: .lookup { values in
                                       guard let device = values["device"]?.replacingOccurrences(of: "mapping=", with: ""), !device.isEmpty else {
                                           throw LookupNeeds(message: "Pick the device first.")
                                       }
                                       return try await session.client.list("/nodes/\(guest.node.enc)/hardware/pci/\(device.enc)/mdev").compactMap { type in
                                           type.text("type").map { FormField.Choice($0, "\(type.text("name") ?? $0)  —  \(type.int("available") ?? 0) available") }
                                       }
                                   }, prompt: "None", help: "A slice of a GPU that supports it, e.g. NVIDIA vGPU or Intel GVT-g"),
                                   FormField(key: "allfn", label: "All functions", kind: .toggle),
                                   FormField(key: "pcie", label: "PCI Express", kind: .toggle, help: "Requires the q35 machine type"),
                                   FormField(key: "xvga", label: "Primary GPU", kind: .toggle),
                                   FormField(key: "rombar", label: "ROM-Bar", kind: .toggle)],
                          initial: ["device": devices.first?.value ?? "", "rombar": "1"], submitTitle: "Add") { result in
                    var value = result["device"]
                    if result["allfn"] == "1", value.hasSuffix(".0") { value.removeLast(2) }
                    if !result["mdev"].isEmpty { value += ",mdev=\(result["mdev"])" }
                    if result["pcie"] == "1" { value += ",pcie=1" }
                    if result["xvga"] == "1" { value += ",x-vga=1" }
                    if result["rombar"] == "0" { value += ",rombar=0" }
                    return await apply("Add a PCI device", [Session.nextKey("hostpci", in: config, max: 15): value])
                }
            }
        case .addVirtiofs:
            Prepared(load: { ((try? await session.client.list("/cluster/mapping/dir")) ?? []).compactMap { $0.text("id") } }) { mappings in
                FormSheet(title: "Add shared folder",
                          message: mappings.isEmpty ? "Create a directory mapping first under Datacenter → Options → Mappings."
                              : "The guest mounts it with virtiofs, for example: mount -t virtiofs \(mappings.first ?? "share") /mnt/\(mappings.first ?? "share")", fields: [
                    FormField(key: "dirid", label: "Directory mapping", kind: .choice(mappings.map { FormField.Choice($0) }), required: true),
                    FormField(key: "cache", label: "Cache", kind: .choice([.init("auto", "Auto"), .init("always", "Always"), .init("metadata", "Metadata only"), .init("never", "Never")])),
                    FormField(key: "direct-io", label: "Direct I/O", kind: .toggle),
                    FormField(key: "expose-acl", label: "POSIX ACLs", kind: .toggle),
                    FormField(key: "expose-xattr", label: "Extended attributes", kind: .toggle),
                ], initial: ["dirid": mappings.first ?? ""], submitTitle: "Add") { result in
                    var value = "dirid=\(result["dirid"])"
                    if !result["cache"].isEmpty { value += ",cache=\(result["cache"])" }
                    for key in ["direct-io", "expose-acl", "expose-xattr"] where result[key] == "1" { value += ",\(key)=1" }
                    return await apply("Add a shared folder", [Session.nextKey("virtiofs", in: config, max: 9): value])
                }
            }
        case .addSerial:
            FormSheet(title: "Add serial port", fields: [FormField(key: "port", label: "Connect to", prompt: "socket or /dev/ttyS0", required: true)],
                      initial: ["port": "socket"], submitTitle: "Add") { result in
                await apply("Add a serial port", [Session.nextKey("serial", in: config, max: 3): result["port"]])
            }
        case .addAudio:
            FormSheet(title: "Add audio device", fields: [
                FormField(key: "device", label: "Device", kind: .choice([.init("ich9-intel-hda", "Intel HDA (ICH9)"), .init("intel-hda", "Intel HDA"), .init("AC97", "AC97")]), required: true),
                FormField(key: "driver", label: "Backend", kind: .choice([.init("spice", "SPICE"), .init("none", "None")]), required: true),
            ], initial: ["device": "ich9-intel-hda", "driver": "spice"], submitTitle: "Add") { result in
                await apply("Add an audio device", ["audio0": "device=\(result["device"]),driver=\(result["driver"])"])
            }
        case .addRNG:
            FormSheet(title: "Add VirtIO RNG", message: "Gives the guest entropy from the host.", fields: [
                FormField(key: "source", label: "Entropy source", kind: .choice([.init("/dev/urandom"), .init("/dev/random"), .init("/dev/hwrng")]), required: true),
                FormField(key: "max_bytes", label: "Limit (bytes per period)", kind: .number, prompt: "1024"),
                FormField(key: "period", label: "Period (ms)", kind: .number, prompt: "1000"),
            ], initial: ["source": "/dev/urandom", "max_bytes": "1024", "period": "1000"], submitTitle: "Add") { result in
                var value = "source=\(result["source"])"
                if !result["max_bytes"].isEmpty { value += ",max_bytes=\(result["max_bytes"])" }
                if !result["period"].isEmpty { value += ",period=\(result["period"])" }
                return await apply("Add a VirtIO RNG", ["rng0": value])
            }
        case .raw(let key):
            FormSheet(title: key == nil ? "Add setting" : "Edit \(key!)",
                      message: "Writes the value straight into the VM configuration. See `man qm.conf` for every option.",
                      fields: [FormField(key: "key", label: "Key", prompt: "e.g. args, hookscript, vga", required: true, lockedOnEdit: true),
                               FormField(key: "value", label: "Value", kind: .multiline)],
                      initial: ["key": key ?? "", "value": key.flatMap { config.string($0) } ?? ""], isEdit: key != nil) { result in
                let name = key ?? result["key"]
                return await apply("Change \(name)", result["value"].isEmpty ? ["delete": name] : [name: result["value"]])
            }
        }
    }

    private var memoryEditor: some View {
        let balloon = config.string("balloon")
        let memory = String((config.string("memory") ?? "2048").split(separator: ",").first.map { $0.replacingOccurrences(of: "current=", with: "") } ?? "2048")
        return FormSheet(title: "Memory", fields: [
            FormField(key: "memory", label: "Memory (MiB)", kind: .number, prompt: "2048", required: true),
            FormField(key: "ballooning", label: "Ballooning device", kind: .toggle, help: "Lets the host reclaim unused guest memory"),
            FormField(key: "balloon", label: "Minimum memory (MiB)", kind: .number, prompt: "Same as memory"),
        ], initial: ["memory": memory, "ballooning": balloon == "0" ? "0" : "1", "balloon": balloon == "0" ? "" : (balloon ?? "")]) { result in
            var params = ["memory": result["memory"]]
            if result["ballooning"] == "0" { params["balloon"] = "0" } else if !result["balloon"].isEmpty { params["balloon"] = result["balloon"] } else if balloon != nil { params["delete"] = "balloon" }
            return await apply("Change memory", params)
        }
    }

    private var processorEditor: some View {
        Prepared(load: {
            let flags = ((try? await session.client.list("/nodes/\(guest.node.enc)/capabilities/qemu/cpu-flags")) ?? [])
                .compactMap { flag in flag.text("name").map { FormField.Choice($0, flag.text("description") ?? $0) } }
            return (await session.cpuChoices(on: guest.node), flags)
        }) { loaded in processorForm(loaded.0, flags: loaded.1) }
    }

    private func processorForm(_ cpus: [FormField.Choice], flags: [FormField.Choice]) -> some View {
        let cpu = PropertyString(config.string("cpu") ?? "", defaultKey: "cputype")
        // Flags already set but missing from the server's list stay editable.
        let current = (cpu["flags"] ?? "").split(separator: ";").map { String($0.dropFirst()) }
        let allFlags = flags + current.filter { name in !flags.contains { $0.value == name } }.map { FormField.Choice($0) }
        return FormSheet(title: "Processors", fields: [
            FormField(key: "sockets", label: "Sockets", kind: .number, required: true),
            FormField(key: "cores", label: "Cores per socket", kind: .number, required: true),
            FormField(key: "cpu", label: "Type", kind: .choice(cpus), help: "host gives the best performance but can block live migration between different CPUs"),
            FormField(key: "numa", label: "NUMA", kind: .toggle),
            FormField(key: "vcpus", label: "Active vCPUs", kind: .number, prompt: "All"),
            FormField(key: "cpulimit", label: "CPU limit", kind: .number, prompt: "Unlimited"),
            FormField(key: "cpuunits", label: "CPU weight", kind: .number, prompt: "100"),
            FormField(key: "affinity", label: "CPU affinity", prompt: "e.g. 0-3,8"),
            FormField(key: "flags", label: "CPU flags", kind: .flags(allFlags), help: "Turn features on or off on top of the CPU type"),
        ], initial: ["sockets": config.string("sockets") ?? "1", "cores": config.string("cores") ?? "1", "cpu": cpu["cputype"] ?? "",
                     "numa": config.string("numa") ?? "0", "vcpus": config.string("vcpus") ?? "", "cpulimit": config.string("cpulimit") ?? "",
                     "cpuunits": config.string("cpuunits") ?? "", "affinity": config.string("affinity") ?? "", "flags": cpu["flags"] ?? ""],
                  isEdit: true) { result in
            var params = result.params
            // cpu is "type,flags=…,hidden=…": change the type and flags, keep the rest.
            params["cpu"] = nil
            params["flags"] = nil
            var deletes = (params["delete"] ?? "").split(separator: ",").map(String.init).filter { $0 != "cpu" && $0 != "flags" }
            let option = VMOption.cpu(config.string("cpu") ?? "", type: result["cpu"], flags: result["flags"])
            if option != (config.string("cpu") ?? "") {
                if option.isEmpty { deletes.append("cpu") } else { params["cpu"] = option }
            }
            params["delete"] = deletes.isEmpty ? nil : deletes.joined(separator: ",")
            return await apply("Change processors", params)
        }
    }

    /// Machine type with an optional pinned version (so QEMU updates don't change the virtual hardware) and vIOMMU.
    private var machineEditor: some View {
        Prepared(load: { (try? await session.client.list("/nodes/\(guest.node.enc)/capabilities/qemu/machines")) ?? [] }) { machines in
            let machine = PropertyString(config.string("machine") ?? "", defaultKey: "type")
            let versions = machines.compactMap { item -> FormField.Choice? in
                guard let id = item.text("id"), let type = item.text("type") else { return nil }
                return FormField.Choice(id, "\(type == "q35" ? "q35" : "i440fx"), version \(item.text("version") ?? id)")
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedDescending }
            let windows = (config.string("ostype") ?? "").hasPrefix("w")
            FormSheet(title: "Machine", message: "Changing the machine version can change the hardware the guest sees." +
                        (windows ? " Windows guests should keep a pinned version." : ""), fields: [
                FormField(key: "type", label: "Machine", kind: .choice([.init("q35", "q35 (latest)")] + versions), prompt: "Default (i440fx, latest)",
                          help: "A version pins the virtual hardware across QEMU updates"),
                FormField(key: "viommu", label: "vIOMMU", kind: .choice([.init("intel", "Intel (AMD compatible, q35 only)"), .init("virtio", "VirtIO")]), prompt: "None",
                          help: "Lets the guest pass devices on to its own guests"),
            ], initial: ["type": machine["type"] == "pc" ? "" : machine["type"] ?? "", "viommu": machine["viommu"] ?? ""], isEdit: true) { result in
                let option = VMOption.machine(config.string("machine") ?? "", type: result["type"], viommu: result["viommu"])
                if option == (config.string("machine") ?? "") { return true }
                return await apply("Change the machine", option.isEmpty ? ["delete": "machine"] : ["machine": option])
            }
        }
    }

    /// Display type plus its video memory and VNC clipboard, keeping any other display options.
    private var displayEditor: some View {
        let vga = PropertyString(config.string("vga") ?? "", defaultKey: "type")
        return FormSheet(title: "Display", fields: [
            FormField(key: "type", label: "Graphic card", kind: .choice(Choices.display), prompt: "Default"),
            FormField(key: "memory", label: "Memory (MiB)", kind: .number, prompt: "Default"),
            FormField(key: "clipboard", label: "VNC clipboard", kind: .toggle, help: "Copy and paste through the noVNC console (needs the SPICE guest tools)"),
        ], initial: ["type": vga["type"] ?? "", "memory": vga["memory"] ?? "", "clipboard": vga["clipboard"] == "vnc" ? "1" : "0"], isEdit: true) { result in
            let option = VMOption.display(config.string("vga") ?? "", type: result["type"], memory: result["memory"], clipboard: result["clipboard"] == "1")
            if option == (config.string("vga") ?? "") { return true }
            return await apply("Change the display", option.isEmpty ? ["delete": "vga"] : ["vga": option])
        }
    }

    private func choiceEditor(_ key: String) -> some View {
        let (title, choices): (String, [FormField.Choice]) = key == "bios" ? ("BIOS", Choices.bios) : ("SCSI Controller", Choices.scsihw)
        let current = config.string(key) ?? ""
        return FormSheet(title: title, fields: [FormField(key: key, label: title, kind: .choice(choices))],
                         initial: [key: current], isEdit: true) { result in
            await apply("Change \(title.lowercased())", result.params)
        }
    }

    private func diskEditor(_ key: String) -> some View {
        var disk = PropertyString(config.string(key) ?? "", defaultKey: "file")
        return FormSheet(title: "Hard Disk (\(key))", message: disk["file"].map { "Volume: \($0)" }, fields: [
            FormField(key: "cache", label: "Cache", kind: .choice(Choices.cache)),
            FormField(key: "discard", label: "Discard", kind: .toggle, help: "Passes TRIM to thin-provisioned storage"),
            FormField(key: "iothread", label: "IO thread", kind: .toggle),
            FormField(key: "ssd", label: "SSD emulation", kind: .toggle),
            FormField(key: "backup", label: "Include in backups", kind: .toggle),
            FormField(key: "replicate", label: "Replicate", kind: .toggle),
            FormField(key: "ro", label: "Read-only", kind: .toggle),
        ], initial: ["cache": disk["cache"] ?? "", "discard": disk["discard"] == "on" ? "1" : "0", "iothread": disk["iothread"] ?? "0",
                     "ssd": disk["ssd"] ?? "0", "backup": disk["backup"] ?? "1", "replicate": disk["replicate"] ?? "1", "ro": disk["ro"] ?? "0"]) { result in
            disk["cache"] = result["cache"].isEmpty ? nil : result["cache"]
            disk["discard"] = result["discard"] == "1" ? "on" : nil
            disk["iothread"] = result["iothread"] == "1" ? "1" : nil
            disk["ssd"] = result["ssd"] == "1" ? "1" : nil
            disk["backup"] = result["backup"] == "0" ? "0" : nil
            disk["replicate"] = result["replicate"] == "0" ? "0" : nil
            disk["ro"] = result["ro"] == "1" ? "1" : nil
            return await apply("Change \(key)", [key: disk.raw])
        }
    }

    private func networkEditor(_ key: String?) -> some View {
        let nic = PropertyString(key.flatMap { config.string($0) } ?? "")
        let model = nic.nicModel ?? "virtio"
        return Prepared(load: { await session.bridgeChoices(on: guest.node) }) { bridges in
            FormSheet(title: key.map { "Network Device (\($0))" } ?? "Add network device", fields: [
                FormField(key: "bridge", label: "Bridge", kind: .choice(bridges), required: true),
                FormField(key: "model", label: "Model", kind: .choice(Choices.nicModels), required: true),
                FormField(key: "tag", label: "VLAN tag", kind: .number, prompt: "None"),
                FormField(key: "macaddr", label: "MAC address", prompt: "Automatic"),
                FormField(key: "firewall", label: "Firewall", kind: .toggle),
                FormField(key: "link_down", label: "Disconnect", kind: .toggle),
                FormField(key: "rate", label: "Rate limit (MB/s)", kind: .number, prompt: "Unlimited"),
                FormField(key: "mtu", label: "MTU", kind: .number, prompt: "Same as bridge"),
                FormField(key: "queues", label: "Multiqueue", kind: .number, prompt: "Off"),
            ], initial: ["bridge": nic["bridge"] ?? bridges.first?.value ?? "vmbr0", "model": model, "tag": nic["tag"] ?? "",
                         "macaddr": nic.nicModel.flatMap { nic[$0] } ?? "", "firewall": nic["firewall"] ?? (key == nil ? "1" : "0"),
                         "link_down": nic["link_down"] ?? "0", "rate": nic["rate"] ?? "", "mtu": nic["mtu"] ?? "", "queues": nic["queues"] ?? ""],
                      submitTitle: key == nil ? "Add" : "Save") { result in
                var value = PropertyString("")
                value[result["model"]] = result["macaddr"].isEmpty ? nil : result["macaddr"]
                if value[result["model"]] == nil { value.pairs.insert(.init(key: "", value: result["model"]), at: 0) }
                for field in ["bridge", "tag", "rate", "mtu", "queues"] where !result[field].isEmpty { value[field] = result[field] }
                if result["firewall"] == "1" { value["firewall"] = "1" }
                if result["link_down"] == "1" { value["link_down"] = "1" }
                let target = key ?? Session.nextKey("net", in: config)
                return await apply(key == nil ? "Add a network device" : "Change \(target)", [target: value.raw])
            }
        }
    }

    private var addDiskEditor: some View {
        Prepared(load: { await session.storageChoices(on: guest.node, content: "images") }) { storages in
            FormSheet(title: "Add hard disk", fields: [
                FormField(key: "bus", label: "Bus", kind: .choice(Choices.buses), required: true),
                FormField(key: "storage", label: "Storage", kind: .choice(storages), required: true),
                FormField(key: "size", label: "Size (GiB)", kind: .number, prompt: "32", required: true),
                FormField(key: "cache", label: "Cache", kind: .choice(Choices.cache)),
                FormField(key: "discard", label: "Discard", kind: .toggle),
                FormField(key: "iothread", label: "IO thread", kind: .toggle),
                FormField(key: "ssd", label: "SSD emulation", kind: .toggle),
                FormField(key: "backup", label: "Include in backups", kind: .toggle),
            ], initial: ["bus": "scsi", "storage": storages.first?.value ?? "", "size": "32", "discard": "1", "iothread": "1", "backup": "1"],
                      submitTitle: "Add") { result in
                var value = "\(result["storage"]):\(result["size"])"
                if !result["cache"].isEmpty { value += ",cache=\(result["cache"])" }
                if result["discard"] == "1" { value += ",discard=on" }
                if result["iothread"] == "1", ["scsi", "virtio"].contains(result["bus"]) { value += ",iothread=1" }
                if result["ssd"] == "1", result["bus"] != "virtio" { value += ",ssd=1" }
                if result["backup"] == "0" { value += ",backup=0" }
                let max = ["ide": 3, "sata": 5, "virtio": 15, "scsi": 30][result["bus"]] ?? 30
                return await apply("Add a hard disk", [Session.nextKey(result["bus"], in: config, max: max): value])
            }
        }
    }

    private func firstFree(_ keys: [String]) -> String {
        keys.first { config[$0] == nil } ?? keys.last ?? "ide2"
    }

    // MARK: Building rows

    static func items(config: JSONObject, pending: [JSONObject]) -> [HardwareItem] {
        var pendingValues: [String: String] = [:]
        var pendingDeletes = Set<String>()
        var current = config
        if !pending.isEmpty {
            current = [:]
            for entry in pending {
                guard let key = entry.string("key") else { continue }
                if let value = entry.string("value") { current[key] = value }
                if let next = entry.string("pending") {
                    pendingValues[key] = next
                    if current[key] == nil { current[key] = next }
                }
                if entry["delete"] != nil, jsonInt(entry["delete"]) != 0 { pendingDeletes.insert(key) }
            }
        }
        let strings: [String: String] = current.reduce(into: [:]) { result, item in
            if let text = current.string(item.key) { result[item.key] = text }
        }
        func value(_ key: String) -> String? { strings[key] }
        func item(_ key: String, _ kind: HardwareItem.Kind, _ title: String, _ symbol: String, _ text: String) -> HardwareItem {
            HardwareItem(key: key, kind: kind, title: title, symbol: symbol, value: text,
                         pending: pendingValues[key].flatMap { $0 == value(key) ? nil : $0 }, pendingDelete: pendingDeletes.contains(key))
        }

        var items: [HardwareItem] = []
        let memoryMiB = Double((value("memory") ?? "512").replacingOccurrences(of: "current=", with: "").split(separator: ",").first.map(String.init) ?? "512") ?? 512
        var memoryText = Format.bytes(memoryMiB * 1_048_576)
        if let balloon = value("balloon") { memoryText += balloon == "0" ? ", no ballooning" : ", minimum \(Format.bytes((Double(balloon) ?? 0) * 1_048_576))" }
        items.append(item("memory", .memory, "Memory", "memorychip", memoryText))

        let sockets = Int(value("sockets") ?? "1") ?? 1, cores = Int(value("cores") ?? "1") ?? 1
        var cpuText = "\(sockets * cores) (\(sockets) socket\(sockets == 1 ? "" : "s"), \(cores) core\(cores == 1 ? "" : "s"))"
        if let type = value("cpu") { cpuText += " [\(PropertyString(type, defaultKey: "cputype")["cputype"] ?? type)]" }
        if jsonBool(value("numa")) { cpuText += " NUMA" }
        var processors = item("cores", .processors, "Processors", "cpu", cpuText)
        if let next = ["sockets", "cores", "cpu"].compactMap({ pendingValues[$0] }).first {
            processors = HardwareItem(key: "processors", kind: .processors, title: "Processors", symbol: "cpu", value: cpuText, pending: "pending: \(next)", pendingDelete: false)
        }
        items.append(processors)
        items.append(item("bios", .bios, "BIOS", "memorychip.fill", value("bios") == "ovmf" ? "OVMF (UEFI)" : "Default (SeaBIOS)"))
        items.append(item("vga", .display, "Display", "display", value("vga") ?? "Default"))
        items.append(item("machine", .machine, "Machine", "rectangle.connected.to.line.below", value("machine") ?? "Default (i440fx)"))
        items.append(item("scsihw", .scsihw, "SCSI Controller", "point.3.filled.connected.trianglepath.dotted",
                          Choices.scsihw.first { $0.value == value("scsihw") }?.label ?? value("scsihw") ?? "Default (LSI 53C895A)"))

        let order = ["ide", "sata", "scsi", "virtio"]
        let diskKeys = strings.keys.filter { key in order.contains { key.hasPrefix($0) && Int(key.dropFirst($0.count)) != nil } }
            .sorted { lhs, rhs in
                let l = order.firstIndex { lhs.hasPrefix($0) } ?? 0, r = order.firstIndex { rhs.hasPrefix($0) } ?? 0
                return l == r ? lhs.localizedStandardCompare(rhs) == .orderedAscending : l < r
            }
        for key in diskKeys {
            let raw = value(key) ?? ""
            if raw.contains("cloudinit") {
                items.append(item(key, .cloudinit, "CloudInit Drive (\(key))", "cloud", raw))
            } else if raw.contains("media=cdrom") {
                items.append(item(key, .cdrom, "CD/DVD Drive (\(key))", "opticaldisc", raw))
            } else {
                items.append(item(key, .disk, "Hard Disk (\(key))", "internaldrive", raw))
            }
        }
        if let efi = value("efidisk0") { items.append(item("efidisk0", .efi, "EFI Disk", "lock.shield", efi)) }
        if let tpm = value("tpmstate0") { items.append(item("tpmstate0", .tpm, "TPM State", "cpu.fill", tpm)) }
        for key in strings.keys.filter({ $0.hasPrefix("net") }).sorted(using: KeyPathComparator(\.self, comparator: .localizedStandard)) {
            items.append(item(key, .net, "Network Device (\(key))", "network", value(key) ?? ""))
        }
        let extras: [(String, String, String)] = [("usb", "USB Device", "cable.connector"), ("hostpci", "PCI Device", "rectangle.and.hand.point.up.left"),
                                                  ("serial", "Serial Port", "cable.coaxial"), ("parallel", "Parallel Port", "cable.coaxial"),
                                                  ("audio", "Audio Device", "speaker.wave.2"), ("rng", "VirtIO RNG", "dice"),
                                                  ("virtiofs", "Virtiofs", "folder"), ("unused", "Unused Disk", "externaldrive.badge.xmark")]
        for (prefix, title, symbol) in extras {
            for key in strings.keys.filter({ $0.hasPrefix(prefix) && Int($0.dropFirst(prefix.count)) != nil }).sorted(using: KeyPathComparator(\.self, comparator: .localizedStandard)) {
                items.append(item(key, prefix == "unused" ? .unused : .other, "\(title) (\(key))", symbol, value(key) ?? ""))
            }
        }
        return items
    }
}

/// Choose an ISO image (or no media) for a CD/DVD drive.
struct MediaPicker: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let guest: Resource
    let key: String
    let current: String
    var isNew = false
    let save: (String) async -> Bool

    @State private var isos: [FormField.Choice] = []
    @State private var loaded = false
    @State private var choice = "none"
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add CD/DVD drive" : "CD/DVD Drive (\(key))").font(.title2.bold())
            if !loaded {
                ProgressView().controlSize(.small)
            } else {
                Picker("Media", selection: $choice) {
                    Text("No media").tag("none")
                    Text("Physical drive on the host").tag("cdrom")
                    if !isos.isEmpty {
                        Divider()
                        ForEach(isos, id: \.self) { Text($0.label).tag($0.value) }
                    }
                }
                .pickerStyle(.radioGroup)
                .frame(maxHeight: 320)
                if isos.isEmpty {
                    Text("No ISO images on this node's storage yet. Upload one from a storage's ISO Images tab.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                Button(isNew ? "Add" : "Save") {
                    Task {
                        busy = true
                        if await save("\(choice),media=cdrom") { dismiss() }
                        busy = false
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520)
        .task {
            isos = await session.volumeChoices(on: guest.node, content: "iso")
            let file = PropertyString(current, defaultKey: "file")["file"] ?? "none"
            choice = file
            loaded = true
        }
    }
}
