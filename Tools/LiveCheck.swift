import Foundation

/// Runs Proxima's own networking code against a real Proxmox server, without signing in.
@main
struct LiveCheck {
    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        var server = ServerProfile()
        server.host = arguments.first ?? ""
        server.normalize()
        let opensslFingerprint = arguments.dropFirst().first ?? ""
        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            print(ok ? "PASS" : "FAIL", message)
            if !ok { failures += 1 }
        }

        var presented: CertificateTrust.Presented?
        do { _ = try await ProxmoxClient(server: server).list("/access/domains") }
        catch PVEError.untrustedCertificate(let certificate) { presented = certificate }
        catch { print("  unexpected:", error.localizedDescription) }
        check(presented != nil, "self-signed certificate caught before any data is exchanged (\(presented?.subject ?? "none"))")
        check(presented?.fingerprint == opensslFingerprint, "fingerprint matches OpenSSL: \(presented?.fingerprint ?? "-")")

        var pinned = server
        pinned.fingerprint = presented?.fingerprint
        do {
            let realms = try await ProxmoxClient(server: pinned).list("/access/domains")
            let ids = realms.compactMap { $0.text("realm") }
            check(ids.contains("pam") && ids.contains("pve"), "pinned connection loads realms: \(ids.joined(separator: ", "))")
            check(realms.allSatisfy { $0.text("comment") != nil }, "realm descriptions decode: \(realms.compactMap { $0.text("comment") }.joined(separator: " / "))")
        } catch {
            check(false, "pinned connection failed: \(error.localizedDescription)")
        }

        var wrong = server
        wrong.fingerprint = String(repeating: "AB:", count: 31) + "AB"
        do { _ = try await ProxmoxClient(server: wrong).list("/access/domains"); check(false, "a different certificate was accepted") }
        catch PVEError.untrustedCertificate { check(true, "a certificate that doesn't match the pin is refused") }
        catch { check(false, "unexpected error for a wrong pin: \(error)") }

        for path in ["/version", "/cluster/resources", "/nodes"] {
            do { _ = try await ProxmoxClient(server: pinned).get(path); check(false, "\(path) answered without a session") }
            catch PVEError.unauthorized { check(true, "\(path) without a session → 401, which triggers \"Sign in again\"") }
            catch { check(false, "\(path): \(error.localizedDescription)") }
        }

        // An empty sign-in request: no credentials are sent, it only exercises error decoding.
        do { _ = try await ProxmoxClient(server: pinned).post("/access/ticket"); check(false, "empty sign-in was accepted") }
        catch PVEError.server(let message, let fields, let status) {
            check(!fields.isEmpty, "server errors decode from the ExtJS body: \"\(message)\" status \(status), fields \(fields.keys.sorted().joined(separator: ", "))")
        } catch {
            check(false, "empty sign-in: \(error)")
        }

        do {
            _ = try await ProxmoxClient(server: pinned).download("/nodes/x/storage/y/file-restore/download", ["volume": "y:backup/vm/100/2026-01-01T00:00:00Z", "filepath": "Lw=="])
            check(false, "a file download without a session was allowed")
        } catch PVEError.unauthorized {
            check(true, "file downloads without a session → 401, which triggers \"Sign in again\"")
        } catch {
            check(false, "unexpected error for a download without a session: \(error)")
        }

        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
