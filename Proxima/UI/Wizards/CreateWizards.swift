import SwiftUI

struct WizardStep: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let fields: [FormField]
    var note: String?
}

/// Stepped sheet: a glass step bar, one step's fields at a time, then a review page.
struct WizardSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let steps: [WizardStep]
    @Binding var values: [String: String]
    let review: [(String, String)]
    let create: () async -> Bool

    @State private var index = 0
    @State private var busy = false
    @Namespace private var namespace

    private var isReview: Bool { index == steps.count }

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top], 24)
            stepBar.padding(.vertical, 14)
                .onAppear {
                    #if DEBUG
                    // Visual checks: PROXIMA_DEBUG_STEP opens the wizard on that step (the last one is Review).
                    if let step = ProcessInfo.processInfo.environment["PROXIMA_DEBUG_STEP"].flatMap(Int.init) { index = min(max(step, 0), steps.count) }
                    #endif
                }
            Group {
                if isReview {
                    Form {
                        Section("Review") {
                            ForEach(Array(review.enumerated()), id: \.offset) { _, row in
                                LabeledContent(row.0) { Text(row.1.isEmpty ? "–" : row.1).textSelection(.enabled).multilineTextAlignment(.trailing) }
                            }
                        }
                        Section {
                            FieldControl(field: FormField(key: "start", label: "Start after creating", kind: .toggle), values: $values)
                        }
                    }
                } else {
                    Form {
                        Section {
                            ForEach(steps[index].fields) { FieldControl(field: $0, values: $values) }
                        } footer: {
                            if let note = steps[index].note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 400)
            HStack {
                if let missing { Text("\(missing) is required").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                if index > 0 { Button("Back") { index -= 1 } }
                if isReview {
                    Button("Create") {
                        Task {
                            busy = true
                            if await create() { dismiss() }
                            busy = false
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
                } else {
                    Button("Next") { index += 1 }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(missing != nil)
                }
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 640)
    }

    private var missing: String? {
        guard !isReview else { return nil }
        return steps[index].fields.first { $0.required && (values[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }?.label
    }

    private var stepBar: some View {
        HStack(spacing: 2) {
            ForEach(Array((steps.map { ($0.title, $0.symbol) } + [("Review", "checkmark.circle")]).enumerated()), id: \.offset) { position, step in
                let selected = position == index
                Button {
                    if position < index || (position > index && missing == nil && position <= index + 1) { index = position }
                } label: {
                    Label(step.0, systemImage: position < index ? "checkmark" : step.1)
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? .primary : (position < index ? .secondary : .tertiary))
                .background {
                    if selected { Capsule().fill(Color.primary.opacity(0.1)).matchedGeometryEffect(id: "step", in: namespace) }
                }
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: index)
    }
}

// MARK: New VM

struct CreateVMWizard: View {
    @Environment(Session.self) private var session
    let initialNode: String?
    @State private var values: [String: String] = [:]
    @State private var choices: [String: [FormField.Choice]] = [:]

    var body: some View {
        let nodes = session.onlineNodes.map { FormField.Choice($0) }
        let pools = session.pools.map { FormField.Choice($0) }
        WizardSheet(title: "New virtual machine", steps: [
            WizardStep(id: "general", title: "General", symbol: "info.circle", fields: [
                FormField(key: "node", label: "Node", kind: .choice(nodes), required: true),
                FormField(key: "vmid", label: "VM ID", kind: .number, required: true),
                FormField(key: "name", label: "Name", prompt: "web-server"),
                FormField(key: "pool", label: "Resource pool", kind: .choice(pools)),
                FormField(key: "onboot", label: "Start at boot", kind: .toggle),
                FormField(key: "tags", label: "Tags", prompt: "prod;web"),
            ]),
            WizardStep(id: "os", title: "OS", symbol: "opticaldisc", fields: [
                FormField(key: "iso", label: "ISO image", kind: .choice([.init("none", "Don't use any media")] + (choices["iso"] ?? [])), required: true),
                FormField(key: "ostype", label: "Guest OS", kind: .choice(Choices.ostypes), required: true),
            ], note: "Upload ISO images in a storage's ISO Images tab."),
            WizardStep(id: "system", title: "System", symbol: "memorychip", fields: [
                FormField(key: "machine", label: "Machine", kind: .choice(Choices.machine), required: true),
                FormField(key: "bios", label: "BIOS", kind: .choice(Choices.bios), required: true),
                FormField(key: "efistorage", label: "EFI disk storage", kind: .choice(choices["images"] ?? []), help: "Needed for OVMF (UEFI)"),
                FormField(key: "tpm", label: "Add TPM (Windows 11)", kind: .toggle),
                FormField(key: "scsihw", label: "SCSI controller", kind: .choice(Choices.scsihw), required: true),
                FormField(key: "agent", label: "QEMU guest agent", kind: .toggle),
            ]),
            WizardStep(id: "disks", title: "Disks", symbol: "internaldrive", fields: [
                FormField(key: "nodisk", label: "No disk", kind: .toggle),
                FormField(key: "bus", label: "Bus", kind: .choice(Choices.buses), required: true),
                FormField(key: "storage", label: "Storage", kind: .choice(choices["images"] ?? []), required: true),
                FormField(key: "size", label: "Disk size (GiB)", kind: .number, required: true),
                FormField(key: "discard", label: "Discard", kind: .toggle),
                FormField(key: "ssd", label: "SSD emulation", kind: .toggle),
                FormField(key: "iothread", label: "IO thread", kind: .toggle),
            ]),
            WizardStep(id: "cpu", title: "CPU", symbol: "cpu", fields: [
                FormField(key: "sockets", label: "Sockets", kind: .number, required: true),
                FormField(key: "cores", label: "Cores", kind: .number, required: true),
                FormField(key: "cpu", label: "Type", kind: .choice(choices["cpu"] ?? Choices.cpuTypes), required: true),
            ]),
            WizardStep(id: "memory", title: "Memory", symbol: "memorychip.fill", fields: [
                FormField(key: "memory", label: "Memory (MiB)", kind: .number, required: true),
                FormField(key: "balloon", label: "Minimum memory (MiB)", kind: .number, prompt: "Same as memory"),
            ]),
            WizardStep(id: "network", title: "Network", symbol: "network", fields: [
                FormField(key: "nonet", label: "No network device", kind: .toggle),
                FormField(key: "bridge", label: "Bridge", kind: .choice(choices["bridges"] ?? [])),
                FormField(key: "model", label: "Model", kind: .choice(Choices.nicModels), required: true),
                FormField(key: "tag", label: "VLAN tag", kind: .number, prompt: "None"),
                FormField(key: "firewall", label: "Firewall", kind: .toggle),
            ]),
        ], values: $values, review: review, create: create)
        .task(id: values["node"]) { await loadChoices() }
        .onAppear { if values.isEmpty { values = defaults } }
    }

    private var defaults: [String: String] {
        ["node": initialNode ?? session.onlineNodes.first ?? "", "iso": "none", "ostype": "l26", "machine": "q35", "bios": "seabios",
         "scsihw": "virtio-scsi-single", "agent": "1", "bus": "scsi", "size": "32", "discard": "1", "iothread": "1",
         "sockets": "1", "cores": "2", "cpu": "x86-64-v2-AES", "memory": "2048", "model": "virtio", "firewall": "1", "start": "0"]
    }

    private func loadChoices() async {
        guard let node = values["node"], !node.isEmpty else { return }
        let images = await session.storageChoices(on: node, content: "images")
        let isos = await session.volumeChoices(on: node, content: "iso")
        let bridges = await session.bridgeChoices(on: node)
        let cpus = await session.cpuChoices(on: node)
        choices = ["images": images, "iso": isos, "bridges": bridges, "cpu": cpus]
        if values["vmid"]?.isEmpty ?? true, let next = (try? await session.client.get("/cluster/nextid")).flatMap({ jsonInt($0) }) { values["vmid"] = String(next) }
        if !(choices["images"] ?? []).contains(where: { $0.value == values["storage"] }) { values["storage"] = choices["images"]?.first?.value }
        if !(choices["images"] ?? []).contains(where: { $0.value == values["efistorage"] }) { values["efistorage"] = choices["images"]?.first?.value }
        if !(choices["bridges"] ?? []).contains(where: { $0.value == values["bridge"] }) { values["bridge"] = choices["bridges"]?.first?.value }
    }

    private func value(_ key: String) -> String { (values[key] ?? "").trimmingCharacters(in: .whitespaces) }

    private var review: [(String, String)] {
        [("Node", value("node")), ("VM ID", value("vmid")), ("Name", value("name").isEmpty ? "–" : value("name")),
         ("Guest OS", Theme.ostypeLabel(value("ostype")) ?? value("ostype")),
         ("ISO image", value("iso") == "none" ? "None" : (value("iso").split(separator: "/").last.map(String.init) ?? value("iso"))),
         ("Firmware", value("bios") == "ovmf" ? "OVMF (UEFI) on \(value("machine"))" : "SeaBIOS on \(value("machine"))"),
         ("Disk", value("nodisk") == "1" ? "None" : "\(value("size")) GiB on \(value("storage")) (\(value("bus")))"),
         ("CPU", "\(value("sockets")) × \(value("cores")) cores, \(value("cpu"))"),
         ("Memory", Format.bytes((Double(value("memory")) ?? 0) * 1_048_576)),
         ("Network", value("nonet") == "1" ? "None" : "\(value("model")) on \(value("bridge"))\(value("tag").isEmpty ? "" : ", VLAN \(value("tag"))")")]
    }

    private func create() async -> Bool {
        let node = value("node")
        let bus = value("bus")
        let disk = "\(bus)0"
        var diskSpec = "\(value("storage")):\(value("size"))"
        if value("discard") == "1" { diskSpec += ",discard=on" }
        if value("iothread") == "1", ["scsi", "virtio"].contains(bus) { diskSpec += ",iothread=1" }
        if value("ssd") == "1", bus != "virtio" { diskSpec += ",ssd=1" }
        var params: [String: String] = [
            "vmid": value("vmid"), "ostype": value("ostype"), "machine": value("machine"), "bios": value("bios"),
            "scsihw": value("scsihw"), "sockets": value("sockets"), "cores": value("cores"), "cpu": value("cpu"),
            "memory": value("memory"), "ide2": "\(value("iso")),media=cdrom",
            "agent": value("agent") == "1" ? "1" : "0", "start": value("start") == "1" ? "1" : "0",
            "boot": "order=" + [value("nodisk") == "1" ? nil : disk, "ide2", value("nonet") == "1" ? nil : "net0"].compactMap { $0 }.joined(separator: ";"),
        ]
        // Like the web UI, a VM can start without disks (e.g. to boot from the network or to add disks later).
        if value("nodisk") != "1" { params[disk] = diskSpec }
        for key in ["name", "pool", "tags", "balloon"] where !value(key).isEmpty { params[key] = value(key) }
        if value("onboot") == "1" { params["onboot"] = "1" }
        if value("bios") == "ovmf", !value("efistorage").isEmpty { params["efidisk0"] = "\(value("efistorage")):1,efitype=4m,pre-enrolled-keys=1" }
        if value("tpm") == "1", !value("efistorage").isEmpty { params["tpmstate0"] = "\(value("efistorage")):1,version=v2.0" }
        if value("nonet") != "1" {
            var net = "\(value("model")),bridge=\(value("bridge"))"
            if value("firewall") == "1" { net += ",firewall=1" }
            if !value("tag").isEmpty { net += ",tag=\(value("tag"))" }
            params["net0"] = net
        }
        let ok = await session.run("Create VM \(value("vmid"))", .post, "/nodes/\(node.enc)/qemu", params)
        if ok, let vmid = Int(value("vmid")) { session.selection = .guest(vmid) }
        return ok
    }
}

// MARK: New container

struct CreateCTWizard: View {
    @Environment(Session.self) private var session
    let initialNode: String?
    @State private var values: [String: String] = [:]
    @State private var choices: [String: [FormField.Choice]] = [:]

    var body: some View {
        let nodes = session.onlineNodes.map { FormField.Choice($0) }
        let pools = session.pools.map { FormField.Choice($0) }
        WizardSheet(title: "New container", steps: [
            WizardStep(id: "general", title: "General", symbol: "info.circle", fields: [
                FormField(key: "node", label: "Node", kind: .choice(nodes), required: true),
                FormField(key: "vmid", label: "CT ID", kind: .number, required: true),
                FormField(key: "hostname", label: "Hostname", prompt: "pihole", required: true),
                FormField(key: "unprivileged", label: "Unprivileged container", kind: .toggle, help: "Safer: root in the container isn't root on the host"),
                FormField(key: "nesting", label: "Nesting", kind: .toggle, help: "Needed for systemd 255+ and Docker"),
                FormField(key: "password", label: "Root password", kind: .secure),
                FormField(key: "ssh-public-keys", label: "SSH public key", kind: .multiline),
                FormField(key: "pool", label: "Resource pool", kind: .choice(pools)),
                FormField(key: "tags", label: "Tags", prompt: "dns;home"),
            ], note: "Set a password, an SSH key, or both."),
            WizardStep(id: "template", title: "Template", symbol: "shippingbox", fields: [
                FormField(key: "ostemplate", label: "Template", kind: .choice(choices["vztmpl"] ?? []), required: true),
            ], note: (choices["vztmpl"] ?? []).isEmpty ? "No templates downloaded yet. Get one from a storage's CT Templates tab." : nil),
            WizardStep(id: "disks", title: "Disks", symbol: "internaldrive", fields: [
                FormField(key: "storage", label: "Storage", kind: .choice(choices["rootdir"] ?? []), required: true),
                FormField(key: "size", label: "Disk size (GiB)", kind: .number, required: true),
            ]),
            WizardStep(id: "cpu", title: "CPU", symbol: "cpu", fields: [
                FormField(key: "cores", label: "Cores", kind: .number, required: true),
            ]),
            WizardStep(id: "memory", title: "Memory", symbol: "memorychip.fill", fields: [
                FormField(key: "memory", label: "Memory (MiB)", kind: .number, required: true),
                FormField(key: "swap", label: "Swap (MiB)", kind: .number, required: true),
            ]),
            WizardStep(id: "network", title: "Network", symbol: "network", fields: [
                FormField(key: "netname", label: "Name", required: true),
                FormField(key: "bridge", label: "Bridge", kind: .choice(choices["bridges"] ?? []), required: true),
                FormField(key: "ip", label: "IPv4", prompt: "dhcp or 192.168.1.20/24", required: true),
                FormField(key: "gw", label: "IPv4 gateway", prompt: "Only for a static address"),
                FormField(key: "ip6", label: "IPv6", prompt: "auto, dhcp or fd00::20/64"),
                FormField(key: "tag", label: "VLAN tag", kind: .number, prompt: "None"),
                FormField(key: "firewall", label: "Firewall", kind: .toggle),
            ]),
            WizardStep(id: "dns", title: "DNS", symbol: "globe", fields: [
                FormField(key: "searchdomain", label: "DNS domain", prompt: "Use host settings"),
                FormField(key: "nameserver", label: "DNS servers", prompt: "Use host settings"),
            ]),
        ], values: $values, review: review, create: create)
        .task(id: values["node"]) { await loadChoices() }
        .onAppear { if values.isEmpty { values = defaults } }
    }

    private var defaults: [String: String] {
        ["node": initialNode ?? session.onlineNodes.first ?? "", "unprivileged": "1", "nesting": "1", "size": "8", "cores": "1",
         "memory": "512", "swap": "512", "netname": "eth0", "ip": "dhcp", "firewall": "1", "start": "1"]
    }

    private func loadChoices() async {
        guard let node = values["node"], !node.isEmpty else { return }
        let rootdir = await session.storageChoices(on: node, content: "rootdir")
        let templates = await session.volumeChoices(on: node, content: "vztmpl")
        let bridges = await session.bridgeChoices(on: node)
        choices = ["rootdir": rootdir, "vztmpl": templates, "bridges": bridges]
        if values["vmid"]?.isEmpty ?? true, let next = (try? await session.client.get("/cluster/nextid")).flatMap({ jsonInt($0) }) { values["vmid"] = String(next) }
        if !(choices["rootdir"] ?? []).contains(where: { $0.value == values["storage"] }) { values["storage"] = choices["rootdir"]?.first?.value }
        if !(choices["vztmpl"] ?? []).contains(where: { $0.value == values["ostemplate"] }) { values["ostemplate"] = choices["vztmpl"]?.first?.value }
        if !(choices["bridges"] ?? []).contains(where: { $0.value == values["bridge"] }) { values["bridge"] = choices["bridges"]?.first?.value }
    }

    private func value(_ key: String) -> String { (values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    private var review: [(String, String)] {
        [("Node", value("node")), ("CT ID", value("vmid")), ("Hostname", value("hostname")),
         ("Template", value("ostemplate").split(separator: "/").last.map(String.init) ?? value("ostemplate")),
         ("Unprivileged", value("unprivileged") == "1" ? "Yes" : "No"),
         ("Login", [value("password").isEmpty ? nil : "Password", value("ssh-public-keys").isEmpty ? nil : "SSH key"].compactMap { $0 }.joined(separator: " and ")),
         ("Disk", "\(value("size")) GiB on \(value("storage"))"), ("CPU", "\(value("cores")) core\(value("cores") == "1" ? "" : "s")"),
         ("Memory", "\(Format.bytes((Double(value("memory")) ?? 0) * 1_048_576)) + \(Format.bytes((Double(value("swap")) ?? 0) * 1_048_576)) swap"),
         ("Network", "\(value("netname")) on \(value("bridge")), \(value("ip"))\(value("tag").isEmpty ? "" : ", VLAN \(value("tag"))")")]
    }

    private func create() async -> Bool {
        guard !value("password").isEmpty || !value("ssh-public-keys").isEmpty else {
            session.alert = AlertItem(title: "Add a way to log in", message: "Set a root password or an SSH public key in the General step.")
            return false
        }
        var net = "name=\(value("netname")),bridge=\(value("bridge")),ip=\(value("ip"))"
        if !value("gw").isEmpty { net += ",gw=\(value("gw"))" }
        if !value("ip6").isEmpty { net += ",ip6=\(value("ip6"))" }
        if !value("tag").isEmpty { net += ",tag=\(value("tag"))" }
        if value("firewall") == "1" { net += ",firewall=1" }
        var params: [String: String] = [
            "vmid": value("vmid"), "hostname": value("hostname"), "ostemplate": value("ostemplate"),
            "rootfs": "\(value("storage")):\(value("size"))", "cores": value("cores"), "memory": value("memory"), "swap": value("swap"),
            "net0": net, "unprivileged": value("unprivileged") == "1" ? "1" : "0", "start": value("start") == "1" ? "1" : "0",
        ]
        if value("nesting") == "1" { params["features"] = "nesting=1" }
        for key in ["password", "ssh-public-keys", "pool", "tags", "searchdomain", "nameserver"] where !value(key).isEmpty { params[key] = value(key) }
        let ok = await session.run("Create CT \(value("vmid"))", .post, "/nodes/\(value("node").enc)/lxc", params)
        if ok, let vmid = Int(value("vmid")) { session.selection = .guest(vmid) }
        return ok
    }
}
