import CryptoKit
import Foundation
import Security
import Synchronization

/// Proxmox ships self-signed certificates. A certificate macOS already trusts is accepted
/// as usual; otherwise only the exact certificate the user approved (by SHA-256
/// fingerprint) is accepted — trust on first use, never "trust everything".
nonisolated final class CertificateTrust: NSObject, URLSessionDelegate, Sendable {
    struct Presented: Sendable, Equatable {
        let fingerprint: String
        let subject: String
    }

    let pinnedFingerprint: String?
    private let rejected = Mutex<Presented?>(nil)

    init(pinnedFingerprint: String?) {
        self.pinnedFingerprint = pinnedFingerprint
    }

    /// The certificate turned away by the last failed connection, for the "Trust this server?" prompt.
    var lastRejected: Presented? { rejected.withLock { $0 } }

    func decide(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        if SecTrustEvaluateWithError(trust, nil) {
            return (.useCredential, URLCredential(trust: trust))
        }
        let presented = Self.describe(trust)
        if let presented, presented.fingerprint == pinnedFingerprint {
            return (.useCredential, URLCredential(trust: trust))
        }
        rejected.withLock { $0 = presented }
        return (.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        decide(challenge)
    }

    static func describe(_ trust: SecTrust) -> Presented? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
        return Presented(fingerprint: fingerprint, subject: subject)
    }
}
