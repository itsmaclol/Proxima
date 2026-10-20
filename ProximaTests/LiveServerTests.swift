import Foundation
import Testing
@testable import Proxima

/// Talks to a real Proxmox server without signing in. Opt in with
/// `TEST_RUNNER_PROXIMA_LIVE_HOST=192.168.100.50 xcodebuild test …`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROXIMA_LIVE_HOST"] != nil, "Set PROXIMA_LIVE_HOST to run"))
struct LiveServer {
    private var server: ServerProfile {
        var server = ServerProfile()
        server.host = ProcessInfo.processInfo.environment["PROXIMA_LIVE_HOST"] ?? ""
        server.normalize()
        return server
    }

    private func presentedCertificate() async throws -> CertificateTrust.Presented {
        do {
            _ = try await ProxmoxClient(server: server).list("/access/domains")
        } catch PVEError.untrustedCertificate(let presented) {
            return presented
        }
        Issue.record("The server's certificate was accepted without pinning; expected a self-signed one")
        throw CancellationError()
    }

    @Test func `self-signed certificate is caught, then accepted once pinned`() async throws {
        let certificate = try await presentedCertificate()
        #expect(certificate.fingerprint.count == 95, "SHA-256 as 32 colon-separated hex pairs")
        print("Live server certificate: \(certificate.subject) \(certificate.fingerprint)")

        var pinned = server
        pinned.fingerprint = certificate.fingerprint
        let realms = try await ProxmoxClient(server: pinned).list("/access/domains")
        #expect(realms.contains { $0.string("realm") == "pam" })
        #expect(realms.contains { $0.string("realm") == "pve" })
        print("Live server realms: \(realms.compactMap { $0.string("realm") })")
    }

    @Test func `a different pinned certificate is refused`() async throws {
        var pinned = server
        pinned.fingerprint = String(repeating: "00:", count: 31) + "00"
        await #expect(throws: PVEError.self) { _ = try await ProxmoxClient(server: pinned).list("/access/domains") }
    }

    @Test func `requests without a session come back as 401`() async throws {
        var pinned = server
        pinned.fingerprint = try await presentedCertificate().fingerprint
        do {
            _ = try await ProxmoxClient(server: pinned).get("/version")
            Issue.record("Expected the server to refuse an unauthenticated request")
        } catch PVEError.unauthorized {
            // The session-expiry path (sign in again) depends on exactly this.
        }
    }
}
