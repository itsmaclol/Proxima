import AppKit
import SwiftUI

/// First screen: saved servers, or the form to add one.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SignInFlow?

    var body: some View {
        ZStack {
            Aura(colors: [.orange, .indigo])
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
                    header
                    if let connecting = model.autoConnecting {
                        AutoConnectStatus(server: connecting) { model.cancelAutoConnect() }
                    } else if let flow = editing {
                        SignInForm(flow: flow, canCancel: !model.servers.isEmpty) { editing = nil }
                    } else {
                        serverList
                    }
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 32)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 560)
        .onAppear {
            if model.servers.isEmpty {
                let flow = SignInFlow()
                #if DEBUG
                if let address = ProcessInfo.processInfo.environment["PROXIMA_DEBUG_ADDRESS"] { flow.server.host = address }
                // Visual checks: PROXIMA_DEBUG_TFA=webauthn (or totp,recovery…) shows the second-factor sheet with those methods.
                if let methods = ProcessInfo.processInfo.environment["PROXIMA_DEBUG_TFA"] {
                    flow.step = .secondFactor(challenge: "debug", methods: methods.components(separatedBy: ","))
                }
                #endif
                editing = flow
            }
        }
        .onChange(of: model.servers.isEmpty) { _, empty in if empty { editing = SignInFlow() } }
        .onChange(of: model.lockedServer) { _, server in
            guard let server else { return }
            let flow = SignInFlow(server: server)
            flow.keychainLocked = true
            editing = flow
            model.lockedServer = nil
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)
            Text("Proxima")
                .font(.system(size: 34, weight: .bold))
            Text("Your Proxmox VE servers, at home on the Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var serverList: some View {
        VStack(spacing: 12) {
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    ForEach(model.servers) { server in
                        ServerRow(server: server) {
                            let flow = SignInFlow(server: server)
                            editing = flow
                            // A remembered secret signs in straight away; otherwise the form asks for it.
                            Task {
                                let lookup = await model.savedSecret(for: server)
                                guard model.session == nil, editing === flow, !flow.busy else { return }
                                switch lookup {
                                case .found(let secret):
                                    flow.secret = secret
                                    await flow.connect(model)
                                case .locked: flow.keychainLocked = true
                                case .missing: break
                                }
                            }
                        } remove: {
                            model.remove(server)
                        }
                    }
                }
            }
            Button {
                editing = SignInFlow()
            } label: {
                Label("Add Server", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(.top, 4)
        }
    }
}

private struct ServerRow: View {
    let server: ServerProfile
    let connect: () -> Void
    let remove: () -> Void

    var body: some View {
        Button(action: connect) {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.displayName).font(.headline)
                    Text("\(server.usesToken ? server.tokenID : server.userid) · \(server.host):\(String(server.port))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let last = server.lastConnected {
                    Text(Format.relative(last)).font(.caption).foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .contextMenu {
            Button("Sign In…", action: connect)
            Divider()
            Button("Remove Server", role: .destructive, action: remove)
        }
    }
}

/// Address, credentials and the trust / second-factor steps.
struct SignInForm: View {
    @Environment(AppModel.self) private var model
    @Bindable var flow: SignInFlow
    var canCancel = true
    var onCancel: () -> Void = {}
    @FocusState private var focus: Field?

