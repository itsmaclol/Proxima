import SwiftUI
import WebKit

/// What a console window shows: a VM (noVNC), a container or node shell (xterm.js), an upgrade run,
/// or (kind "cmd") a command such as `ceph_install` with NUL-separated options.
nonisolated struct ConsoleTarget: Codable, Hashable {
    let kind: String
    let node: String
    let vmid: Int?
    let name: String
    var cmd: String?
    var cmdOptions: String?

    init(kind: String, node: String, vmid: Int?, name: String, cmd: String? = nil, cmdOptions: String? = nil) {
        self.kind = kind
        self.node = node
        self.vmid = vmid
        self.name = name
        self.cmd = cmd
        self.cmdOptions = cmdOptions
    }

    init(guest: Resource) {
        self.init(kind: guest.kind == .qemu ? "kvm" : "lxc", node: guest.node, vmid: guest.vmid, name: guest.displayName)
    }

    /// The same console page the Proxmox web UI opens in its pop-up windows.
    func url(base: URL) -> URL? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/"
        var items = [URLQueryItem(name: "console", value: kind), URLQueryItem(name: "node", value: node)]
        items.append(URLQueryItem(name: kind == "kvm" ? "novnc" : "xtermjs", value: "1"))
        if let vmid {
            items.append(URLQueryItem(name: "vmid", value: String(vmid)))
            items.append(URLQueryItem(name: "vmname", value: name))
        }
        if kind == "kvm" { items.append(URLQueryItem(name: "resize", value: "scale")) }
        items.append(URLQueryItem(name: "cmd", value: cmd ?? ""))
        if let cmdOptions { items.append(URLQueryItem(name: "cmd-opts", value: cmdOptions)) }
        components?.queryItems = items
        return components?.url
    }
}

/// Embeds Proxmox's own console page with the session ticket as its cookie.
struct ConsoleView: View {
    @Environment(Session.self) private var session
    let target: ConsoleTarget
    @State private var page: WebPage?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if session.usesToken {
                ContentUnavailableView {
                    Label("Consoles need a password sign-in", systemImage: "terminal")
                } description: {
                    Text("Proxmox only opens consoles for password sessions, not API tokens. Sign in with a password to use the console here.")
                }
            } else if let error {
                ContentUnavailableView {
                    Label("The console didn't open", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { attempt += 1 }
                }
            } else if let page {
                WebView(page)
                    .webViewContentBackground(.hidden)
                    .background(Color.black)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(target.hashValue)-\(attempt)") { await open() }
        .onDisappear { close() }
    }

    /// Ends the session on the server right away, as closing the web UI's console does. Releasing the page alone
    /// left a shell connected for minutes, until WebKit got round to tearing it down.
    private func close() {
        guard let page, let blank = URL(string: "about:blank") else { return }
        self.page = nil
        // Unloading the console page closes its connection; the task keeps the page alive until that's done.
        Task { for try await _ in page.load(URLRequest(url: blank)) {} }
    }

    private func open() async {
        guard !session.usesToken, let ticket = session.client.ticket, let url = target.url(base: session.server.baseURL) else { return }
        close()
        error = nil
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: "PVEAuthCookie", .value: ticket.enc, .domain: session.server.host, .path: "/", .secure: "TRUE",
        ]
        if let cookie = HTTPCookie(properties: properties) {
            await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        let trust = CertificateTrust(pinnedFingerprint: session.server.fingerprint)
        let page = WebPage(configuration: configuration, navigationDecider: ConsoleNavigation(trust: trust))
        self.page = page
        do {
            for try await _ in page.load(URLRequest(url: url)) {}
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        #if DEBUG
        // Visual checks: WebKit doesn't draw while the screen is locked, so PROXIMA_DEBUG_CONSOLE_DUMP=<folder> saves what the page renders.
        if let folder = ProcessInfo.processInfo.environment["PROXIMA_DEBUG_CONSOLE_DUMP"] {
            try? await Task.sleep(for: .seconds(2))
            let base = URL(fileURLWithPath: folder)
            if let image = try? await page.exported(as: .image(afterScreenUpdates: false)) {
                try? image.write(to: base.appendingPathComponent("console-\(target.kind).png"))
            }
            if let text = try? await page.callJavaScript("return document.title + '\\n' + document.body.innerText") as? String {
                try? text.write(to: base.appendingPathComponent("console-\(target.kind).txt"), atomically: true, encoding: .utf8)
            }
        }
        #endif
    }
}

/// Applies the app's certificate pinning to the console's web view too.
private struct ConsoleNavigation: WebPage.NavigationDeciding {
    let trust: CertificateTrust

    func decideAuthenticationChallengeDisposition(for challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trust.decide(challenge)
    }
}

/// Content of a separate console window.
struct ConsoleWindow: View {
    @Environment(AppModel.self) private var model
    let target: ConsoleTarget?

    var body: some View {
        if let session = model.session, let target {
            ConsoleView(target: target)
                .environment(session)
                .navigationTitle(target.name)
                .navigationSubtitle(target.kind == "shell" ? "Shell on \(target.node)" : "Console · \(target.node)")
                .frame(minWidth: 640, minHeight: 420)
        } else {
            ContentUnavailableView("Sign in to open a console", systemImage: "terminal")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
