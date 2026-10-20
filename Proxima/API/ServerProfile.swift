import Foundation

/// A saved Proxmox server. Secrets are kept in the keychain, never here.
nonisolated struct ServerProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = 8006
    var username = "root"
    var realm = "pam"
    /// Set when signing in with an API token: the part after "!" in `user@realm!name`.
    var tokenName: String?
    /// SHA-256 of the self-signed certificate the user approved.
    var fingerprint: String?
    var lastConnected: Date?

    var userid: String { "\(username)@\(realm)" }
    var usesToken: Bool { !(tokenName ?? "").isEmpty }
    var tokenID: String { "\(userid)!\(tokenName ?? "")" }
    var displayName: String { name.isEmpty ? host : name }
    var keychainAccount: String { id.uuidString }

    private var hostForURL: String { host.contains(":") ? "[\(host)]" : host }
    var baseURL: URL { URL(string: "https://\(hostForURL):\(port)")! }
    /// The web UI's `location.origin` here, where OpenID providers send people back after signing in.
    var origin: String { port == 443 ? "https://\(hostForURL)" : "https://\(hostForURL):\(port)" }

    /// Accepts what people paste: "https://pve:8006/#v1:0:18", "root@pam", "pve.lan:443".
    mutating func normalize() {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let slash = text.firstIndex(where: { $0 == "/" || $0 == "#" || $0 == "?" }) { text = String(text[..<slash]) }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":"), let parsed = Int(rest.dropFirst()) { port = parsed }
            text = String(text[text.index(after: text.startIndex)..<close])
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":"), let parsed = Int(text[text.index(after: colon)...]) {
            port = parsed
            text = String(text[..<colon])
        }
        host = text
        username = username.trimmingCharacters(in: .whitespaces)
        if let at = username.lastIndex(of: "@") {
            let suffix = String(username[username.index(after: at)...])
            if suffix.contains("!") {
                let parts = suffix.split(separator: "!", maxSplits: 1)
                realm = String(parts[0])
                tokenName = parts.count > 1 ? String(parts[1]) : tokenName
            } else if !suffix.isEmpty {
                realm = suffix
            }
            username = String(username[..<at])
        }
    }
}
