import Foundation
import Testing
@testable import Proxima

@Suite struct PropertyStrings {
    @Test func `disk with a leading volume`() {
        var disk = PropertyString("local-lvm:vm-100-disk-0,iothread=1,size=32G", defaultKey: "file")
        #expect(disk["file"] == "local-lvm:vm-100-disk-0")
        #expect(disk["size"] == "32G")
        disk["discard"] = "on"
        disk["iothread"] = nil
        #expect(disk.raw == "local-lvm:vm-100-disk-0,size=32G,discard=on")
    }

    @Test func `nic model holds the MAC`() {
        let nic = PropertyString("virtio=BC:24:11:AA:BB:CC,bridge=vmbr0,firewall=1")
        #expect(nic.nicModel == "virtio")
        #expect(nic["virtio"] == "BC:24:11:AA:BB:CC")
        #expect(nic.flag("firewall"))
        #expect(nic.raw == "virtio=BC:24:11:AA:BB:CC,bridge=vmbr0,firewall=1")
    }

    @Test func `value with an equals sign keeps it`() {
        let boot = PropertyString("order=scsi0;ide2;net0")
        #expect(boot["order"] == "scsi0;ide2;net0")
    }
}

@Suite struct OCIReferences {
    @Test func `tags follow the last colon after the last slash`() {
        #expect(OCIPullSheet.split("nginx:1.29") == ("nginx", "1.29"))
        #expect(OCIPullSheet.split("registry.local:5000/team/app") == ("registry.local:5000/team/app", nil))
        #expect(OCIPullSheet.split("registry.local:5000/team/app:v2") == ("registry.local:5000/team/app", "v2"))
        #expect(OCIPullSheet.split(" ghcr.io/home-assistant/home-assistant ") == ("ghcr.io/home-assistant/home-assistant", nil))
    }
}

@Suite struct VMOptions {
    @Test func `cpu edits keep options the editor doesn't show`() {
        #expect(VMOption.cpu("x86-64-v2-AES,flags=+aes,hidden=1", type: "host", flags: "+aes;+md-clear") == "host,flags=+aes;+md-clear,hidden=1")
        #expect(VMOption.cpu("kvm64,flags=+aes", type: "", flags: "") == "")
        #expect(VMOption.cpu("", type: "host", flags: "") == "host")
    }

    @Test func `machine options need a type`() {
        #expect(VMOption.machine("pc-q35-9.2+pve1,viommu=intel", type: "pc-q35-10.0+pve1", viommu: "intel") == "pc-q35-10.0+pve1,viommu=intel")
        #expect(VMOption.machine("q35", type: "", viommu: "virtio") == "pc,viommu=virtio")
        #expect(VMOption.machine("q35,viommu=intel", type: "", viommu: "") == "")
    }

    @Test func `display keeps its memory and clipboard`() {
        #expect(VMOption.display("std,memory=32", type: "virtio", memory: "32", clipboard: true) == "virtio,memory=32,clipboard=vnc")
        #expect(VMOption.display("qxl,memory=64", type: "", memory: "64", clipboard: false) == "std,memory=64")
        #expect(VMOption.display("std", type: "", memory: "", clipboard: false) == "")
    }
}

@Suite struct TaskIDs {
    @Test func `regular UPID`() throws {
        let upid = try #require(UPID("UPID:pve1:00009D7D:02C0146B:6AD69E4C:qmstart:102:root@pam:"))
        #expect(upid.node == "pve1")
        #expect(upid.type == "qmstart")
        #expect(upid.id == "102")
        #expect(upid.user == "root@pam")
        #expect(upid.start == Date(timeIntervalSince1970: 0x6AD69E4C))
        #expect(upid.title == "Start VM 102")
        #expect(UPID("UPID:pve1:00009D7D:02C0146B:6AD69E4C:push_file:119:root@pam:")?.title == "Push file to CT 119")
    }

    @Test func `worker id containing colons`() throws {
        let upid = try #require(UPID("UPID:pve1:0000ABCD:00000001:6AD69E4C:imgdel:local:iso/debian.iso:automation@pve!ci:"))
        #expect(upid.id == "local:iso/debian.iso")
        #expect(upid.user == "automation@pve!ci")
    }

    @Test func `garbage is rejected`() {
        #expect(UPID("not a upid") == nil)
        #expect(UPID("UPID:pve1:x") == nil)
    }

