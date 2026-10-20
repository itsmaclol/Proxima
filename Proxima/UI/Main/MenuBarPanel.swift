import AppKit
import SwiftUI

/// The menu bar panel: cluster load at a glance and one-click power for every guest.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = model.session {
                content(session)
            } else {
                Label("Not signed in", systemImage: "server.rack").font(.headline)
                Text("Open Proxima to connect to a Proxmox server.").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Open Proxima") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder private func content(_ session: Session) -> some View {
        let online = session.nodes.filter(\.isOnline)
        let cores = online.reduce(0) { $0 + $1.maxcpu }
        let cpu = cores > 0 ? online.reduce(0) { $0 + $1.cpu * $1.maxcpu } / cores : 0
        let memTotal = online.reduce(Int64(0)) { $0 + $1.maxmem }
        let memory = memTotal > 0 ? Double(online.reduce(Int64(0)) { $0 + $1.mem }) / Double(memTotal) : 0
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.clusterName ?? session.server.displayName).font(.headline)
                Text("\(online.count) of \(Format.count(session.nodes.count, "node")) online").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session.runningTaskCount > 0 {
                Label("\(session.runningTaskCount)", systemImage: "gearshape.2").font(.caption).foregroundStyle(.blue)
            }
        }
        HStack(spacing: 14) {
            Meter(title: "CPU", fraction: cpu, color: Theme.cpu)
            Meter(title: "Memory", fraction: memory, color: Theme.memory)
        }
        ScrollView {
            VStack(spacing: 2) {
                ForEach(session.guests.filter { !$0.isTemplate }.sorted { ($0.statusRank, $0.vmid) < ($1.statusRank, $1.vmid) }) { guest in
                    GuestMenuRow(guest: guest, actions: GuestActions(session: session, guest: guest)) {
                        session.selection = .guest(guest.vmid)
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                }
            }
        }
        .frame(maxHeight: 320)
    }
}

private struct GuestMenuRow: View {
    let guest: Resource
    let actions: GuestActions
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusGlyph(power: guest.power, size: 8)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(guest.displayName).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: "\(guest.kind?.short ?? "") \(guest.vmid) on \(guest.node)").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if guest.power == .running {
                Text(Format.percent(guest.cpu)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Group {
                switch guest.power {
                case .stopped:
                    Button { Task { await actions.power("start") } } label: { Image(systemName: "play.fill") }.help("Start")
                case .running:
                    Button { Task { await actions.power("shutdown") } } label: { Image(systemName: "power") }.help("Shut down")
                case .paused:
                    Button { Task { await actions.power("resume") } } label: { Image(systemName: "play.fill") }.help("Resume")
                case .unknown:
                    EmptyView()
                }
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}
