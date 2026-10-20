import AppKit
import SwiftUI

/// Color is reserved for meaning: power state, metric identity and the accent for actions.
enum Theme {
    static let cardRadius: CGFloat = 18

    static let cpu = Color.orange
    static let memory = Color.purple
    static let disk = Color.teal
    static let netIn = Color.cyan
    static let netOut = Color.indigo
    static let read = Color.mint
    static let write = Color.pink

    /// White cards on the light window background; a faint lift in dark mode.
    static let cardFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.055)
            : NSColor.white
    })

    static let canvas = Color(nsColor: .windowBackgroundColor)

    static func color(_ power: PowerState) -> Color {
        switch power {
        case .running: .green
        case .stopped: .secondary
        case .paused: .yellow
        case .unknown: .red
        }
    }

    /// The hero tint behind a guest, node or storage.
    static func aura(_ power: PowerState) -> [Color] {
        switch power {
        case .running: [.green, .teal]
        case .stopped: [.gray, .blue.mix(with: .gray, by: 0.7)]
        case .paused: [.yellow, .orange]
        case .unknown: [.red, .orange]
        }
    }

    static func usage(_ fraction: Double, base: Color) -> Color {
        fraction >= 0.9 ? .red : fraction >= 0.8 ? .orange : base
    }

    /// Stable color per tag name, like Proxmox's automatic tag colors.
    static func tag(_ name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.6, brightness: 0.82)
    }

    static func ostypeLabel(_ ostype: String?) -> String? {
        guard let ostype, !ostype.isEmpty else { return nil }
        let names = [
            "l26": "Linux 6.x / 2.6 kernel", "l24": "Linux 2.4 kernel", "win11": "Windows 11/2022/2025", "win10": "Windows 10/2016/2019",
            "win8": "Windows 8/2012", "win7": "Windows 7/2008r2", "wvista": "Windows Vista/2008", "wxp": "Windows XP/2003",
            "w2k": "Windows 2000", "solaris": "Solaris", "other": "Other",
            "debian": "Debian", "ubuntu": "Ubuntu", "centos": "CentOS", "fedora": "Fedora", "alpine": "Alpine", "archlinux": "Arch Linux",
            "opensuse": "openSUSE", "gentoo": "Gentoo", "nixos": "NixOS", "devuan": "Devuan", "unmanaged": "Unmanaged",
        ]
        return names[ostype] ?? ostype
    }
}

extension View {
    /// Runs `action` now and then every `interval` while visible, restarting when `id` changes.
    func polling(id: some Equatable, every interval: Duration, _ action: @escaping () async -> Void) -> some View {
        task(id: id) {
            while !Task.isCancelled {
                await action()
                try? await Task.sleep(for: interval)
            }
        }
    }
}
