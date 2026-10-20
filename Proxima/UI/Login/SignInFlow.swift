import Foundation
import Observation

/// Drives one sign-in attempt: credentials → (certificate approval) → (second factor) → session.
@Observable
final class SignInFlow {
    enum Step: Equatable {
        case form
        case trust(CertificateTrust.Presented)
        case secondFactor(challenge: String, methods: [String])
    }

    var server: ServerProfile
    var secret = ""
    var remember = true
    var step: Step = .form
    var busy = false
    var error: String?
    var needsLocalNetwork = false
    /// The saved secret exists but macOS keeps it locked to an older build of Proxima.
    var keychainLocked = false
    var unlocking = false
    var realms: [(id: String, name: String)] = [("pam", "Linux PAM"), ("pve", "Proxmox VE")]
    /// Realms that sign in on an OpenID Connect provider's page instead of with a password.
    var openIDRealms: Set<String> = []
    /// The provider's sign-in page while it's open.
    var openIDPage: OpenIDPage?

    struct OpenIDPage: Identifiable {
        let url: URL
        /// Where the provider sends the browser back: the server's address, as the web UI uses.
        let redirect: String
        var id: String { url.absoluteString }
    }

    private var client: ProxmoxClient?

    init(server: ServerProfile = ServerProfile()) {
        self.server = server
    }

    var usesOpenID: Bool { openIDRealms.contains(server.realm) && !server.usesToken }

    var canSubmit: Bool { !server.host.trimmingCharacters(in: .whitespaces).isEmpty && (usesOpenID || !secret.isEmpty) && !busy }

    func connect(_ model: AppModel) async {
        server.normalize()
        error = nil
        needsLocalNetwork = false
        busy = true
        defer { busy = false }
        let client = ProxmoxClient(server: server)
        self.client = client
        do {
            if usesOpenID {
                openIDPage = OpenIDPage(url: try await client.openIDAuthURL(realm: server.realm, redirect: server.origin), redirect: server.origin)
            } else if server.usesToken {
                client.useToken(secret: secret)
                _ = try await client.get("/version")
                finish(model, client)
            } else {
                switch try await client.login(password: secret) {
                case .signedIn: finish(model, client)
                case .needsSecondFactor(let challenge, let methods): step = .secondFactor(challenge: challenge, methods: methods)
                }
            }
        } catch PVEError.untrustedCertificate(let presented) {
            step = .trust(presented)
        } catch PVEError.localNetworkDenied {
            needsLocalNetwork = true
            error = PVEError.localNetworkDenied.localizedDescription
        } catch let failure as PVEError where failure.isAuthenticationFailure {
            error = server.usesToken ? "That API token was rejected. Check the token ID and secret." : "The username or password is wrong."
        } catch PVEError.unauthorized {
            error = "The server rejected these credentials."
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Pins the certificate; connects too when a password or secret is already filled in.
    func trust(_ presented: CertificateTrust.Presented, model: AppModel) async {
        server.fingerprint = presented.fingerprint
        step = .form
        await loadRealms()
        if !secret.isEmpty { await connect(model) }
    }

    /// Checks the address before the password: surfaces the certificate prompt early and loads the
    /// server's real realms (LDAP, AD, OpenID…). Runs as the user types, so it stays quiet on failure.
    func probe() async {
        var probe = server
        probe.normalize()
        guard probe.host.count > 2, step == .form, !busy else { return }
        do {
            let list = try await ProxmoxClient(server: probe).list("/access/domains")
            applyRealms(list)
            error = nil
            needsLocalNetwork = false
        } catch PVEError.untrustedCertificate(let presented) {
            server.normalize()
            step = .trust(presented)
        } catch PVEError.localNetworkDenied {
            needsLocalNetwork = true
            error = PVEError.localNetworkDenied.localizedDescription
        } catch {
            // Still typing, or the server is down; Connect reports it properly.
        }
    }

    func submitCode(_ code: String, method: String, model: AppModel) async {
        guard case .secondFactor(let challenge, _) = step, let client else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.completeSecondFactor(challenge: challenge, response: "\(method):\(code.trimmingCharacters(in: .whitespaces))")
            finish(model, client)
        } catch let failure as PVEError where failure.isAuthenticationFailure {
            error = "That code didn't work. Codes change every 30 seconds — try the current one."
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Asks macOS to let this build read the saved secret (a prompt for the Mac's login password), then signs in with it.
    func unlockSavedSecret(_ model: AppModel) async {
        unlocking = true
        defer { unlocking = false }
        switch await model.savedSecret(for: server, allowPrompt: true) {
        case .found(let saved):
            keychainLocked = false
            secret = saved
            await connect(model)
        case .locked:
            error = "macOS didn't unlock the saved \(server.usesToken ? "secret" : "password"). Type it instead."
        case .missing:
            keychainLocked = false
        }
    }

    /// The provider sent the browser back with a code: Proxmox checks it and hands out a ticket.
    func completeOpenID(code: String, state: String, model: AppModel) async {
        guard let page = openIDPage, let client else { return }
        openIDPage = nil
        error = nil
        busy = true
        defer { busy = false }
        do {
            try await client.completeOpenID(code: code, state: state, redirect: page.redirect)
            // The provider decides who signed in, e.g. alice@authentik.
            if let at = client.userid.lastIndex(of: "@") { server.username = String(client.userid[..<at]) }
            finish(model, client)
        } catch let failure as PVEError where failure.isAuthenticationFailure {
            error = "Proxmox didn't accept the sign-in from \(realmName). Try again."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func failOpenID(_ message: String) {
        openIDPage = nil
        error = message
    }

    var realmName: String { realms.first { $0.id == server.realm }?.name ?? server.realm }

    func cancelStep() {
        step = .form
        busy = false
    }

    /// Realms come from an unauthenticated endpoint; only possible once the certificate is trusted.
    func loadRealms() async {
        var probe = server
        probe.normalize()
        guard !probe.host.isEmpty, let list = try? await ProxmoxClient(server: probe).list("/access/domains") else { return }
        applyRealms(list)
    }

    private func applyRealms(_ list: [JSONObject]) {
        openIDRealms = Set(list.filter { $0.string("type") == "openid" }.compactMap { $0.text("realm") })
        let found: [(id: String, name: String)] = list.compactMap { item in
            guard let id = item.text("realm") else { return nil }
            return (id, item.text("comment") ?? id)
        }
        guard !found.isEmpty else { return }
        realms = found
        if !realms.contains(where: { $0.id == server.realm }), let first = realms.first { server.realm = first.id }
    }

    private func finish(_ model: AppModel, _ client: ProxmoxClient) {
        #if DEBUG
        let testing = ProcessInfo.processInfo.environment["PROXIMA_DEBUG_SECRET"] != nil
        #else
        let testing = false
        #endif
        if testing {
            // UI tests sign in with a mock-server secret; leave the keychain alone.
        } else if remember && !usesOpenID {
            Keychain.save(secret, account: server.keychainAccount, label: "Proxima: \(server.usesToken ? server.tokenID : server.userid) on \(server.host)")
        } else {
            Keychain.delete(account: server.keychainAccount)
        }
        secret = ""
        step = .form
        model.begin(server, client: client)
    }
}
