import Foundation

/// Proxmox returns the same field as a number, a string or a boolean depending on the
/// endpoint and PVE version, so every read goes through these coercing accessors.
typealias JSONObject = [String: Any]

nonisolated func jsonDouble(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber: return number.doubleValue
    case let string as String: return Double(string.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
}

nonisolated func jsonInt(_ value: Any?) -> Int? {
    switch value {
    case let number as NSNumber:
        if CFNumberIsFloatType(number) { return Int(exactly: number.doubleValue.rounded(.towardZero)) }
        return number.intValue
    case let string as String:
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        return Int(trimmed) ?? Double(trimmed).flatMap { Int(exactly: $0.rounded(.towardZero)) }
    default: return nil
    }
}

nonisolated func jsonBool(_ value: Any?) -> Bool {
    switch value {
    case let number as NSNumber: return number.boolValue
    case let string as String: return ["1", "true", "yes", "on"].contains(string.lowercased())
    default: return false
    }
}

nonisolated extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        switch self[key] {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    /// Like `string`, but treats an empty string as missing.
    func text(_ key: String) -> String? {
        guard let value = string(key), !value.isEmpty else { return nil }
        return value
    }

    func double(_ key: String) -> Double? { jsonDouble(self[key]) }
    func int(_ key: String) -> Int? { jsonInt(self[key]) }
    func int64(_ key: String) -> Int64 { Int64(jsonInt(self[key]) ?? 0) }
    func bool(_ key: String) -> Bool { jsonBool(self[key]) }
    func object(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func objects(_ key: String) -> [JSONObject] { self[key] as? [JSONObject] ?? [] }

    /// Arrays of strings, or a single comma/semicolon separated string.
    func strings(_ key: String) -> [String] {
        if let list = self[key] as? [Any] { return list.compactMap { $0 as? String ?? ($0 as? NSNumber)?.stringValue } }
        guard let value = string(key) else { return [] }
        return value.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map(String.init)
    }
}

/// A row of an API list, made identifiable for SwiftUI lists and tables.
nonisolated struct Row: Identifiable {
    let id: String
    let json: JSONObject
    subscript(key: String) -> String? { json.string(key) }
}

nonisolated extension String {
    /// Percent-encodes one path segment (a node name, volume ID, UPID, user ID…).
    var enc: String {
        addingPercentEncoding(withAllowedCharacters: .urlUnreserved) ?? self
    }
}

extension CharacterSet {
    nonisolated static let urlUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
