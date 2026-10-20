import Foundation

/// Proxmox packs device settings into `key=value,key=value` strings, often led by an
/// unkeyed value: `local-lvm:vm-100-disk-0,iothread=1,size=32G` or
/// `virtio=BC:24:11:AA:BB:CC,bridge=vmbr0,firewall=1`.
nonisolated struct PropertyString: Equatable {
    struct Pair: Equatable {
        var key: String
        var value: String
    }

    var pairs: [Pair]
    /// The key the first unkeyed item is stored under (e.g. "file" for disks).
    let defaultKey: String

    init(_ raw: String, defaultKey: String = "") {
        self.defaultKey = defaultKey
        pairs = raw.split(separator: ",", omittingEmptySubsequences: true).map { item in
            if let eq = item.firstIndex(of: "=") {
                return Pair(key: String(item[..<eq]), value: String(item[item.index(after: eq)...]))
            }
            return Pair(key: defaultKey, value: String(item))
        }
    }

    subscript(key: String) -> String? {
        get { pairs.first { $0.key == key }?.value }
        set {
            if let index = pairs.firstIndex(where: { $0.key == key }) {
                if let newValue { pairs[index].value = newValue } else { pairs.remove(at: index) }
            } else if let newValue {
                if key == defaultKey { pairs.insert(Pair(key: key, value: newValue), at: 0) } else { pairs.append(Pair(key: key, value: newValue)) }
            }
        }
    }

    func flag(_ key: String) -> Bool { jsonBool(self[key]) }

    var raw: String {
        pairs.map { $0.key == defaultKey && !defaultKey.isEmpty || $0.key.isEmpty ? $0.value : "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }
}

nonisolated extension PropertyString {
    /// For `net0` on a VM the NIC model is the key holding the MAC (`virtio=BC:…`).
    static let nicModels = ["virtio", "e1000", "e1000e", "rtl8139", "vmxnet3"]

    var nicModel: String? { pairs.first { Self.nicModels.contains($0.key) }?.key }
}

/// Edits to VM options that pack several settings into one property string. Each changes only what its editor shows
/// and keeps the rest (e.g. `hidden=1` set in the web UI); an empty result means the option goes back to its default.
nonisolated enum VMOption {
    /// `cpu`: "type,flags=+aes;-pcid,hidden=1".
    static func cpu(_ current: String, type: String, flags: String) -> String {
        var cpu = PropertyString(current, defaultKey: "cputype")
        cpu["cputype"] = type.isEmpty ? nil : type
        cpu["flags"] = flags.isEmpty ? nil : flags
        return cpu.raw
    }

    /// `machine`: "pc-q35-9.2+pve1,viommu=intel". Options need a type in front; the default one is "pc".
    static func machine(_ current: String, type: String, viommu: String) -> String {
        var machine = PropertyString(current, defaultKey: "type")
        machine["type"] = type.isEmpty ? nil : type
        machine["viommu"] = viommu.isEmpty ? nil : viommu
        if machine["type"] == nil, !machine.pairs.isEmpty { machine["type"] = "pc" }
        return machine.raw
    }

    /// `vga`: "virtio,memory=32,clipboard=vnc". Options need a type in front; the default one is "std".
    static func display(_ current: String, type: String, memory: String, clipboard: Bool) -> String {
        var vga = PropertyString(current, defaultKey: "type")
        vga["type"] = type.isEmpty ? nil : type
        vga["memory"] = memory.isEmpty ? nil : memory
        vga["clipboard"] = clipboard ? "vnc" : nil
        if vga["type"] == nil, !vga.pairs.isEmpty { vga["type"] = "std" }
        return vga.raw
    }
}

