import Foundation

/// Proxmox reports sizes in binary units, so the app does too (GiB, not GB).
nonisolated enum Format {
    static func bytes(_ value: Int64) -> String { bytes(Double(value)) }

    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 B" }
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        var size = value
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(size)) B" }
        return size >= 100 ? "\(Int(size.rounded())) \(units[unit])" : String(format: "%.1f %@", size, units[unit])
    }

    static func rate(_ bytesPerSecond: Double) -> String { bytes(bytesPerSecond) + "/s" }

    /// "1 node", "3 nodes".
    static func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }

    /// 0.034 → "3.4%", 0.42 → "42%".
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "–" }
        let value = max(0, fraction * 100)
        // One decimal below 10%, but 9.96% would round to "10.0%", so it reads as "10%".
        return value < 9.95 && value > 0 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
    }

    /// 1_000_000 seconds → "11d 13h", 4000 → "1h 6m".
    static func duration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "–" }
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        if abs(date.timeIntervalSince(now)) < 45 { return "just now" }
        // Without weeks: the week unit counts calendar weeks, so nine days ago read "2 wk. ago".
        return Date.RelativeFormatStyle(allowedFields: [.year, .month, .day, .hour, .minute], presentation: .named, unitsStyle: .abbreviated).format(date)
    }

    /// Proxmox's subscription states in words ("notfound" means no key was entered).
    static func subscription(_ status: String?) -> String {
        ["notfound": "No subscription", "active": "Active", "invalid": "Invalid key", "expired": "Expired", "new": "New, not yet checked",
         "suspended": "Suspended"][status ?? ""] ?? (status ?? "Unknown").capitalized
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func epoch(_ seconds: Int?) -> Date? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// "32G" → bytes. Proxmox disk sizes use K/M/G/T suffixes.
    static func parseSize(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return nil }
        let multipliers: [Character: Double] = ["K": 1024, "M": 1_048_576, "G": 1_073_741_824, "T": 1_099_511_627_776]
        if let multiplier = multipliers[Character(last.uppercased())], let number = Double(trimmed.dropLast()) {
            return Int64(number * multiplier)
        }
        return Double(trimmed).map { Int64($0) }
    }
}
