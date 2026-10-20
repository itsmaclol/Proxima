import Foundation

/// A Proxmox task ID: `UPID:node:pid:pstart:starttime:type:id:user:` (hex numbers).
nonisolated struct UPID: Hashable {
    let raw: String
    let node: String
    let start: Date
    let type: String
    let id: String
    let user: String

    init?(_ raw: String) {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 9, parts[0] == "UPID", let start = Int(parts[4], radix: 16) else { return nil }
        self.raw = raw
        node = parts[1]
        self.start = Date(timeIntervalSince1970: TimeInterval(start))
        type = parts[5]
        // The worker ID may itself contain colons (volume IDs), the user never does.
        id = parts[6..<(parts.count - 2)].joined(separator: ":")
        user = parts[parts.count - 2]
    }

    var title: String { TaskNames.describe(type: type, id: id) }
}

/// Human names for task types, mirroring the Proxmox web UI's task table.
nonisolated enum TaskNames {
    static func describe(type: String, id: String) -> String {
        let vm = id.isEmpty ? "" : " \(id)"
        if let (verb, subject) = table[type] {
            switch subject {
            case .vm: return "\(verb) VM\(vm)"
            case .ct: return "\(verb) CT\(vm)"
            case .guest: return id.isEmpty ? verb : "\(verb) \(id)"
            case .none: return verb
            case .detail: return id.isEmpty ? verb : "\(verb): \(id)"
            }
        }
        return id.isEmpty ? type : "\(type) \(id)"
    }

    private enum Subject { case vm, ct, guest, none, detail }

    private static let table: [String: (String, Subject)] = [
        "qmstart": ("Start", .vm), "qmstop": ("Stop", .vm), "qmshutdown": ("Shut down", .vm),
        "qmreboot": ("Reboot", .vm), "qmreset": ("Reset", .vm), "qmsuspend": ("Hibernate", .vm),
        "qmresume": ("Resume", .vm), "qmpause": ("Pause", .vm), "qmcreate": ("Create", .vm),
        "qmrestore": ("Restore", .vm), "qmdestroy": ("Destroy", .vm), "qmclone": ("Clone", .vm),
        "qmigrate": ("Migrate", .vm), "qmtemplate": ("Convert to template", .vm), "qmconfig": ("Configure", .vm),
        "qmsnapshot": ("Take snapshot of", .vm), "qmrollback": ("Roll back", .vm), "qmdelsnapshot": ("Delete snapshot of", .vm),
        "qmmove": ("Move disk of", .vm), "qmimport": ("Import disk to", .vm), "resize": ("Resize disk of", .guest),
        "vncproxy": ("Console", .guest), "vncshell": ("Shell", .none), "termproxy": ("Terminal", .guest), "spiceproxy": ("SPICE console", .guest),
        "vzstart": ("Start", .ct), "vzstop": ("Stop", .ct), "vzshutdown": ("Shut down", .ct), "vzreboot": ("Reboot", .ct),
        "vzsuspend": ("Suspend", .ct), "vzresume": ("Resume", .ct), "vzcreate": ("Create", .ct), "vzrestore": ("Restore", .ct),
        "vzdestroy": ("Destroy", .ct), "vzclone": ("Clone", .ct), "vzmigrate": ("Migrate", .ct), "vztemplate": ("Convert to template", .ct),
        "vzsnapshot": ("Take snapshot of", .ct), "vzrollback": ("Roll back", .ct), "vzdelsnapshot": ("Delete snapshot of", .ct),
        "vzmount": ("Mount", .ct), "vzumount": ("Unmount", .ct), "move_volume": ("Move volume of", .ct),
        "vzdump": ("Backup", .guest), "imgcopy": ("Copy data", .none), "imgdel": ("Erase data", .detail),
        "download": ("Download", .detail), "aptupdate": ("Update package database", .none),
        "startall": ("Bulk start guests", .none), "stopall": ("Bulk shut down guests", .none),
        "suspendall": ("Bulk suspend guests", .none), "migrateall": ("Bulk migrate guests", .none),
        "srvstart": ("Start service", .detail), "srvstop": ("Stop service", .detail), "srvrestart": ("Restart service", .detail),
        "srvreload": ("Reload service", .detail), "cephcreatemon": ("Create Ceph monitor", .detail),
        "hamigrate": ("HA migrate", .guest), "hastart": ("HA start", .guest), "hastop": ("HA stop", .guest),
        "pull_file": ("Pull file from", .ct), "push_file": ("Push file to", .ct), "reloadnetworkall": ("Apply network changes", .none),
        "cephcreatemgr": ("Create Ceph manager", .detail), "cephcreatemds": ("Create Ceph metadata server", .detail),
        "cephcreateosd": ("Create Ceph OSD", .detail), "cephcreatepool": ("Create Ceph pool", .detail), "cephfscreate": ("Create CephFS", .detail),
        "cephdestroymon": ("Destroy Ceph monitor", .detail), "cephdestroymgr": ("Destroy Ceph manager", .detail),
        "cephdestroymds": ("Destroy Ceph metadata server", .detail), "cephdestroyosd": ("Destroy Ceph OSD", .detail),
        "cephdestroypool": ("Destroy Ceph pool", .detail), "cephdestroyfs": ("Destroy CephFS", .detail),
        "cephsetpool": ("Edit Ceph pool", .detail), "cephsetflags": ("Change Ceph flags", .none),
        "clustercreate": ("Create cluster", .none), "clusterjoin": ("Join cluster", .none), "hashutdown": ("HA shut down", .guest),
        "lvmremove": ("Remove LVM volume group", .detail), "lvmthinremove": ("Remove LVM thin pool", .detail),
        "pbs-download": ("Download from backup of", .guest), "spiceshell": ("SPICE shell", .none),
        "acmeregister": ("Register ACME account", .detail), "acmeupdate": ("Update ACME account", .detail),
        "acmerefresh": ("Refresh ACME account", .detail), "acmedeactivate": ("Deactivate ACME account", .detail),
        "acmerevoke": ("Revoke certificate", .none), "auth-realm-sync-test": ("Preview realm sync", .detail),
        "dircreate": ("Create directory storage", .detail), "zfscreate": ("Create ZFS pool", .detail),
        "lvmcreate": ("Create LVM volume group", .detail), "lvmthincreate": ("Create LVM thin pool", .detail),
        "diskinit": ("Initialize disk", .detail), "wipedisk": ("Wipe disk", .detail), "acmenewcert": ("Order certificate", .none),
        "acmerenew": ("Renew certificate", .none), "auth-realm-sync": ("Sync realm", .detail), "unknownimgdel": ("Remove unused disk", .detail),
        "qmmonitor": ("Monitor", .vm), "zfsremove": ("Remove ZFS pool", .detail), "dirremove": ("Remove directory storage", .detail),
    ]
}