    @Test func `running tasks have no status`() {
        let running = TaskEntry(["upid": "UPID:pve1:1:1:6AD69E4C:vzdump::root@pam:", "status": "RUNNING", "starttime": 1_792_000_000])
        #expect(running.isRunning)
        #expect(running.status == nil)
        let failed = TaskEntry(["upid": "UPID:pve1:1:1:6AD69E4C:vzstart:203:root@pam:", "status": "startup failed", "endtime": 1_792_000_100])
        #expect(!failed.isRunning && !failed.succeeded)
    }
}

@Suite struct Coercion {
    @Test(arguments: [("2048", 2048), ("2048.0", 2048), (" 7 ", 7)])
    func `ints from strings`(text: String, value: Int) {
        #expect(jsonInt(text) == value)
    }

    @Test func `numbers, flags and lists`() {
        let object: JSONObject = ["cpu": NSNumber(value: 0.25), "vmid": "100", "template": NSNumber(value: 1), "flag": "0",
                                  "tags": "prod;web", "list": ["a", NSNumber(value: 2)], "empty": ""]
        #expect(object.double("cpu") == 0.25)
        #expect(object.int("vmid") == 100)
        #expect(object.bool("template"))
        #expect(!object.bool("flag"))
        #expect(object.strings("tags") == ["prod", "web"])
        #expect(object.strings("list") == ["a", "2"])
        #expect(object.text("empty") == nil)
        #expect(jsonInt(Double.nan) == nil)
    }
}

@Suite struct Formatting {
    @Test func `relative dates count days, not calendar weeks`() {
        #expect(Format.relative(.now.addingTimeInterval(-9 * 86400)) == "9 days ago")
        #expect(Format.relative(.now.addingTimeInterval(-10)) == "just now")
    }

    @Test func bytes() {
        #expect(Format.bytes(Int64(0)) == "0 B")
        #expect(Format.bytes(Int64(512)) == "512 B")
        #expect(Format.bytes(Int64(1_610_612_736)) == "1.5 GiB")
        #expect(Format.bytes(Int64(137_438_953_472)) == "128 GiB")
    }

    @Test func percentAndDuration() {
        #expect(Format.percent(0.034) == "3.4%")
        #expect(Format.percent(0.42) == "42%")
        #expect(Format.percent(0.0997) == "10%")
        #expect(Format.duration(1_000_000) == "11d 13h")
        #expect(Format.duration(4000) == "1h 6m")
        #expect(Format.duration(0) == "–")
    }

    @Test func sizes() {
        #expect(Format.parseSize("32G") == 34_359_738_368)
        #expect(Format.parseSize("512M") == 536_870_912)
        #expect(Format.parseSize("1.5T") == 1_649_267_441_664)
    }
}

@Suite struct Servers {
    @Test func `pasted web UI address`() {
        var server = ServerProfile()
        server.host = " https://pve.home.lan:443/#v1:0:18:4 "
        server.username = "admin@pve"
        server.normalize()
        #expect(server.host == "pve.home.lan")
        #expect(server.port == 443)
        #expect(server.username == "admin")
        #expect(server.realm == "pve")
        #expect(server.baseURL.absoluteString == "https://pve.home.lan:443")
    }

    @Test func `token user and IPv6`() {
        var server = ServerProfile()
        server.host = "[fd00::10]:8006"
        server.username = "automation@pve!terraform"
        server.normalize()
        #expect(server.host == "fd00::10")
        #expect(server.usesToken)
        #expect(server.tokenID == "automation@pve!terraform")
        #expect(server.baseURL.absoluteString == "https://[fd00::10]:8006")
    }
}

@Suite struct Wire {
    @Test func `second factor methods from the challenge ticket`() {
        let json = #"{"totp":true,"recovery":"available","yubico":false}"#
        let ticket = "PVE:!tfa!" + json.addingPercentEncoding(withAllowedCharacters: .urlUnreserved)! + ":abc"
        #expect(ProxmoxClient.secondFactorMethods(in: ticket) == ["totp", "recovery"])
        #expect(ProxmoxClient.secondFactorMethods(in: "PVE:root@pam:1234::sig") == ["totp"])
        let keyOnly = "PVE:!tfa!" + "{\"webauthn\":{\"challenge\":\"abc\"}}".addingPercentEncoding(withAllowedCharacters: .urlUnreserved)! + ":5F00AA"
        #expect(ProxmoxClient.secondFactorMethods(in: keyOnly) == ["webauthn"])
    }

