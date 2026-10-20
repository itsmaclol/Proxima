import SwiftUI

/// A settings row: title, current value, and what clicking "Edit" opens.
private struct SettingRow: View {
    let title: String
    let value: String
    var monospaced = false
    /// Shown when the option isn't set.
    var placeholder = "Default"
    var edit: (() -> Void)?

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Text(value.isEmpty ? placeholder : value)
                    .foregroundStyle(value.isEmpty ? .tertiary : .secondary)
                    .fontDesign(monospaced && !value.isEmpty ? .monospaced : .default)
                    .lineLimit(3)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                if let edit { Button("Edit", action: edit).buttonStyle(.borderless) }
            }
        } label: {
            Text(title)
        }
    }
}

/// A toggle that writes straight to the guest's config.
private struct ConfigToggle: View {
    @Environment(Session.self) private var session
    let title: String
    let key: String
    let config: JSONObject
    let path: String
    var defaultOn = false
    var help: String?

    var body: some View {
        let isOn = config[key] == nil ? defaultOn : jsonBool(config[key])
        Toggle(isOn: Binding { isOn } set: { newValue in
            Task { await session.run("Change \(title.lowercased())", .put, path + "/config", [key: newValue ? "1" : "0"]) }
        }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct EditRequest: Identifiable {
    let id = UUID()
    let title: String
    var message: String?
    let fields: [FormField]
    let initial: [String: String]
    let apply: (FormResult) -> [String: String]
}

/// Shared plumbing: one form sheet at a time, applied with PUT …/config.
private struct ConfigForm<Content: View>: View {
    @Environment(Session.self) private var session
    let path: String
    let config: JSONObject
    @Binding var request: EditRequest?
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .sheet(item: $request) { request in
                FormSheet(title: request.title, message: request.message, fields: request.fields, initial: request.initial, isEdit: true) { result in
                    var params = request.apply(result)
                    guard !params.isEmpty else { return true }
                    if let digest = config.string("digest") { params["digest"] = digest }
                    return await session.run("Save \(request.title.lowercased())", .put, path + "/config", params)
                }
            }
    }
}

// MARK: Options

struct GuestOptionsView: View {
    @Environment(Session.self) private var session
    let guest: Resource
    let config: JSONObject
    @State private var request: EditRequest?
    @State private var editingBoot = false

    private var path: String { "/nodes/\(guest.node.enc)/\(guest.type)/\(guest.vmid)" }
    private var isVM: Bool { guest.kind == .qemu }

    var body: some View {
        ConfigForm(path: path, config: config, request: $request) {
            Section("General") {
                if isVM {
                    SettingRow(title: "Name", value: config.string("name") ?? "") { text("Name", "name") }
                } else {
                    SettingRow(title: "Hostname", value: config.string("hostname") ?? "") { text("Hostname", "hostname") }
                }
                SettingRow(title: "Tags", value: (config.string("tags") ?? "").replacingOccurrences(of: ";", with: ", "), placeholder: "None") {
                    request = EditRequest(title: "Tags", message: "Separate tags with commas or spaces, e.g. prod, web.",
                                          fields: [FormField(key: "tags", label: "Tags", prompt: "prod, web")],
                                          initial: ["tags": (config.string("tags") ?? "").replacingOccurrences(of: ";", with: ", ")]) { result in
                        let tags = result["tags"].split(whereSeparator: { ",; ".contains($0) }).map { $0.lowercased() }
                        return tags.isEmpty ? ["delete": "tags"] : ["tags": tags.joined(separator: ";")]
                    }
                }
                ConfigToggle(title: "Start at boot", key: "onboot", config: config, path: path, help: "Starts automatically when the node boots")
                SettingRow(title: "Start and shutdown order", value: startupText) { startup() }
                ConfigToggle(title: "Protection", key: "protection", config: config, path: path, help: "Blocks removing this guest and its disks")
                if isVM {
                    SettingRow(title: "OS type", value: Theme.ostypeLabel(config.string("ostype")) ?? "") {
                        request = EditRequest(title: "OS type", fields: [FormField(key: "ostype", label: "Guest OS", kind: .choice(Choices.ostypes))],
                                              initial: ["ostype": config.string("ostype") ?? ""]) { $0.params }
                    }
                    SettingRow(title: "Boot order", value: bootText, monospaced: true) { editingBoot = true }
                } else {
                    SettingRow(title: "OS type", value: Theme.ostypeLabel(config.string("ostype")) ?? "")
                    SettingRow(title: "Architecture", value: config.string("arch") ?? "amd64")
                    SettingRow(title: "Unprivileged", value: jsonBool(config["unprivileged"]) ? "Yes" : "No")
                }
            }
            if isVM {
                Section("Machine") {
                    ConfigToggle(title: "Use tablet for pointer", key: "tablet", config: config, path: path, defaultOn: true)
                    SettingRow(title: "Hotplug", value: config.string("hotplug") ?? "disk,network,usb") {
                        let choices = ["disk", "network", "usb", "memory", "cpu", "cloudinit"].map { FormField.Choice($0, $0.capitalized) }
                        request = EditRequest(title: "Hotplug", fields: [FormField(key: "hotplug", label: "Devices", kind: .multiChoice(choices))],
                                              initial: ["hotplug": config.string("hotplug") ?? "disk,network,usb"]) { result in
                            ["hotplug": result["hotplug"].isEmpty ? "0" : result["hotplug"]]
                        }
                    }
                    ConfigToggle(title: "ACPI support", key: "acpi", config: config, path: path, defaultOn: true)
                    ConfigToggle(title: "KVM hardware virtualization", key: "kvm", config: config, path: path, defaultOn: true)
                    ConfigToggle(title: "Freeze CPU at startup", key: "freeze", config: config, path: path)
                    ConfigToggle(title: "Use local time for RTC", key: "localtime", config: config, path: path)
                    SettingRow(title: "RTC start date", value: config.string("startdate") ?? "now") { text("RTC start date", "startdate", prompt: "now or 2006-06-17T16:01:21") }
                    SettingRow(title: "SMBIOS (type 1)", value: config.string("smbios1") ?? "", monospaced: true) { text("SMBIOS settings", "smbios1") }
                    SettingRow(title: "VM state storage", value: config.string("vmstatestorage") ?? "Automatic") { text("VM state storage", "vmstatestorage") }
                }
                Section("Guest agent") {
                    let agent = PropertyString(config.string("agent") ?? "", defaultKey: "enabled")
                    SettingRow(title: "QEMU guest agent", value: agent.flag("enabled") ? "Enabled\(agent.flag("fstrim_cloned_disks") ? ", trim after clone" : "")" : "Disabled") {
                        request = EditRequest(title: "QEMU guest agent", message: "Install qemu-guest-agent inside the VM to see IP addresses and allow clean shutdowns.",
                                              fields: [FormField(key: "enabled", label: "Use QEMU guest agent", kind: .toggle),
                                                       FormField(key: "fstrim", label: "Run guest trim after moving or cloning a disk", kind: .toggle),
                                                       FormField(key: "type", label: "Type", kind: .choice([.init("virtio", "VirtIO"), .init("isa", "ISA")]))],
                                              initial: ["enabled": agent.flag("enabled") ? "1" : "0", "fstrim": agent.flag("fstrim_cloned_disks") ? "1" : "0",
                                                        "type": agent["type"] ?? ""]) { result in
                            var value = "enabled=\(result["enabled"] == "1" ? 1 : 0)"
                            if result["fstrim"] == "1" { value += ",fstrim_cloned_disks=1" }
                            if !result["type"].isEmpty { value += ",type=\(result["type"])" }
                            return ["agent": value]
                        }
                    }
                }
            } else {
                Section("Console") {
                    SettingRow(title: "Console mode", value: config.string("cmode") ?? "tty") {
                        request = EditRequest(title: "Console mode", fields: [FormField(key: "cmode", label: "Mode",
                                              kind: .choice([.init("tty", "tty"), .init("console", "/dev/console"), .init("shell", "Shell")]))],
                                              initial: ["cmode": config.string("cmode") ?? ""]) { $0.params }
                    }
                    SettingRow(title: "TTY count", value: config.string("tty") ?? "2") { text("TTY count", "tty", prompt: "2") }
                    ConfigToggle(title: "Enable /dev/console", key: "console", config: config, path: path, defaultOn: true)
                }
                Section("Features") {
                    let features = PropertyString(config.string("features") ?? "")
                    SettingRow(title: "Features", value: features.raw.isEmpty ? "None" : features.raw.replacingOccurrences(of: ",", with: ", ")) {
                        request = EditRequest(title: "Features", message: "Nesting is needed for systemd 255+ and Docker inside the container.",
                                              fields: [FormField(key: "nesting", label: "Nesting", kind: .toggle),
                                                       FormField(key: "keyctl", label: "keyctl", kind: .toggle),
                                                       FormField(key: "fuse", label: "FUSE", kind: .toggle),
                                                       FormField(key: "mknod", label: "Create device nodes", kind: .toggle),
                                                       FormField(key: "mount", label: "Allowed mounts", prompt: "nfs;cifs")],
                                              initial: ["nesting": features["nesting"] ?? "0", "keyctl": features["keyctl"] ?? "0",
                                                        "fuse": features["fuse"] ?? "0", "mknod": features["mknod"] ?? "0", "mount": features["mount"] ?? ""]) { result in
                            var parts: [String] = []
                            for flag in ["nesting", "keyctl", "fuse", "mknod"] where result[flag] == "1" { parts.append("\(flag)=1") }
                            if !result["mount"].isEmpty { parts.append("mount=\(result["mount"])") }
                            return parts.isEmpty ? ["delete": "features"] : ["features": parts.joined(separator: ",")]
                        }
                    }
                    SettingRow(title: "Timezone", value: config.string("timezone") ?? "") { text("Timezone", "timezone", prompt: "host, or e.g. Europe/Berlin") }
                }
            }
            Section("Advanced") {
                SettingRow(title: "Hookscript", value: config.string("hookscript") ?? "", monospaced: true, placeholder: "None") { text("Hookscript", "hookscript", prompt: "local:snippets/hook.pl") }
            }
        }
        .sheet(isPresented: $editingBoot) {
            BootOrderSheet(guest: guest, config: config)
        }
    }

    private var startupText: String {
        let startup = PropertyString(config.string("startup") ?? "")
        var parts: [String] = []
        if let order = startup["order"] { parts.append("order \(order)") }
        if let up = startup["up"] { parts.append("wait \(up)s after start") }
        if let down = startup["down"] { parts.append("\(down)s shutdown timeout") }
        return parts.joined(separator: ", ")
    }

    private var bootText: String {
        let boot = config.string("boot") ?? ""
        return boot.hasPrefix("order=") ? boot.dropFirst(6).replacingOccurrences(of: ";", with: " → ") : boot
    }

    private func text(_ title: String, _ key: String, prompt: String = "") {
        request = EditRequest(title: title, fields: [FormField(key: key, label: title, prompt: prompt)],
                              initial: [key: config.string(key) ?? ""]) { $0.params }
    }

    private func startup() {
        let startup = PropertyString(config.string("startup") ?? "")
        request = EditRequest(title: "Start and shutdown order",
                              message: "Lower order starts first and shuts down last. Delay waits before starting the next guest.",
                              fields: [FormField(key: "order", label: "Order", kind: .number, prompt: "Any"),
                                       FormField(key: "up", label: "Startup delay (s)", kind: .number, prompt: "0"),
                                       FormField(key: "down", label: "Shutdown timeout (s)", kind: .number, prompt: "Default")],
                              initial: ["order": startup["order"] ?? "", "up": startup["up"] ?? "", "down": startup["down"] ?? ""]) { result in
            let parts = ["order", "up", "down"].compactMap { result[$0].isEmpty ? nil : "\($0)=\(result[$0])" }
            return parts.isEmpty ? ["delete": "startup"] : ["startup": parts.joined(separator: ",")]
        }
    }
}

/// Drag devices into boot order; unchecked devices are skipped.
private struct BootOrderSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let guest: Resource
    let config: JSONObject
    @State private var devices: [(key: String, on: Bool)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Boot order").font(.title2.bold())
            Text("Drag to reorder. The VM tries checked devices from top to bottom.").foregroundStyle(.secondary)
            List {
                ForEach(devices.indices, id: \.self) { index in
                    Toggle(isOn: $devices[index].on) {
                        HStack {
                            Image(systemName: devices[index].key.hasPrefix("net") ? "network" : (config.string(devices[index].key)?.contains("media=cdrom") == true ? "opticaldisc" : "internaldrive"))
                                .foregroundStyle(.secondary)
                            Text(devices[index].key).fontDesign(.monospaced)
                            Text(config.string(devices[index].key) ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .onMove { devices.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    Task {
                        let order = devices.filter(\.on).map(\.key).joined(separator: ";")
                        if await session.run("Change the boot order", .put, "/nodes/\(guest.node.enc)/qemu/\(guest.vmid)/config", ["boot": "order=\(order)"]) { dismiss() }
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520, height: 440)
        .onAppear {
            let current = (config.string("boot") ?? "").replacingOccurrences(of: "order=", with: "").split(separator: ";").map(String.init)
            let bootable = config.keys.filter { key in
                ["ide", "sata", "scsi", "virtio", "net", "hostpci", "usb"].contains { key.hasPrefix($0) && Int(key.dropFirst($0.count)) != nil }
            }
            let ordered = current.filter(bootable.contains) + bootable.filter { !current.contains($0) }.sorted()
            devices = ordered.map { ($0, current.contains($0)) }
        }
    }
}

// MARK: Cloud-Init

struct CloudInitView: View {
    @Environment(Session.self) private var session
    let guest: Resource
    let config: JSONObject
    @State private var request: EditRequest?

    private var path: String { "/nodes/\(guest.node.enc)/qemu/\(guest.vmid)" }
    private var hasDrive: Bool { config.values.contains { ($0 as? String)?.contains("cloudinit") == true } }

    var body: some View {
        VStack(spacing: 0) {
            if !hasDrive {
                ErrorBanner(message: "This VM has no CloudInit drive yet. Add one under Hardware → Add → CloudInit Drive for these settings to reach the guest.")
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }
            ConfigForm(path: path, config: config, request: $request) {
                Section("User") {
                    SettingRow(title: "User", value: config.string("ciuser") ?? "") { text("User", "ciuser", prompt: "Image default") }
                    SettingRow(title: "Password", value: config["cipassword"] == nil ? "" : "••••••••") {
                        request = EditRequest(title: "Password", message: "Stored hashed on the server.",
                                              fields: [FormField(key: "cipassword", label: "Password", kind: .secure)], initial: [:]) { $0.params }
                    }
                    SettingRow(title: "SSH public keys", value: sshKeys, monospaced: true) {
                        request = EditRequest(title: "SSH public keys", message: "One key per line.",
                                              fields: [FormField(key: "sshkeys", label: "Keys", kind: .multiline)], initial: ["sshkeys": sshKeys]) { result in
                            // Proxmox expects this one parameter URL-encoded on top of the form encoding.
                            result["sshkeys"].isEmpty ? ["delete": "sshkeys"]
                                : ["sshkeys": result["sshkeys"].addingPercentEncoding(withAllowedCharacters: .urlUnreserved) ?? ""]
                        }
                    }
                    ConfigToggle(title: "Upgrade packages on first boot", key: "ciupgrade", config: config, path: path, defaultOn: true)
                }
                Section("Network") {
                    SettingRow(title: "DNS domain", value: config.string("searchdomain") ?? "") { text("DNS domain", "searchdomain", prompt: "Use host settings") }
                    SettingRow(title: "DNS servers", value: config.string("nameserver") ?? "") { text("DNS servers", "nameserver", prompt: "Use host settings") }
                    ForEach(config.keys.filter { $0.hasPrefix("net") }.sorted(), id: \.self) { net in
                        let key = "ipconfig\(net.dropFirst(3))"
                        SettingRow(title: "IP config (\(net))", value: config.string(key) ?? "", monospaced: true) { ipConfig(key) }
                    }
                }
                Section("Advanced") {
                    SettingRow(title: "Custom files", value: config.string("cicustom") ?? "", monospaced: true) {
                        text("Custom cloud-init files", "cicustom", prompt: "user=local:snippets/user.yaml")
                    }
                    SettingRow(title: "Type", value: config.string("citype") ?? "Automatic") {
                        request = EditRequest(title: "Cloud-init type", fields: [FormField(key: "citype", label: "Type",
                                              kind: .choice([.init("nocloud", "NoCloud"), .init("configdrive2", "ConfigDrive2"), .init("opennebula", "OpenNebula")]))],
                                              initial: ["citype": config.string("citype") ?? ""]) { $0.params }
                    }
                }
                Section {
                    Button("Regenerate Image") {
                        Task { await session.run("Regenerate the cloud-init image", .put, path + "/cloudinit") }
                    }
                    .disabled(!hasDrive)
                } footer: {
                    Text("Changes reach the guest the next time it boots with a regenerated image.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sshKeys: String { (config.string("sshkeys") ?? "").removingPercentEncoding ?? "" }

    private func text(_ title: String, _ key: String, prompt: String = "") {
        request = EditRequest(title: title, fields: [FormField(key: key, label: title, prompt: prompt)],
                              initial: [key: config.string(key) ?? ""]) { $0.params }
    }

    private func ipConfig(_ key: String) {
        let current = PropertyString(config.string(key) ?? "")
        request = EditRequest(title: "IP configuration", message: "Use dhcp, or an address with prefix like 192.168.1.50/24.",
                              fields: [FormField(key: "ip", label: "IPv4", prompt: "dhcp or 192.168.1.50/24"),
                                       FormField(key: "gw", label: "IPv4 gateway", prompt: "192.168.1.1"),
                                       FormField(key: "ip6", label: "IPv6", prompt: "dhcp, auto or fd00::50/64"),
                                       FormField(key: "gw6", label: "IPv6 gateway")],
                              initial: ["ip": current["ip"] ?? "", "gw": current["gw"] ?? "", "ip6": current["ip6"] ?? "", "gw6": current["gw6"] ?? ""]) { result in
            let parts = ["ip", "gw", "ip6", "gw6"].compactMap { result[$0].isEmpty ? nil : "\($0)=\(result[$0])" }
            return parts.isEmpty ? ["delete": key] : [key: parts.joined(separator: ",")]
        }
    }
}

// MARK: Container resources, network, DNS

struct CTResourcesView: View {
    @Environment(Session.self) private var session
    let guest: Resource
    let config: JSONObject
    let pending: [JSONObject]
    @State private var request: EditRequest?
    @State private var resizing: String?
    @State private var moving: String?
    @State private var addingMount = false
    @State private var addingDevice = false

    private var path: String { "/nodes/\(guest.node.enc)/lxc/\(guest.vmid)" }

    var body: some View {
        ConfigForm(path: path, config: config, request: $request) {
            Section("Memory") {
                SettingRow(title: "Memory", value: mib("memory", fallback: "512")) {
                    request = EditRequest(title: "Memory", fields: [FormField(key: "memory", label: "Memory (MiB)", kind: .number, required: true),
                                                                    FormField(key: "swap", label: "Swap (MiB)", kind: .number)],
                                          initial: ["memory": config.string("memory") ?? "512", "swap": config.string("swap") ?? "512"]) { $0.params }
                }
                SettingRow(title: "Swap", value: mib("swap", fallback: "512"))
            }
            Section("Processors") {
                SettingRow(title: "Cores", value: config.string("cores") ?? "Unlimited") {
                    request = EditRequest(title: "Processors", fields: [FormField(key: "cores", label: "Cores", kind: .number, prompt: "Unlimited"),
                                                                        FormField(key: "cpulimit", label: "CPU limit", kind: .number, prompt: "Unlimited"),
                                                                        FormField(key: "cpuunits", label: "CPU weight", kind: .number, prompt: "100")],
                                          initial: ["cores": config.string("cores") ?? "", "cpulimit": config.string("cpulimit") ?? "",
                                                    "cpuunits": config.string("cpuunits") ?? ""]) { $0.params }
                }
                SettingRow(title: "CPU limit", value: config.string("cpulimit") ?? "Unlimited")
                SettingRow(title: "CPU weight", value: config.string("cpuunits") ?? "100")
            }
            Section("Disks") {
                ForEach(volumeKeys, id: \.self) { key in
                    let volume = PropertyString(config.string(key) ?? "", defaultKey: "volume")
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text(volume["size"].flatMap(Format.parseSize).map(Format.bytes) ?? "").monospacedDigit().foregroundStyle(.secondary)
                            if !key.hasPrefix("unused") {
                                Button("Resize") { resizing = key }.buttonStyle(.borderless)
                                Button("Move") { moving = key }.buttonStyle(.borderless)
                            }
                            if key != "rootfs" {
                                Button(key.hasPrefix("unused") ? "Delete" : "Detach", role: .destructive) { remove(key) }.buttonStyle(.borderless)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key == "rootfs" ? "Root disk" : (key.hasPrefix("unused") ? "Unused volume (\(key))" : "Mount point \(volume["mp"] ?? "") (\(key))"))
                            Text(volume["volume"] ?? "").font(.caption).fontDesign(.monospaced).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Add Mount Point…") { addingMount = true }
            }
            Section("Devices") {
                ForEach(deviceKeys, id: \.self) { key in
                    let device = PropertyString(config.string(key) ?? "", defaultKey: "path")
                    LabeledContent {
                        Button("Remove", role: .destructive) { removeDevice(key, device["path"] ?? key) }.buttonStyle(.borderless)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device["path"] ?? key).fontDesign(.monospaced)
                            let details = [device["gid"].map { "group \($0)" }, device["uid"].map { "user \($0)" }, device["mode"].map { "mode \($0)" },
                                           device.flag("deny-write") ? "read-only" : nil].compactMap { $0 }
                            if !details.isEmpty { Text(details.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Button("Add Device…") { addingDevice = true }
            }
        }
        .sheet(item: Binding(get: { resizing.map { ResizeTarget(key: $0) } }, set: { resizing = $0?.key })) { target in
            FormSheet(title: "Resize \(target.key)", message: "Volumes can only grow.",
                      fields: [FormField(key: "size", label: "Add (GiB)", kind: .number, prompt: "4", required: true)], submitTitle: "Resize") { result in
                await session.run("Resize \(target.key)", .put, path + "/resize", ["disk": target.key, "size": "+\(result["size"])G"])
            }
        }
        .sheet(item: Binding(get: { moving.map { ResizeTarget(key: $0) } }, set: { moving = $0?.key })) { target in
            Prepared(load: { await session.storageChoices(on: guest.node, content: "rootdir") }) { storages in
                FormSheet(title: "Move \(target.key) to another storage", message: "The container must be stopped unless the storage supports live moves.",
                          fields: [FormField(key: "storage", label: "Target storage", kind: .choice(storages), required: true),
                                   FormField(key: "delete", label: "Delete the source after moving", kind: .toggle)],
                          initial: ["delete": "1"], submitTitle: "Move") { result in
                    var params = result.changed
                    params["volume"] = target.key
                    if params["delete"] == "0" { params["delete"] = nil }
                    return await session.run("Move \(target.key)", .post, path + "/move_volume", params)
                }
            }
        }
        .sheet(isPresented: $addingDevice) {
            FormSheet(title: "Pass through a device", message: "For example /dev/dri/renderD128 for hardware video transcoding. The container sees it from its next start.", fields: [
                FormField(key: "path", label: "Device on the host", prompt: "/dev/dri/renderD128", required: true),
                FormField(key: "gid", label: "Group ID in the container", kind: .number, prompt: "0"),
                FormField(key: "uid", label: "User ID in the container", kind: .number, prompt: "0"),
                FormField(key: "mode", label: "Access mode", prompt: "0660"),
                FormField(key: "deny-write", label: "Read-only", kind: .toggle),
            ], submitTitle: "Add") { result in
                var value = result["path"]
                for key in ["gid", "uid", "mode"] where !result[key].isEmpty { value += ",\(key)=\(result[key])" }
                if result["deny-write"] == "1" { value += ",deny-write=1" }
                return await session.run("Pass through \(result["path"])", .put, path + "/config", [Session.nextKey("dev", in: config, max: 255): value])
            }
        }
        .debugAction("add-ct-device") { addingDevice = true }
        .sheet(isPresented: $addingMount) {
            Prepared(load: { await session.storageChoices(on: guest.node, content: "rootdir") }) { storages in
                FormSheet(title: "Add mount point", fields: [
                    FormField(key: "storage", label: "Storage", kind: .choice(storages), required: true),
                    FormField(key: "size", label: "Size (GiB)", kind: .number, prompt: "8", required: true),
                    FormField(key: "mp", label: "Path in container", prompt: "/mnt/data", required: true),
                    FormField(key: "backup", label: "Include in backups", kind: .toggle),
                    FormField(key: "ro", label: "Read-only", kind: .toggle),
                ], initial: ["storage": storages.first?.value ?? "", "size": "8", "backup": "1"], submitTitle: "Add") { result in
                    var value = "\(result["storage"]):\(result["size"]),mp=\(result["mp"])"
                    if result["backup"] == "1" { value += ",backup=1" }
                    if result["ro"] == "1" { value += ",ro=1" }
                    return await session.run("Add a mount point", .put, path + "/config", [Session.nextKey("mp", in: config, max: 255): value])
                }
            }
        }
    }

    private var deviceKeys: [String] {
        config.keys.filter { $0.hasPrefix("dev") && Int($0.dropFirst(3)) != nil }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func removeDevice(_ key: String, _ device: String) {
        session.confirmation = Confirmation(title: "Remove \(device)?", message: "The container loses access to it from its next start.",
                                            actionTitle: "Remove", destructive: true) {
            await session.run("Remove \(device)", .put, path + "/config", ["delete": key])
        }
    }

    private struct ResizeTarget: Identifiable {
        let key: String
        var id: String { key }
    }

    private var volumeKeys: [String] {
        ["rootfs"] + config.keys.filter { ($0.hasPrefix("mp") || $0.hasPrefix("unused")) && Int($0.drop { !$0.isNumber }) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func mib(_ key: String, fallback: String) -> String {
        Format.bytes((Double(config.string(key) ?? fallback) ?? 0) * 1_048_576)
    }

    private func remove(_ key: String) {
        let unused = key.hasPrefix("unused")
        session.confirmation = Confirmation(title: unused ? "Delete \(key)?" : "Detach \(key)?",
                                            message: unused ? "The volume and its data are deleted from storage." : "The volume is kept as an unused volume.",
                                            actionTitle: unused ? "Delete" : "Detach", destructive: true) {
            await session.run("Remove \(key)", .put, path + "/config", ["delete": key])
        }
    }
}

struct CTNetworkView: View {
    @Environment(Session.self) private var session
    let guest: Resource
    let config: JSONObject
    @State private var editing: NetEdit?
    @State private var selection: String?

    private struct NetEdit: Identifiable {
        let key: String?
        var id: String { key ?? "new" }
    }

    private var path: String { "/nodes/\(guest.node.enc)/lxc/\(guest.vmid)" }

    var body: some View {
        let keys = config.keys.filter { $0.hasPrefix("net") && Int($0.dropFirst(3)) != nil }.sorted()
        VStack(spacing: 0) {
            HStack {
                Button("Add", systemImage: "plus") { editing = NetEdit(key: nil) }
                Button("Edit", systemImage: "pencil") { if let selection { editing = NetEdit(key: selection) } }.disabled(selection == nil)
                Button("Remove", systemImage: "minus") {
                    if let selection {
                        session.confirmation = Confirmation(title: "Remove \(selection)?", message: "The interface disappears from the container.",
                                                            actionTitle: "Remove", destructive: true) {
                            await session.run("Remove \(selection)", .put, path + "/config", ["delete": selection])
                        }
                    }
                }
                .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            Table(keys.map { Row(id: $0, json: ["raw": config.string($0) ?? ""]) }, selection: $selection) {
                TableColumn("ID") { row in Text(row.id).fontDesign(.monospaced) }.width(60)
                TableColumn("Name") { row in Text(field(row, "name")) }.width(70)
                TableColumn("Bridge") { row in Text(field(row, "bridge")) }.width(80)
                TableColumn("IPv4") { row in Text(field(row, "ip")).fontDesign(.monospaced) }.width(min: 100, ideal: 150)
                TableColumn("Gateway") { row in Text(field(row, "gw")).fontDesign(.monospaced) }.width(min: 80, ideal: 120)
                TableColumn("IPv6") { row in Text(field(row, "ip6")).fontDesign(.monospaced) }.width(min: 80, ideal: 140)
                TableColumn("VLAN") { row in Text(field(row, "tag")) }.width(50)
                TableColumn("Firewall") { row in Text(field(row, "firewall") == "1" ? "Yes" : "No") }.width(60)
                TableColumn("MAC") { row in Text(field(row, "hwaddr")).fontDesign(.monospaced).foregroundStyle(.secondary) }.width(min: 100, ideal: 140)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let id = ids.first { editing = NetEdit(key: id) }
            }
        }
        .sheet(item: $editing) { edit in editor(edit.key) }
    }

    private func field(_ row: Row, _ key: String) -> String {
        PropertyString(row["raw"] ?? "")[key] ?? ""
    }

    private func editor(_ key: String?) -> some View {
        let nic = PropertyString(key.flatMap { config.string($0) } ?? "")
        return Prepared(load: { await session.bridgeChoices(on: guest.node) }) { bridges in
            FormSheet(title: key.map { "Network interface \($0)" } ?? "Add network interface", fields: [
                FormField(key: "name", label: "Name", prompt: "eth0", required: true),
                FormField(key: "bridge", label: "Bridge", kind: .choice(bridges), required: true),
                FormField(key: "ip", label: "IPv4", prompt: "dhcp, manual or 192.168.1.20/24"),
                FormField(key: "gw", label: "IPv4 gateway", prompt: "192.168.1.1"),
                FormField(key: "ip6", label: "IPv6", prompt: "auto, dhcp, manual or fd00::20/64"),
                FormField(key: "gw6", label: "IPv6 gateway"),
                FormField(key: "tag", label: "VLAN tag", kind: .number, prompt: "None"),
                FormField(key: "firewall", label: "Firewall", kind: .toggle),
                FormField(key: "rate", label: "Rate limit (MB/s)", kind: .number, prompt: "Unlimited"),
                FormField(key: "mtu", label: "MTU", kind: .number, prompt: "Same as bridge"),
                FormField(key: "hwaddr", label: "MAC address", prompt: "Automatic"),
            ], initial: ["name": nic["name"] ?? "eth\(key == nil ? Session.nextKey("net", in: config).dropFirst(3) : "0")",
                         "bridge": nic["bridge"] ?? bridges.first?.value ?? "vmbr0", "ip": nic["ip"] ?? (key == nil ? "dhcp" : ""),
                         "gw": nic["gw"] ?? "", "ip6": nic["ip6"] ?? "", "gw6": nic["gw6"] ?? "", "tag": nic["tag"] ?? "",
                         "firewall": nic["firewall"] ?? "1", "rate": nic["rate"] ?? "", "mtu": nic["mtu"] ?? "", "hwaddr": nic["hwaddr"] ?? ""],
                      submitTitle: key == nil ? "Add" : "Save") { result in
                var parts = ["name=\(result["name"])", "bridge=\(result["bridge"])"]
                for field in ["ip", "gw", "ip6", "gw6", "tag", "rate", "mtu", "hwaddr"] where !result[field].isEmpty { parts.append("\(field)=\(result[field])") }
                if result["firewall"] == "1" { parts.append("firewall=1") }
                parts.append("type=veth")
                let target = key ?? Session.nextKey("net", in: config)
                return await session.run(key == nil ? "Add a network interface" : "Change \(target)", .put, path + "/config", [target: parts.joined(separator: ",")])
            }
        }
    }
}

struct CTDNSView: View {
    let guest: Resource
    let config: JSONObject
    @State private var request: EditRequest?

    var body: some View {
        ConfigForm(path: "/nodes/\(guest.node.enc)/lxc/\(guest.vmid)", config: config, request: $request) {
            Section {
                SettingRow(title: "Hostname", value: config.string("hostname") ?? "") { edit("Hostname", "hostname", "") }
                SettingRow(title: "DNS domain", value: config.string("searchdomain") ?? "Use host settings") { edit("DNS domain", "searchdomain", "Use host settings") }
                SettingRow(title: "DNS servers", value: config.string("nameserver") ?? "Use host settings") { edit("DNS servers", "nameserver", "Use host settings") }
            } footer: {
                Text("Leave DNS empty to copy the node's settings into the container at start.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func edit(_ title: String, _ key: String, _ prompt: String) {
        request = EditRequest(title: title, fields: [FormField(key: key, label: title, prompt: prompt)],
                              initial: [key: config.string(key) ?? ""]) { $0.params }
    }
}
