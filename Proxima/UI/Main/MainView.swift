import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let session = model.session {
                MainView().environment(session)
            } else {
                WelcomeView()
            }
        }
        .task { await model.restoreLastSession() }
    }
}

struct MainView: View {
    @Environment(Session.self) private var session

    var body: some View {
        @Bindable var session = session
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 420)
        } detail: {
            DetailView(place: session.selection ?? .overview)
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
                .overlay(alignment: .bottom) { ActivityPill() }
                .overlay(alignment: .top) {
                    if let problem = session.problem {
                        ConnectionBanner(message: problem)
                    }
                }
        }
        .searchable(text: $session.search, placement: .sidebar, prompt: "Guests, tags, nodes")
        .navigationTitle(session.server.displayName)
        // A SwiftUI alert waits until an open sheet closes, and most failures happen inside a sheet (a wizard, a form),
        // which then looks frozen. AppKit can stack the alert on top of whatever sheet is showing.
        .onChange(of: session.alert?.id) {
            guard let item = session.alert else { return }
            Self.present(item) { if session.alert?.id == item.id { session.alert = nil } }
        }
        .confirmationDialog(session.confirmation?.title ?? "", isPresented: Binding { session.confirmation != nil } set: { if !$0 { session.confirmation = nil } },
                            presenting: session.confirmation) { confirmation in
            Button(confirmation.actionTitle, role: confirmation.destructive ? .destructive : nil) {
                Task { await confirmation.action() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .sheet(item: $session.sheet) { route in
            SheetHost(route: route).environment(session)
        }
        .sheet(isPresented: $session.needsReauth) {
            ReauthSheet().environment(session)
        }
    }
}

/// Routes the sidebar selection to its page.
struct DetailView: View {
    @Environment(Session.self) private var session
    let place: Place

    var body: some View {
        switch place {
        case .overview: OverviewView()
        case .guests: GuestsTableView()
        case .tasks: TasksView()
        case .node(let name): NodeView(name: name).id(name)
        case .guest(let vmid):
            if let guest = session.guest(vmid) {
                GuestView(vmid: vmid, kind: guest.kind ?? .qemu).id(vmid)
            } else if session.loaded {
                ContentUnavailableView("Guest \(String(vmid)) is gone", systemImage: "questionmark.square.dashed",
                                       description: Text("It was destroyed or moved to a cluster you're not signed in to."))
            } else {
                ProgressView().controlSize(.small)
            }
        case .storage(let node, let id): StorageView(node: node, storage: id).id("\(node)/\(id)")
        case .pool(let id): PoolView(poolid: id).id(id)
        case .backups: BackupJobsView()
        case .replication: ReplicationView()
        case .storageConfig: StorageConfigView()
        case .permissions: PermissionsView()
        case .ha: HAView()
        case .firewall: FirewallView(scope: .datacenter)
        case .sdn: SDNView()
        case .options: DatacenterOptionsView()
        }
    }
}

private struct ConnectionBanner: View {
    let message: String

    var body: some View {
        Label("Lost contact with the server: \(message)", systemImage: "wifi.exclamationmark")
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(.orange.opacity(0.3)), in: .capsule)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: Activity

/// A floating glass capsule following the tasks started from this window.
struct ActivityPill: View {
    @Environment(Session.self) private var session
    @State private var showingList = false
    @State private var logTarget: Activity?
    /// A finished, successful task stays in view for a moment, then the pill steps aside.
    @State private var settled: String?

    var body: some View {
        let current = session.activities.first
        let visible = current.map { activity in
            showingList || activity.state != .succeeded || settled != activity.id
        } ?? false
        ZStack {
            if let current, visible {
                Button { showingList.toggle() } label: {
                    HStack(spacing: 10) {
                        icon(for: current.state)
                        Text(current.title).lineLimit(1)
                        if case .failed = current.state { Text("Failed").foregroundStyle(.red) }
                        if session.activities.count > 1 {
                            Text("+\(session.activities.count - 1)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .popover(isPresented: $showingList, arrowEdge: .top) {
                    ActivityList(logTarget: $logTarget).environment(session)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(.bottom, 16)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.activities)
        .animation(.easeOut(duration: 0.3), value: visible)
        .task(id: current.map { "\($0.id)-\($0.state == .succeeded)" }) {
            guard let current, current.state == .succeeded else { return }
            try? await Task.sleep(for: .seconds(6))
            settled = current.id
        }
        .sheet(item: $logTarget) { activity in
            TaskLogSheet(upid: activity.upid, node: activity.node, title: activity.title)
                .environment(session)
        }
    }

    @ViewBuilder private func icon(for state: Activity.State) -> some View {
        switch state {
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).transition(.symbolEffect(.drawOn))
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

private struct ActivityList: View {
    @Environment(Session.self) private var session
    @Binding var logTarget: Activity?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(session.activities) { activity in
                HStack(spacing: 10) {
                    switch activity.state {
                    case .running: ProgressView().controlSize(.small)
                    case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.title).font(.callout.weight(.medium))
                        if case .failed(let message) = activity.state {
                            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                        } else {
                            Text("\(activity.node) · started \(Format.relative(activity.started))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Log") { logTarget = activity }
                        .buttonStyle(.borderless)
                    if activity.state != .running {
                        Button { session.dismissActivity(activity.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Dismiss")
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                Divider().opacity(activity.id == session.activities.last?.id ? 0 : 1)
            }
        }
        .frame(width: 380)
        .padding(.vertical, 4)
    }
}

// MARK: Session expiry

/// Asks for the password again when the two-hour ticket has expired.
struct ReauthSheet: View {
    @Environment(Session.self) private var session
    @Environment(AppModel.self) private var model
    @State private var secret = ""
    @State private var code = ""
    @State private var challenge: String?
    @State private var methods: [String] = []
    @State private var method = "totp"
    @State private var error: String?
    @State private var busy = false

    private var codeMethods: [String] { methods.filter { ["totp", "yubico", "recovery"].contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Sign in again", systemImage: "person.badge.key").font(.title2.bold())
            Text("Your session on \(session.server.displayName) expired. Enter the \(session.usesToken ? "token secret" : "password") for \(session.userid) to continue where you left off.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if challenge == nil {
                SecureField(session.usesToken ? "Secret" : "Password", text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await submit() } }
            } else if codeMethods.isEmpty {
                Text("This account's second factor is a security key, which macOS lets only browsers use with a self-hosted server. Sign out, then sign in with an authenticator code, a recovery key or an API token.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if codeMethods.count > 1 {
                    Picker("Method", selection: $method) {
                        ForEach(codeMethods, id: \.self) { method in
                            Text(["totp": "Authenticator app", "yubico": "Yubico OTP", "recovery": "Recovery key"][method] ?? method).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                TextField(method == "totp" ? "Authenticator code" : "Code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { Task { await submit() } }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Sign Out") { model.signOut() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Continue") { Task { await submit() } }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (challenge == nil ? secret.isEmpty : code.isEmpty || codeMethods.isEmpty))
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            if let challenge {
                try await session.client.completeSecondFactor(challenge: challenge, response: "\(method):\(code)")
            } else if session.usesToken {
                session.client.useToken(secret: secret)
                _ = try await session.client.get("/version")
            } else if case .needsSecondFactor(let next, let offered) = try await session.client.login(password: secret) {
                challenge = next
                methods = offered
                method = codeMethods.first ?? "totp"
                return
            }
            session.needsReauth = false
            await session.refresh()
        } catch {
            self.error = (error as? PVEError)?.isAuthenticationFailure == true ? "That didn't work. Check and try again." : error.localizedDescription
        }
    }
}

extension MainView {
    /// Shows an alert on the top-most sheet of the session's window, or on the window itself.
    static func present(_ item: AlertItem, done: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = item.title
        alert.informativeText = item.message
        alert.addButton(withTitle: "OK")
        let root = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.canBecomeMain }
        guard var window = root else {
            alert.runModal()
            return done()
        }
        while let sheet = window.attachedSheet { window = sheet }
        alert.beginSheetModal(for: window) { _ in done() }
    }
}