    @Test func `form encoding escapes everything reserved`() {
        let body = ProxmoxClient.formEncode(["net0": "virtio,bridge=vmbr0", "description": "a & b = c\n", "sshkeys": "ssh-ed25519 AAA+/="])
        #expect(body == "description=a%20%26%20b%20%3D%20c%0A&net0=virtio%2Cbridge%3Dvmbr0&sshkeys=ssh-ed25519%20AAA%2B%2F%3D")
    }

    @Test func `array values go out as repeated keys`() {
        #expect(ProxmoxClient.formEncode(["target": "mail-to-root\0ntfy", "name": "m"]) == "name=m&target=mail-to-root&target=ntfy")
        #expect(ProxmoxClient.formEncode(["comment": ""]) == "comment=")
    }

    @Test func `uploads carry the file's SHA-256`() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("proxima-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try ProxmoxClient.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func `path segments`() {
        #expect("local:iso/debian 13.iso".enc == "local%3Aiso%2Fdebian%2013.iso")
        #expect("vm:101".enc == "vm%3A101")
    }

    @Test func `next free device slot`() {
        #expect(Session.nextKey("net", in: ["net0": "x", "net1": "y"]) == "net2")
        #expect(Session.nextKey("scsi", in: [:]) == "scsi0")
    }
}

@Suite struct Hardware {
    @Test func `rows in web UI order with pending values`() {
        let config: JSONObject = ["memory": "8192", "cores": 4, "sockets": 1, "scsi0": "local-lvm:vm-100-disk-0,size=64G",
                                  "ide2": "none,media=cdrom", "net0": "virtio=BC:24:11:00:00:01,bridge=vmbr0", "unused0": "local-lvm:vm-100-disk-1"]
        let pending: [JSONObject] = [["key": "memory", "value": "8192", "pending": "16384"], ["key": "cores", "value": 4],
                                     ["key": "sockets", "value": 1], ["key": "scsi0", "value": "local-lvm:vm-100-disk-0,size=64G"],
                                     ["key": "ide2", "value": "none,media=cdrom"], ["key": "net0", "value": "virtio=BC:24:11:00:00:01,bridge=vmbr0"],
                                     ["key": "unused0", "value": "local-lvm:vm-100-disk-1", "delete": 1]]
        let items = VMHardwareView.items(config: config, pending: pending)
        #expect(items.first?.key == "memory")
        #expect(items.first?.pending == "16384")
        #expect(items.contains { $0.key == "ide2" && $0.kind == .cdrom })
        #expect(items.contains { $0.key == "scsi0" && $0.kind == .disk })
        #expect(items.first { $0.key == "unused0" }?.pendingDelete == true)
        #expect(items.firstIndex { $0.key == "scsi0" }! < items.firstIndex { $0.key == "net0" }!)
    }
}

@Suite struct Cluster {
    @Test func `join information round-trips the preferred member's address and fingerprint`() throws {
        let join: JSONObject = ["preferred_node": "pve2", "totem": ["cluster_name": "homelab"],
                                "nodelist": [["name": "pve1", "pve_addr": "10.0.0.1", "pve_fp": "AA:01", "ring0_addr": "10.0.0.1"],
                                             ["name": "pve2", "pve_addr": "10.0.0.2", "pve_fp": "BB:02", "ring0_addr": "10.0.0.2", "ring1_addr": "172.16.0.2"]]]
        let blob = try #require(ClusterSection.joinInformation(join))
        let info = try #require(ClusterSection.decodeJoinInformation(blob + "\n"))
        #expect(info.string("ipAddress") == "10.0.0.2")
        #expect(info.string("fingerprint") == "BB:02")
        #expect(info.strings("ring_addr") == ["10.0.0.2", "172.16.0.2"])
        #expect(info.object("peerLinks")?.string("1") == "172.16.0.2")
        #expect(ClusterSection.decodeJoinInformation("not base64!") == nil)
    }

    @Test func `Ceph OSD tree flattens to OSDs with their host`() {
        let root: JSONObject = ["type": "root", "name": "default", "children": [
            ["type": "host", "name": "pve1", "children": [["type": "osd", "id": 0, "name": "osd.0"], ["type": "osd", "id": 1, "name": "osd.1"]]],
            ["type": "host", "name": "pve2", "children": [["type": "osd", "id": 2, "name": "osd.2", "host": "pve2"]]]]]
        let osds = CephOSDs.flatten(root)
        #expect(osds.map { $0.string("name") ?? "" } == ["osd.0", "osd.1", "osd.2"])
        #expect(osds.map { $0.string("host") ?? "" } == ["pve1", "pve1", "pve2"])
    }
}

