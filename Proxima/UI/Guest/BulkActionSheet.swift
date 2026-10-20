import SwiftUI

/// Start, shut down, suspend or migrate many guests at once, like the web UI's bulk actions: pick the guests and the
/// options, and each node runs one task for its guests.
struct BulkActionSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    /// start, shutdown, suspend or migrate.
    let action: String
    /// Only this node's guests; nil for the whole cluster.
    let node: String?
    /// Guests picked beforehand, e.g. the selection in the Guests table. Empty picks the ones the action fits.
    let preselected: [Int]

    @State private var selected: Set<Int> = []
    @State private var search = ""
    @State private var target = ""
    @State private var timeout = ""
    @State private var forceStop = true
    @State private var withLocalDisks = false
    @State private var workers = ""
    @State private var busy = false

    private var verb: String { ["start": "Start", "shutdown": "Shut Down", "suspend": "Suspend", "migrate": "Migrate"][action] ?? "Run" }

    private var candidates: [Resource] {
        session.guests.filter { guest in
            guard !guest.isTemplate, node == nil || guest.node == node else { return false }
            switch action {
            case "suspend": return guest.kind == .qemu
            case "migrate": return guest.node != target
            default: return true
            }
        }
        .sorted { $0.vmid < $1.vmid }
    }

    private var shown: [Resource] {
        search.isEmpty ? candidates : candidates.filter { "\($0.vmid) \($0.name) \($0.node) \($0.tags.joined(separator: " "))".localizedCaseInsensitiveContains(search) }
    }

    private var chosen: [Resource] { candidates.filter { selected.contains($0.vmid) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(verb) Guests").font(.title2.bold())
                Text(node.map { "Guests on \($0), run as one task." } ?? "Guests across the cluster, one task per node.").foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 8)

            Form {
                if action == "migrate" {
                    Picker("Target node", selection: $target) {
                        ForEach(session.onlineNodes.filter { $0 != node }, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle(isOn: $withLocalDisks) {
                        Text("Move local disks too")
                        Text("Running VMs with disks on local storage copy them live").font(.caption)
                    }
                }
                if action == "shutdown" {
                    LabeledContent("Timeout") {
                        TextField("", text: $timeout, prompt: Text("180"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                    Toggle(isOn: $forceStop) {
                        Text("Stop guests that don't shut down in time")
                    }
                }
                LabeledContent("Parallel jobs") {
                    TextField("", text: $workers, prompt: Text("Datacenter default"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: action == "migrate" || action == "shutdown" ? 170 : 72)

            HStack {
                TextField("Filter", text: $search, prompt: Text("Filter by name, ID, node or tag"))
                    .textFieldStyle(.roundedBorder)
                Button("All") { selected.formUnion(shown.map(\.vmid)) }
                Button("None") { selected.subtract(shown.map(\.vmid)) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 6)

            List(shown) { guest in
                Toggle(isOn: Binding { selected.contains(guest.vmid) } set: { on in
                    if on { selected.insert(guest.vmid) } else { selected.remove(guest.vmid) }
                }) {
                    HStack(spacing: 8) {
                        Circle().fill(color(guest.power)).frame(width: 7, height: 7)
                        Text(String(guest.vmid)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        Text(guest.displayName).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if node == nil { Text(guest.node).foregroundStyle(.secondary) }
                        Text(guest.power.label).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.bordered)
            .padding(.horizontal, 24)
            .overlay {
                if shown.isEmpty { ContentUnavailableView("No guests", systemImage: "square.stack.3d.up.slash") }
            }

            HStack {
                Text("\(chosen.count) of \(candidates.count) selected").foregroundStyle(.secondary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                Button("\(verb) \(chosen.count)") { Task { await run() } }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || chosen.isEmpty || (action == "migrate" && target.isEmpty))
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 640, height: 620)
        .onAppear {
            target = session.onlineNodes.first { $0 != node } ?? ""
            let wanted = Set(preselected)
            selected = Set(candidates.filter { guest in
                if !wanted.isEmpty { return wanted.contains(guest.vmid) }
                switch action {
                case "start": return guest.power != .running
                case "shutdown", "suspend": return guest.power == .running
                default: return node != nil
                }
            }.map(\.vmid))
        }
    }

    private func color(_ power: PowerState) -> Color {
        switch power {
        case .running: .green
        case .paused: .orange
        default: .secondary
        }
    }

    /// One task per node: startall (forced, so guests without start-at-boot start too, as in the web UI), stopall,
    /// suspendall or migrateall, each limited to the picked guests.
    private func run() async {
        busy = true
        defer { busy = false }
        var ok = true
        for (guestNode, guests) in Dictionary(grouping: chosen, by: \.node).sorted(by: { $0.key < $1.key }) {
            var params = ["vms": guests.map { String($0.vmid) }.joined(separator: ",")]
            if let count = Int(workers), count > 0 { params["max-workers"] = String(count) }
            let endpoint: String
            switch action {
            case "start":
                endpoint = "startall"
                params["force"] = "1"
            case "shutdown":
                endpoint = "stopall"
                if let seconds = Int(timeout), seconds > 0 { params["timeout"] = String(seconds) }
                params["force-stop"] = forceStop ? "1" : "0"
            case "suspend":
                endpoint = "suspendall"
            default:
                endpoint = "migrateall"
                params["target"] = target
                if withLocalDisks { params["with-local-disks"] = "1" }
            }
            let what = guests.count == 1 ? guests[0].displayName : "\(guests.count) guests"
            ok = await session.run("\(verb) \(what) on \(guestNode)", .post, "/nodes/\(guestNode.enc)/\(endpoint)", params) && ok
        }
        if ok { dismiss() }
    }
}
