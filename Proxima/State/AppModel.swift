import Foundation
import Observation

/// Saved servers and the active session.
@Observable
final class AppModel {
    private(set) var servers: [ServerProfile]
    private(set) var session: Session?
    /// Set while restoring the last session at launch.
    var autoConnecting: ServerProfile?
    /// A server whose saved secret macOS keeps locked to an older build of Proxima; the welcome screen picks it up.
    var lockedServer: ServerProfile?
    /// Counts automatic sign-ins, so one the person stopped ignores a keychain answer that arrives late.
    private var autoConnectAttempt = 0

    private static let storeKey = "servers"

    init() {
        let data = UserDefaults.standard.data(forKey: Self.storeKey)
        servers = data.flatMap { try? JSONDecoder().decode([ServerProfile].self, from: $0) } ?? []
    }

    func save(_ server: ServerProfile) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index] = server } else { servers.append(server) }
        persist()
    }

    func remove(_ server: ServerProfile) {
        servers.removeAll { $0.id == server.id }
        Keychain.delete(account: server.keychainAccount)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }

    func begin(_ server: ServerProfile, client: ProxmoxClient) {
        var server = server
        server.lastConnected = .now
        save(server)
        session?.stop()
        let session = Session(server: server, client: client)
        self.session = session
        session.start()
    }

    func signOut(forget: Bool = false) {
        if forget, let server = session?.server { Keychain.delete(account: server.keychainAccount) }
        session?.stop()
        session = nil
    }

    /// The remembered password or token secret for a server.
    func savedSecret(for server: ServerProfile, allowPrompt: Bool = false) async -> Keychain.Lookup {
        #if DEBUG
        // Lets UI tests against the local mock server sign in without typing; synthetic keystrokes are
        // blocked while another app holds secure input. Never set outside testing.
        if let secret = ProcessInfo.processInfo.environment["PROXIMA_DEBUG_SECRET"], server.host == "127.0.0.1" { return .found(secret) }
        #endif
        return await Keychain.load(account: server.keychainAccount, allowPrompt: allowPrompt)
    }

    /// Stops waiting for an automatic sign-in (for example on a keychain prompt nobody has answered) so the person can sign in by hand.
    func cancelAutoConnect() {
        autoConnectAttempt += 1
        autoConnecting = nil
    }

    /// Reconnects to the most recent server when its secret is in the keychain and no second factor is needed.
    func restoreLastSession() async {
        var candidates = servers.filter { $0.lastConnected != nil }
        #if DEBUG
        // Test runs sign in to the local mock only, never to a real server saved next to it.
        if ProcessInfo.processInfo.environment["PROXIMA_DEBUG_SECRET"] != nil { candidates = candidates.filter { $0.host == "127.0.0.1" } }
        #endif
        guard session == nil, let server = candidates.max(by: { $0.lastConnected! < $1.lastConnected! }) else { return }
        autoConnectAttempt += 1
        let attempt = autoConnectAttempt
        autoConnecting = server
        let lookup = await savedSecret(for: server)
        guard attempt == autoConnectAttempt else { return }
        guard case .found(let secret) = lookup else {
            autoConnecting = nil
            // Saved by an older build: the welcome screen opens sign-in for it, with a way to unlock the saved password.
            if lookup == .locked { lockedServer = server }
            return
        }
        defer { if attempt == autoConnectAttempt { autoConnecting = nil } }
        let client = ProxmoxClient(server: server)
        do {
            if server.usesToken {
                client.useToken(secret: secret)
                _ = try await client.get("/version")
            } else {
                guard case .signedIn = try await client.login(password: secret) else { return }
            }
            guard attempt == autoConnectAttempt, session == nil else { return }
            begin(server, client: client)
        } catch {
            // The welcome screen stays up; the user signs in by hand.
        }
    }
}