    private enum Field { case host, user, secret }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if flow.keychainLocked { lockedNotice }
            Form {
                Section {
                    TextField("Address", text: $flow.server.host, prompt: Text("192.168.1.10 or pve.home.lan"))
                        .focused($focus, equals: .host)
                        .onSubmit { Task { await flow.loadRealms() } }
                    TextField("Port", value: $flow.server.port, format: .number.grouping(.never))
                    TextField("Name", text: $flow.server.name, prompt: Text("Optional, e.g. Home lab"))
                }
                Section {
                    Picker("Sign in with", selection: usesToken) {
                        Text("Password").tag(false)
                        Text("API Token").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if !flow.usesOpenID {
                        TextField("Username", text: $flow.server.username, prompt: Text("root"))
                            .focused($focus, equals: .user)
                            .textContentType(.username)
                    }
                    Picker("Realm", selection: $flow.server.realm) {
                        ForEach(flow.realms, id: \.id) { realm in Text(realm.name).tag(realm.id) }
                        if !flow.realms.contains(where: { $0.id == flow.server.realm }) {
                            Text(flow.server.realm).tag(flow.server.realm)
                        }
                    }
                    if flow.usesOpenID {
                        Text("You sign in on \(flow.realmName)'s page, then come back here.")
                            .foregroundStyle(.secondary)
                    } else if flow.server.usesToken {
                        TextField("Token name", text: tokenName, prompt: Text("e.g. proxima"))
                        SecureField("Secret", text: $flow.secret, prompt: Text("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
                            .focused($focus, equals: .secret)
                    } else {
                        SecureField("Password", text: $flow.secret)
                            .focused($focus, equals: .secret)
                            .textContentType(.password)
                    }
                    if !flow.usesOpenID {
                        Toggle("Remember in Keychain", isOn: $flow.remember)
                    }
                } footer: {
                    if flow.server.usesToken {
                        Text("Consoles need a password sign-in; everything else works with a token.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: flow.usesOpenID ? 274 : flow.server.usesToken ? 370 : 322)

            if let error = flow.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: flow.needsLocalNetwork ? "network.slash" : "exclamationmark.circle.fill")
                        .foregroundStyle(flow.needsLocalNetwork ? Color.orange : .red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if flow.needsLocalNetwork {
                        Button("Open Local Network Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.horizontal, 20)
                .transition(.opacity)
            }

            HStack {
                if canCancel { Button("Cancel", action: onCancel).buttonStyle(.glass) }
                Spacer()
                if flow.busy { ProgressView().controlSize(.small) }
                Button {
                    Task { await flow.connect(model) }
                } label: {
                    Text(flow.usesOpenID ? "Continue" : "Connect").frame(minWidth: 80)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.canSubmit)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
        }
        .animation(.smooth(duration: 0.25), value: flow.error)
        .onAppear { focus = flow.server.host.isEmpty ? .host : .secret }
        .task(id: "\(flow.server.host)|\(flow.server.port)") {
            // Wait for a pause in typing, then check the address.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await flow.probe()
        }
        .sheet(isPresented: trustPresented) {
            if case .trust(let presented) = flow.step {
                TrustSheet(host: flow.server.host, presented: presented, connects: !flow.secret.isEmpty) {
                    Task { await flow.trust(presented, model: model) }
                } cancel: { flow.cancelStep() }
            }
        }
        .sheet(item: $flow.openIDPage) { page in
            OpenIDSignInSheet(page: page, realm: flow.realmName, fingerprint: flow.server.fingerprint) { code, state in
                Task { await flow.completeOpenID(code: code, state: state, model: model) }
            } fail: { message in
                flow.failOpenID(message)
            } cancel: {
                flow.openIDPage = nil
            }
        }
        .sheet(isPresented: codePresented) {
            if case .secondFactor(_, let methods) = flow.step {
                SecondFactorSheet(methods: methods, error: flow.error, busy: flow.busy, webInterface: flow.server.host.isEmpty ? nil : flow.server.baseURL) { code, method in
                    Task { await flow.submitCode(code, method: method, model: model) }
                } cancel: { flow.cancelStep() }
            }
        }
    }

    /// A saved secret from an older build: unlock it once in macOS, or just type it.
    private var lockedNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Proxima was updated, so macOS keeps your saved \(flow.server.usesToken ? "secret" : "password") locked to the old version.",
                  systemImage: "lock.fill")
                .fixedSize(horizontal: false, vertical: true)
            Text("Type it below, or unlock it once: macOS asks for your Mac's login password, then choose Always Allow.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Unlock Saved \(flow.server.usesToken ? "Secret" : "Password")…") { Task { await flow.unlockSavedSecret(model) } }
                    .buttonStyle(.glass)
                    .disabled(flow.unlocking || flow.busy)
                if flow.unlocking { ProgressView().controlSize(.small) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 20)
    }

    private var usesToken: Binding<Bool> {
        Binding { flow.server.tokenName != nil } set: { flow.server.tokenName = $0 ? (flow.server.tokenName ?? "") : nil }
    }

    private var tokenName: Binding<String> {
        Binding { flow.server.tokenName ?? "" } set: { flow.server.tokenName = $0 }
    }

    private var trustPresented: Binding<Bool> {
        Binding { if case .trust = flow.step { true } else { false } } set: { if !$0, case .trust = flow.step { flow.cancelStep() } }
    }

    private var codePresented: Binding<Bool> {
        Binding { if case .secondFactor = flow.step { true } else { false } } set: { if !$0, case .secondFactor = flow.step { flow.cancelStep() } }
    }
}

/// Shown the first time we meet a self-signed certificate.
struct TrustSheet: View {
    let host: String
    let presented: CertificateTrust.Presented
    var connects = true
    let trust: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Verify \(host)").font(.title2.bold())
                    Text("This server uses a certificate macOS doesn't know. That's normal for Proxmox.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Certificate").font(.caption).foregroundStyle(.secondary)
                Text(presented.subject.isEmpty ? "Unnamed certificate" : presented.subject).font(.callout.weight(.medium))
                Text("SHA-256 fingerprint").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                Text(presented.fingerprint)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
            Text("To be sure, compare it with the fingerprint of pve-ssl.pem in the Proxmox web interface under the node → System → Certificates. Proxima will only accept this exact certificate from now on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                Button(connects ? "Trust and Connect" : "Trust Certificate", action: trust)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct SecondFactorSheet: View {
    let methods: [String]
    let error: String?
    let busy: Bool
    var webInterface: URL?
    let submit: (String, String) -> Void
    let cancel: () -> Void

    @State private var code = ""
    @State private var method = "totp"
    @FocusState private var focused: Bool

    /// The methods answered by typing a code; security keys need a browser.
    private var codeMethods: [String] { methods.filter { ["totp", "yubico", "recovery"].contains($0) } }
    private var hasSecurityKey: Bool { methods.contains("webauthn") || methods.contains("u2f") }

    var body: some View {
        if codeMethods.isEmpty {
            securityKeyOnly
        } else {
            codeEntry
        }
    }

    /// macOS lets only browsers use security keys with a self-hosted server, so point to the ways that do work.
    private var securityKeyOnly: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("This account signs in with a security key").font(.title2.bold()).multilineTextAlignment(.center)
            Text("macOS only lets web browsers use security keys with a self-hosted server like this one. Sign in with the key in the web interface, and add an authenticator app or recovery keys there to use Proxima. An API token works too.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                Spacer()
                if let webInterface {
                    Button("Open Web Interface") { NSWorkspace.shared.open(webInterface) }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 400)
    }

    private var codeEntry: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Two-factor authentication").font(.title2.bold())
            if codeMethods.count > 1 {
                Picker("Method", selection: $method) {
                    if methods.contains("totp") { Text("Authenticator app").tag("totp") }
                    if methods.contains("yubico") { Text("Yubico OTP").tag("yubico") }
                    if methods.contains("recovery") { Text("Recovery key").tag("recovery") }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            TextField(method == "totp" ? "123456" : "Code", text: $code)
                .font(.system(.title2, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if !code.isEmpty { submit(code, method) } }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if hasSecurityKey {
                Text("Security keys work in the web interface only.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Verify") { submit(code, method) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.isEmpty || busy)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 380)
        .onAppear {
            method = codeMethods.first ?? "totp"
            focused = true
        }
    }
}

/// Shown while Proxima signs in by itself. If the server is slow to answer, it offers to sign in by hand instead.
private struct AutoConnectStatus: View {
    let server: ServerProfile
    let cancel: () -> Void
    @State private var slow = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(server.displayName)…").foregroundStyle(.secondary)
            }
            if slow {
                Text("This is taking a while. You can stop and sign in by hand.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                Button("Sign In Manually", action: cancel)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 20)
        .task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.smooth) { slow = true }
        }
    }
}
