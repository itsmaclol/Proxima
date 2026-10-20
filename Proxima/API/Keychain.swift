import Foundation
import Security

/// Passwords and API token secrets live only in the login keychain, keyed by server ID.
///
/// A locally signed build looks like a new app to macOS each time it's rebuilt, and an item saved by an older build
/// can then only be read after the person approves a macOS prompt (with their Mac's login password). Proxima reads
/// silently and shows that prompt only when the person asks for it, so it never loops on the prompt, and every call
/// runs on one background queue, so the window never freezes while macOS waits for an answer.
nonisolated enum Keychain {
    enum Lookup: Equatable {
        case found(String)
        case missing
        /// Saved by another build of Proxima: macOS wants the person's OK before this one may read it.
        case locked
    }

    private static let service = "app.proxima.Proxima"
    /// Whether macOS may prompt is a switch for the whole process, so keychain calls take turns here.
    private static let queue = DispatchQueue(label: "app.proxima.keychain")

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Runs `body` with macOS prompts allowed or not, then turns them back on (the system default).
    private static func prompting<T>(_ allowed: Bool, _ body: () -> T) -> T {
        SecKeychainSetUserInteractionAllowed(allowed)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return body()
    }

    static func save(_ secret: String, account: String, label: String) {
        queue.async {
            prompting(false) {
                let query = base(account)
                var item = query
                item[kSecAttrLabel as String] = label
                item[kSecValueData as String] = Data(secret.utf8)
                SecItemDelete(query as CFDictionary)
                if SecItemAdd(item as CFDictionary, nil) == errSecDuplicateItem {
                    // An older build's item can't be removed, but its secret can still be replaced.
                    SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(secret.utf8), kSecAttrLabel as String: label] as CFDictionary)
                }
            }
        }
    }

    /// Looks up a saved secret. With `allowPrompt`, macOS may ask the person to let this build read an older build's item.
    static func load(account: String, allowPrompt: Bool = false) async -> Lookup {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = prompting(allowPrompt) { () -> Lookup in
                    var query = base(account)
                    query[kSecReturnData as String] = true
                    query[kSecMatchLimit as String] = kSecMatchLimitOne
                    var item: CFTypeRef?
                    switch SecItemCopyMatching(query as CFDictionary, &item) {
                    case errSecSuccess: return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }.map(Lookup.found) ?? .missing
                    case errSecItemNotFound: return .missing
                    default: return .locked
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    static func delete(account: String) {
        queue.async { prompting(false) { _ = SecItemDelete(base(account) as CFDictionary) } }
    }
}
