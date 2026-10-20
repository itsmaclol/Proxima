import SwiftUI

/// Proxima → Settings: saved servers and their stored secrets and certificates.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: ServerProfile.ID?
    @AppStorage("menuBarExtra") private var showsMenuBarExtra = true

    var body: some View {
        TabView {
            Tab("Servers", systemImage: "server.rack") { servers }
            Tab("General", systemImage: "gearshape") {
                Form {
                    Toggle("Show Proxima in the menu bar", isOn: $showsMenuBarExtra)
                    Text("The menu bar panel shows cluster load and lets you start or shut down guests without opening the window.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
                .frame(width: 620, height: 200)
            }
        }
    }

    private var servers: some View {
        let selected = model.servers.first { $0.id == selection }
        return HStack(spacing: 0) {
            List(model.servers, selection: $selection) { server in
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.displayName).fontWeight(.medium)
                    Text("\(server.host):\(String(server.port))").font(.caption).foregroundStyle(.secondary)
                }
                .tag(server.id)
            }
            .frame(width: 200)
            Divider()
            Group {
                if let selected {
                    ServerSettings(server: selected)
                } else {
                    ContentUnavailableView("Pick a server", systemImage: "server.rack")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 360)
        .onAppear { selection = selection ?? model.servers.first?.id }
    }
}

private struct ServerSettings: View {
    @Environment(AppModel.self) private var model
    let server: ServerProfile
    @State private var name = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .onSubmit { var copy = server; copy.name = name; model.save(copy) }
            LabeledContent("Address", value: "\(server.host):\(String(server.port))")
            LabeledContent("Signs in as", value: server.usesToken ? server.tokenID : server.userid)
            LabeledContent("Trusted certificate") {
                Text(server.fingerprint.map { String($0.prefix(23)) + "…" } ?? "System trust").font(.system(.caption, design: .monospaced))
            }
            HStack {
                Button("Forget Saved Secret") { Keychain.delete(account: server.keychainAccount) }
                Button("Forget Certificate") { var copy = server; copy.fingerprint = nil; model.save(copy) }
                    .help("You'll be asked to verify the certificate again next time")
            }
            Button("Remove Server", role: .destructive) { model.remove(server) }
                .disabled(model.session?.server.id == server.id)
        }
        .formStyle(.grouped)
        .onAppear { name = server.name }
        .onChange(of: server.id) { name = server.name }
    }
}
