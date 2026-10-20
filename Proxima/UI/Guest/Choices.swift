import SwiftUI

/// Pick lists that need a round trip: storages, bridges, ISO images, templates.
extension Session {
    func storageChoices(on node: String, content: String) async -> [FormField.Choice] {
        let list = (try? await client.list("/nodes/\(node.enc)/storage", ["content": content, "enabled": "1"])) ?? []
        return list.map(StorageInfo.init).filter(\.enabled).map { storage in
            FormField.Choice(storage.storage, storage.total > 0 ? "\(storage.storage) (\(Format.bytes(storage.available)) free)" : storage.storage)
        }
    }

    /// The node's CPU models, custom ones included (PVE 9), or the common built-in list if the server can't say.
    func cpuChoices(on node: String) async -> [FormField.Choice] {
        guard let list = try? await client.list("/nodes/\(node.enc)/capabilities/qemu/cpu"), !list.isEmpty else { return Choices.cpuTypes }
        return list.filter { !$0.bool("abstract") }.compactMap { model in
            model.text("name").map { name in FormField.Choice(name, model.bool("custom") ? "\(name) (custom)" : name) }
        }
    }

    func bridgeChoices(on node: String) async -> [FormField.Choice] {
        let list = (try? await client.list("/nodes/\(node.enc)/network", ["type": "any_bridge"])) ?? []
        return list.filter { ($0.string("type") ?? "").lowercased().contains("bridge") || $0.string("type") == "vnet" }
            .compactMap { $0.text("iface") }
            .sorted()
            .map { FormField.Choice($0) }
    }

    func volumeChoices(on node: String, content: String) async -> [FormField.Choice] {
        var choices: [FormField.Choice] = []
        for storage in await storageChoices(on: node, content: content) {
            let list = (try? await client.list("/nodes/\(node.enc)/storage/\(storage.value.enc)/content", ["content": content])) ?? []
            choices += list.map(Volume.init).map { FormField.Choice($0.volid, "\(storage.value): \($0.fileName)") }
        }
        return choices
    }

    /// First free slot like scsi1, net2, usb0.
    static func nextKey(_ prefix: String, in config: JSONObject, max: Int = 31) -> String {
        for index in 0...max where config["\(prefix)\(index)"] == nil { return "\(prefix)\(index)" }
        return "\(prefix)\(max)"
    }
}

/// Shows a spinner while the sheet's pick lists load, then the sheet.
struct Prepared<Content: View, Value>: View {
    let load: () async -> Value
    @ViewBuilder let content: (Value) -> Content
    @State private var value: Value?

    var body: some View {
        if let value {
            content(value)
        } else {
            ProgressView("Loading…")
                .controlSize(.small)
                .frame(width: 520, height: 240)
                .task { value = await load() }
        }
    }
}

enum Choices {
    static let cpuTypes = ["host", "x86-64-v2-AES", "x86-64-v3", "x86-64-v4", "x86-64-v2", "kvm64", "qemu64", "max",
                           "Skylake-Server", "Cascadelake-Server", "Icelake-Server", "SapphireRapids", "EPYC", "EPYC-Rome", "EPYC-Milan", "EPYC-Genoa"]
        .map { FormField.Choice($0) }
    static let nicModels = [("virtio", "VirtIO (paravirtualized)"), ("e1000", "Intel E1000"), ("e1000e", "Intel E1000E"),
                            ("rtl8139", "Realtek RTL8139"), ("vmxnet3", "VMware vmxnet3")].map { FormField.Choice($0.0, $0.1) }
    static let cache = [("none", "No cache"), ("directsync", "Direct sync"), ("writethrough", "Write through"),
                        ("writeback", "Write back"), ("unsafe", "Write back (unsafe)")].map { FormField.Choice($0.0, $0.1) }
    static let bios = [("seabios", "SeaBIOS"), ("ovmf", "OVMF (UEFI)")].map { FormField.Choice($0.0, $0.1) }
    static let display = [("std", "Standard VGA"), ("virtio", "VirtIO-GPU"), ("virtio-gl", "VirGL GPU"), ("qxl", "SPICE"),
                          ("vmware", "VMware compatible"), ("cirrus", "Cirrus Logic"), ("serial0", "Serial terminal 0"), ("none", "None")]
        .map { FormField.Choice($0.0, $0.1) }
    static let machine = [("pc", "Default (i440fx)"), ("q35", "q35")].map { FormField.Choice($0.0, $0.1) }
    static let scsihw = [("virtio-scsi-single", "VirtIO SCSI single"), ("virtio-scsi-pci", "VirtIO SCSI"), ("lsi", "LSI 53C895A"),
                         ("lsi53c810", "LSI 53C810"), ("megasas", "MegaRAID SAS 8708EM2"), ("pvscsi", "VMware PVSCSI")]
        .map { FormField.Choice($0.0, $0.1) }
    static let buses = [("scsi", "SCSI"), ("virtio", "VirtIO Block"), ("sata", "SATA"), ("ide", "IDE")].map { FormField.Choice($0.0, $0.1) }
    static let ostypes = [("l26", "Linux 6.x / 2.6 kernel"), ("win11", "Windows 11/2022/2025"), ("win10", "Windows 10/2016/2019"),
                          ("win8", "Windows 8/2012"), ("win7", "Windows 7/2008r2"), ("wxp", "Windows XP/2003"), ("solaris", "Solaris"),
                          ("l24", "Linux 2.4 kernel"), ("other", "Other")].map { FormField.Choice($0.0, $0.1) }
    static let backupModes = [("snapshot", "Snapshot"), ("suspend", "Suspend"), ("stop", "Stop")].map { FormField.Choice($0.0, $0.1) }
    /// The web UI's schedule examples (systemd calendar events).
    static let schedules = [("*/30", "Every 30 minutes"), ("*/2:00", "Every two hours"), ("21:00", "Every day at 21:00"), ("2,22:30", "Every day at 02:30 and 22:30"),
                            ("mon..fri 00:00", "Monday to Friday at 00:00"), ("mon..fri */1:00", "Monday to Friday, hourly"),
                            ("mon..fri 7..18:00/15", "Monday to Friday, 07:00 to 18:45 every 15 minutes"), ("sun 01:00", "Sunday at 01:00"),
                            ("monthly", "First day of each month at 00:00"), ("sat *-1..7 15:00", "First Saturday of each month at 15:00"),
                            ("yearly", "First day of the year at 00:00")].map { FormField.Choice($0.0, "\($0.1)  (\($0.0))") }
    static let compression = [("zstd", "ZSTD (fast and good)"), ("lzo", "LZO (fastest)"), ("gzip", "GZIP (good)"), ("0", "None")]
        .map { FormField.Choice($0.0, $0.1) }
}