@Suite struct Webhooks {
    @Test func `headers go out as base64 pairs and come back as lines`() {
        let encoded = TargetEditor.encodePairs("Content-Type: application/json\nAuthorization: Bearer a,b:c\n\nkept:")
        #expect(encoded == "name=Content-Type,value=YXBwbGljYXRpb24vanNvbg==\0name=Authorization,value=QmVhcmVyIGEsYjpj\0name=kept")
        #expect(TargetEditor.decodePairs(encoded.split(separator: "\0").map(String.init)) == "Content-Type: application/json\nAuthorization: Bearer a,b:c\nkept: ")
    }
}

@Suite struct CephSetup {
    @Test func `interface addresses become networks`() {
        #expect(CephConfigureSheet.network(of: "192.168.1.10/24") == "192.168.1.0/24")
        #expect(CephConfigureSheet.network(of: "10.10.10.77/27") == "10.10.10.64/27")
        #expect(CephConfigureSheet.network(of: "172.16.5.4/0") == "0.0.0.0/0")
        #expect(CephConfigureSheet.network(of: "fd00::10/64") == "fd00::10/64")
    }

    @Test func `the installer console carries its options`() throws {
        let target = ConsoleTarget(kind: "cmd", node: "pve1", vmid: nil, name: "Install", cmd: "ceph_install", cmdOptions: "--version\0squid\0--repository\0no-subscription")
        let url = try #require(target.url(base: URL(string: "https://pve:8006/api2/extjs")!))
        let query = url.absoluteString
        #expect(query.contains("console=cmd"))
        #expect(query.contains("cmd=ceph_install"))
        #expect(query.contains("cmd-opts=--version%00squid%00--repository%00no-subscription"))
    }
}

@Suite struct GuestImport {
    @Test func `ESXi guests import every disk and keep their MACs`() {
        let meta: JSONObject = [
            "create-args": ["name": "web01", "memory": 8192, "cores": 4, "bios": "ovmf", "ide2": "datastore1/iso/x.iso,media=cdrom"],
            "disks": ["scsi0": ["volid": "esxi1:ha-datacenter/datastore1/web01/web01.vmdk", "size": 68_719_476_736], "efidisk0": ["volid": "esxi1:nvram"]],
            "net": ["net0": ["model": "vmxnet3", "macaddr": "00:50:56:9a:12:34"]],
        ]
        let result = FormResult(all: ["vmid": "120", "name": "web01", "memory": "4096", "storage": "local-lvm", "format": "", "bridge": "vmbr0", "live-restore": "1"],
                                changed: [:], cleared: [])
        let params = ImportGuestSheet.params(meta: meta, result: result)
        #expect(params["scsi0"] == "local-lvm:0,import-from=esxi1:ha-datacenter/datastore1/web01/web01.vmdk")
        #expect(params["efidisk0"] == "local-lvm:0,efitype=4m")
        #expect(params["net0"] == "vmxnet3=00:50:56:9a:12:34,bridge=vmbr0")
        #expect(params["ide2"] == "none,media=cdrom")
        #expect(params["memory"] == "4096")
        #expect(params["cores"] == "4")
        #expect(params["bios"] == "ovmf")
        #expect(params["vmid"] == "120")
        #expect(params["live-restore"] == "1")
    }

    @Test func `Windows disks move to free SATA slots, and skipped disks stay behind`() {
        let meta: JSONObject = [
            "create-args": ["ostype": "win11", "sata0": "ds/iso/setup.iso,media=cdrom", "boot": "order=scsi0;sata0;net0", "scsihw": "pvscsi"],
            "disks": ["scsi0": ["volid": "esxi1:vm/disk0.vmdk"], "scsi1": ["volid": "esxi1:vm/disk1.vmdk"], "scsi2": ["volid": "esxi1:vm/scratch.vmdk"]],
        ]
        let result = FormResult(all: ["storage": "local-lvm", "storage:scsi1": "tank", "storage:scsi2": ImportGuestSheet.skip, "virtio-prep": "1"],
                                changed: [:], cleared: [])
        let params = ImportGuestSheet.params(meta: meta, result: result)
        #expect(params["sata1"] == "local-lvm:0,import-from=esxi1:vm/disk0.vmdk")
        #expect(params["sata2"] == "tank:0,import-from=esxi1:vm/disk1.vmdk")
        #expect(params["sata3"] == nil && params["scsi2"] == nil && params["scsi0"] == nil)
        #expect(params["sata0"] == "none,media=cdrom")
        #expect(params["boot"] == "order=sata1;sata0;net0")
        #expect(params["scsihw"] == "virtio-scsi-single")
    }
}

