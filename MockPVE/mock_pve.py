#!/usr/bin/env python3
"""A fake Proxmox VE API server for developing and testing Proxima.

It speaks the same JSON/ExtJS API shapes as pveproxy on https://127.0.0.1:8006,
with a self-signed certificate, ticket + CSRF auth, API tokens, TOTP 2FA, and
stateful guests, snapshots, backups, tasks and permissions.

    python3 MockPVE/mock_pve.py                    # normal homelab cluster
    MOCK_PVE_PROFILE=stress python3 MockPVE/...    # worst-case data (long names, 140 guests, offline node)

Test logins live in MockPVE/seed-users.json (created on first run).
"""
import base64
import email.parser
import email.policy
import hashlib
import io
import html
import json
import math
import os
import random
import re
import secrets
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(os.environ.get("MOCK_PVE_PORT", "8006"))
PROFILE = os.environ.get("MOCK_PVE_PROFILE", "normal")
GiB = 1024 ** 3
MiB = 1024 ** 2
LOCK = threading.RLock()
START = time.time()


class ApiError(Exception):
    def __init__(self, status, message, errors=None):
        super().__init__(message)
        self.status, self.message, self.errors = status, message, errors


# ---------------------------------------------------------------- credentials

def load_seed():
    path = os.path.join(HERE, "seed-users.json")
    if not os.path.exists(path):
        seed = {
            "comment": "Test logins for the mock server only. Not real credentials.",
            "users": [
                {"userid": "root@pam", "password": secrets.token_urlsafe(12)},
                {"userid": "admin@pve", "password": secrets.token_urlsafe(12), "totp": "246810"},
            ],
            "tokens": [{"tokenid": "root@pam!proxima", "secret": str(__import__("uuid").uuid4())}],
        }
        with open(path, "w") as f:
            json.dump(seed, f, indent=2)
    with open(path) as f:
        seed = json.load(f)
    # An account whose only second factor is a security key, to try the sign-in path that has to send people to a browser.
    if not any(u["userid"] == "keyonly@pve" for u in seed["users"]):
        seed["users"].append({"userid": "keyonly@pve", "password": secrets.token_urlsafe(12), "webauthn": True})
        with open(path, "w") as f:
            json.dump(seed, f, indent=2)
    return seed


SEED = load_seed()
TICKETS = {}  # ticket -> (userid, csrf, created)


def ensure_cert():
    d = os.path.join(HERE, "certs")
    os.makedirs(d, exist_ok=True)
    cert, key = os.path.join(d, "cert.pem"), os.path.join(d, "key.pem")
    if not os.path.exists(cert):
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
                        "-out", cert, "-days", "825", "-subj", "/OU=PVE Cluster Node/O=Proxmox Virtual Environment/CN=pve1.home.lan"],
                       check=True, capture_output=True)
    der = ssl.PEM_cert_to_DER_cert(open(cert).read())
    fp = hashlib.sha256(der).hexdigest().upper()
    return cert, key, ":".join(fp[i:i + 2] for i in range(0, len(fp), 2))


# ---------------------------------------------------------------- state

def now():
    return int(time.time())


def mac(seed):
    r = random.Random(seed)
    return "BC:24:11:" + ":".join(f"{r.randint(0, 255):02X}" for _ in range(3))


NODES = {}
GUESTS = {}
STORAGES = {}      # storage id -> config
CONTENT = {}       # (node or "shared", storage) -> list of volumes
TASKS = []
SNAPSHOTS = {}     # vmid -> list
FIREWALL = {}      # base path -> {"rules": [...], "options": {...}}
BACKUP_JOBS = []
HA_RESOURCES = []
POOLS = {}
USERS = {}
GROUPS = {}
ACL = []
NODE_EXTRA = {}
CLUSTER_OPTIONS = {"description": "", "keyboard": "en-us", "console": "xtermjs"}

ROLES = [
    ("Administrator", "Datastore.Allocate,Datastore.AllocateSpace,Datastore.Audit,Group.Allocate,Mapping.Audit,Mapping.Modify,Mapping.Use,Permissions.Modify,Pool.Allocate,Pool.Audit,Realm.Allocate,Realm.AllocateUser,SDN.Allocate,SDN.Audit,SDN.Use,Sys.Audit,Sys.Console,Sys.Incoming,Sys.Modify,Sys.PowerMgmt,Sys.Syslog,User.Modify,VM.Allocate,VM.Audit,VM.Backup,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Console,VM.GuestAgent.Audit,VM.Migrate,VM.PowerMgmt,VM.Snapshot,VM.Snapshot.Rollback"),
    ("PVEAdmin", "Datastore.Allocate,Datastore.AllocateSpace,Datastore.Audit,Group.Allocate,Pool.Allocate,Pool.Audit,Sys.Audit,Sys.Console,Sys.Syslog,User.Modify,VM.Allocate,VM.Audit,VM.Backup,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Disk,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Console,VM.Migrate,VM.PowerMgmt,VM.Snapshot,VM.Snapshot.Rollback"),
    ("PVEAuditor", "Datastore.Audit,Mapping.Audit,Pool.Audit,SDN.Audit,Sys.Audit,VM.Audit,VM.GuestAgent.Audit"),
    ("PVEVMAdmin", "VM.Allocate,VM.Audit,VM.Backup,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Disk,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Console,VM.Migrate,VM.PowerMgmt,VM.Snapshot,VM.Snapshot.Rollback"),
    ("PVEVMUser", "VM.Audit,VM.Backup,VM.Config.CDROM,VM.Config.Cloudinit,VM.Console,VM.PowerMgmt"),
    ("PVEDatastoreAdmin", "Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit"),
    ("PVEDatastoreUser", "Datastore.AllocateSpace,Datastore.Audit"),
    ("PVEPoolAdmin", "Pool.Allocate,Pool.Audit"),
    ("PVEUserAdmin", "Group.Allocate,Realm.AllocateUser,User.Modify"),
    ("NoAccess", ""),
]


def add_guest(vmid, kind, node, name, status="stopped", cores=2, mem_mib=2048, disk_gib=32, tags="", ostype=None,
              template=0, agent=True, onboot=0, description=""):
    g = {
        "vmid": vmid, "type": kind, "node": node, "status": status, "template": template,
        "uptime_start": now() - random.Random(vmid).randint(3600, 40 * 86400) if status == "running" else None,
        "netin": 0, "netout": 0, "diskread": 0, "diskwrite": 0, "lock": None, "pending": {},
    }
    if kind == "qemu":
        g["config"] = {
            "name": name, "cores": cores, "sockets": 1, "memory": str(mem_mib), "cpu": "x86-64-v2-AES",
            "ostype": ostype or "l26", "scsihw": "virtio-scsi-single", "bios": "ovmf" if (ostype or "").startswith("win") else "seabios",
            "machine": "q35", "boot": "order=scsi0;ide2;net0", "numa": 0, "onboot": onboot,
            "scsi0": f"local-lvm:vm-{vmid}-disk-0,iothread=1,size={disk_gib}G",
            "ide2": "none,media=cdrom",
            "net0": f"virtio={mac(vmid)},bridge=vmbr0,firewall=1",
            "agent": "1" if agent else "0",
            "smbios1": f"uuid={__import__('uuid').UUID(int=vmid * 7919)}",
            "vmgenid": str(__import__("uuid").UUID(int=vmid * 104729)),
            "meta": "creation-qemu=9.2.0,ctime=1735689600",
        }
        if (ostype or "").startswith("win"):
            g["config"]["efidisk0"] = f"local-lvm:vm-{vmid}-disk-1,efitype=4m,pre-enrolled-keys=1,size=4M"
            g["config"]["tpmstate0"] = f"local-lvm:vm-{vmid}-disk-2,size=4M,version=v2.0"
        if vmid == 100:
            # A detached disk, as real servers often have one: its label is the longest in the hardware list.
            g["config"]["unused0"] = f"local-lvm:vm-{vmid}-disk-9"
    else:
        g["config"] = {
            "hostname": name, "cores": cores, "memory": mem_mib, "swap": 512, "arch": "amd64",
            "ostype": ostype or "debian", "unprivileged": 1, "features": "nesting=1", "onboot": onboot,
            "rootfs": f"local-lvm:vm-{vmid}-disk-0,size={disk_gib}G",
            "net0": f"name=eth0,bridge=vmbr0,firewall=1,hwaddr={mac(vmid)},ip=dhcp,type=veth",
        }
    if tags:
        g["config"]["tags"] = tags
    if description:
        g["config"]["description"] = description
    g["config"]["digest"] = hashlib.sha1(json.dumps(g["config"], sort_keys=True).encode()).hexdigest()
    GUESTS[vmid] = g
    SNAPSHOTS.setdefault(vmid, [])
    return g


def guest_name(g):
    return g["config"].get("name") or g["config"].get("hostname") or f"{'VM' if g['type'] == 'qemu' else 'CT'} {g['vmid']}"


def build_state():
    random.seed(7)
    if PROFILE == "stress":
        node_specs = [
            ("pve-alpha-rack-a-u12-primary-datacenter", "online", 64, 512),
            ("pve-beta", "online", 8, 16),
            ("pve-gamma", "offline", 24, 128),
        ]
    else:
        node_specs = [("pve1", "online", 32, 128), ("pve2", "online", 12, 64)]
    models = ["AMD Ryzen 9 5950X 16-Core Processor", "Intel(R) Xeon(R) E-2236 CPU @ 3.40GHz", "AMD EPYC 7443P 24-Core Processor"]
    for i, (name, status, cpus, mem) in enumerate(node_specs):
        NODES[name] = {
            "node": name, "status": status, "cpus": cpus, "maxmem": mem * GiB, "maxdisk": 94 * GiB,
            "boot": now() - (12 + i * 9) * 86400 - 3712, "model": models[i % len(models)], "ip": f"192.168.1.{10 + i}",
        }
        NODE_EXTRA[name] = {
            "description": "", "dns": {"search": "home.lan", "dns1": "192.168.1.1", "dns2": "1.1.1.1"},
            "hosts": f"127.0.0.1 localhost.localdomain localhost\n192.168.1.{10 + i} {name}.home.lan {name}\n\n# The following lines are desirable for IPv6 capable hosts\n::1     ip6-localhost ip6-loopback\nfe00::0 ip6-localnet\nff00::0 ip6-mcastprefix\nff02::1 ip6-allnodes\nff02::2 ip6-allrouters\n",
            "timezone": "Europe/Berlin",
            "services": {s: "running" for s in SERVICE_NAMES},
        }
        NODE_EXTRA[name]["services"]["postfix"] = "running"
        NODE_EXTRA[name]["services"]["spiceproxy"] = "running"
        NODE_EXTRA[name]["services"]["ksmtuned"] = "dead"
    first = list(NODES)[0]
    second = list(NODES)[1]

    if PROFILE == "stress":
        words = ["customer", "portal", "staging", "blue", "green", "canary", "analytics", "warehouse", "ingest",
                 "pipeline", "kafka", "broker", "elastic", "search", "redis", "cache", "gateway", "edge"]
        r = random.Random(42)
        vmid = 100
        for n in range(140):
            node = list(NODES)[n % 3]
            kind = "qemu" if n % 3 else "lxc"
            name = "-".join(r.choice(words) for _ in range(r.randint(1, 7))) + f"-{n:03d}"
            if n == 5:
                name = ""  # a VM with no name at all
            if n == 6:
                name = "x"
            status = "stopped" if node == "pve-gamma" else r.choice(["running", "running", "running", "stopped"])
            tags = ";".join(r.sample(["prod", "staging", "dev", "db", "web", "critical", "legacy", "k8s", "gpu",
                                      "backup-exempt", "customer-facing", "pci-dss"], r.randint(0, 6)))
            add_guest(vmid, kind, node, name, status, cores=r.choice([1, 2, 4, 8, 32, 128]),
                      mem_mib=r.choice([256, 2048, 8192, 65536, 1048576]), disk_gib=r.choice([2, 32, 512, 16384]),
                      tags=tags, template=1 if n in (20, 21) else 0)
            vmid += r.choice([1, 1, 7, 100])
    else:
        add_guest(100, "qemu", first, "web-frontend", "running", 4, 8192, 64, "prod;web", onboot=1,
                  description="# Web frontend\nNginx + Node 22 serving **shop.home.lan**.\n\n- Deploys from `main` via Gitea Actions\n- Health: https://shop.home.lan/health")
        add_guest(101, "qemu", first, "db-primary", "running", 8, 32768, 256, "prod;db", onboot=1,
                  description="PostgreSQL 17 primary. Replica lives on pve2 (backup-server snapshots nightly).")
        add_guest(102, "qemu", first, "win11-workstation", "stopped", 8, 16384, 128, "desktop", ostype="win11")
        add_guest(103, "qemu", first, "k3s-node-1", "running", 4, 8192, 48, "k8s")
        add_guest(104, "qemu", first, "k3s-node-2", "running", 4, 8192, 48, "k8s")
        add_guest(105, "qemu", first, "home-assistant", "running", 2, 4096, 32, "home", onboot=1)
        add_guest(106, "qemu", first, "truenas-scale", "paused", 4, 16384, 32, "storage")
        add_guest(9000, "qemu", first, "debian-12-cloudinit", "stopped", 2, 2048, 8, "template", template=1)
        add_guest(200, "lxc", first, "pihole", "running", 1, 512, 4, "dns;home", onboot=1)
        add_guest(201, "lxc", first, "nginx-proxy", "running", 1, 1024, 8, "web", onboot=1)
        add_guest(202, "lxc", first, "jellyfin", "running", 4, 4096, 32, "media")
        add_guest(203, "lxc", first, "gitea", "stopped", 2, 2048, 16, "dev")
        add_guest(110, "qemu", second, "backup-server", "running", 4, 8192, 64, "infra", onboot=1)
        add_guest(111, "qemu", second, "dev-sandbox", "stopped", 2, 4096, 32, "dev")
        add_guest(210, "lxc", second, "grafana", "running", 2, 2048, 8, "monitoring", onboot=1)
        add_guest(211, "lxc", second, "prometheus", "running", 2, 4096, 64, "monitoring", onboot=1)
        add_guest(212, "lxc", second, "unifi-controller", "running", 2, 2048, 16, "home;network")
        SNAPSHOTS[100] = [
            {"name": "pre-upgrade", "description": "Before Node 22 upgrade", "snaptime": now() - 9 * 86400, "vmstate": 0},
            {"name": "after-tls-rotation", "description": "Renewed certificates", "snaptime": now() - 2 * 86400, "vmstate": 1, "parent": "pre-upgrade"},
        ]
        SNAPSHOTS[101] = [{"name": "before-pg17", "description": "PostgreSQL 16 -> 17", "snaptime": now() - 20 * 86400, "vmstate": 0}]
        SNAPSHOTS[202] = [{"name": "clean-install", "description": "", "snaptime": now() - 40 * 86400}]

    STORAGES.update({
        "local": {"storage": "local", "type": "dir", "path": "/var/lib/vz", "content": "iso,vztmpl,backup,snippets,import", "shared": 0, "total": 94 * GiB},
        "local-lvm": {"storage": "local-lvm", "type": "lvmthin", "thinpool": "data", "vgname": "pve", "content": "images,rootdir", "shared": 0, "total": 832 * GiB},
        "nas-backup": {"storage": "nas-backup", "type": "nfs", "server": "192.168.1.20", "export": "/mnt/tank/pve", "path": "/mnt/pve/nas-backup", "content": "backup,iso", "shared": 1, "total": 3726 * GiB, "prune-backups": "keep-last=3,keep-weekly=4"},
        "tank": {"storage": "tank", "type": "zfspool", "pool": "tank", "content": "images,rootdir", "shared": 0, "nodes": first, "sparse": 1, "total": 1800 * GiB},
    })
    for node in NODES:
        CONTENT[(node, "local")] = [
            vol("local:iso/debian-12.7.0-amd64-netinst.iso", "iso", 631 * MiB, 30),
            vol("local:iso/ubuntu-24.04.1-live-server-amd64.iso", "iso", 2654 * MiB, 60),
            vol("local:iso/Win11_24H2_English_x64.iso", "iso", 5843 * MiB, 90),
            vol("local:iso/virtio-win-0.1.266.iso", "iso", 709 * MiB, 90),
            vol("local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst", "vztmpl", 120 * MiB, 50, fmt="tzst"),
            vol("local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst", "vztmpl", 141 * MiB, 50, fmt="tzst"),
            vol("local:vztmpl/alpine-3.20-default_20240908_amd64.tar.xz", "vztmpl", 3 * MiB, 20, fmt="txz"),
            vol("local:import/home-assistant-15.2.ova", "import", 512 * MiB, 7, fmt="ova"),
        ]
        CONTENT[(node, "local-lvm")] = []
        CONTENT[(node, "tank")] = []
    CONTENT[("shared", "nas-backup")] = []
    for g in GUESTS.values():
        disk = parse_size(g["config"].get("scsi0") or g["config"].get("rootfs") or "size=8G")
        CONTENT[(g["node"], "local-lvm")].append({
            "volid": f"local-lvm:vm-{g['vmid']}-disk-0", "format": "raw", "size": disk, "vmid": str(g["vmid"]),
            "content": "images" if g["type"] == "qemu" else "rootdir", "ctime": now() - 50 * 86400})
        if g["status"] == "running" and PROFILE != "stress":
            for days in (1, 2, 3):
                CONTENT[("shared", "nas-backup")].append(backup_vol("nas-backup", g, days))
    CONTENT[("shared", "nas-backup")].append(vol("nas-backup:iso/proxmox-backup-server_4.0-1.iso", "iso", 1374 * MiB, 10))
    if PROFILE != "stress":
        STORAGES["esxi-old"] = {"storage": "esxi-old", "type": "esxi", "server": "esxi.home.lan", "username": "root", "content": "import", "shared": 1, "total": 0}
        CONTENT[("shared", "esxi-old")] = [
            {"volid": f"esxi-old:ha-datacenter/datastore1/{name}/{name}.vmx", "content": "import", "format": "vmx", "size": 0, "ctime": now() - 400 * 86400}
            for name in ("win2019-dc", "web01", "legacy-erp")]
        STORAGES["pbs-offsite"] = {"storage": "pbs-offsite", "type": "pbs", "server": "192.168.1.40", "datastore": "homelab", "username": "backup@pbs",
                                   "content": "backup", "shared": 1, "total": 7450 * GiB}
        CONTENT[("shared", "pbs-offsite")] = [pbs_vol(g, days) for g in GUESTS.values() if g["status"] == "running" for days in (1, 8)]
    if CONTENT[("shared", "nas-backup")]:
        CONTENT[("shared", "nas-backup")][0]["protected"] = 1

    for path in ["cluster"] + [f"nodes/{n}" for n in NODES] + [f"guest/{v}" for v in GUESTS]:
        # Nodes have no policies of their own in PVE; the datacenter's apply.
        FIREWALL[path] = {"rules": [], "options": {"enable": 1} if path.startswith("node") else
                          {"enable": 0 if path.startswith("guest") else 1, "policy_in": "DROP", "policy_out": "ACCEPT"}}
    FIREWALL["cluster"]["rules"] = [
        rule("in", "ACCEPT", proto="tcp", dport="8006", source="192.168.1.0/24", comment="Web UI from LAN"),
        rule("in", "ACCEPT", macro="SSH", source="192.168.1.0/24", comment="SSH from LAN"),
        rule("in", "ACCEPT", macro="Ping", comment=""),
        rule("in", "DROP", source="10.66.0.0/16", comment="Guest VLAN may not reach the hosts", enable=0),
    ]
    if 100 in GUESTS:
        FIREWALL["guest/100"]["options"]["enable"] = 1
        FIREWALL["guest/100"]["rules"] = [rule("in", "ACCEPT", macro="HTTPS", comment="Public site"),
                                          rule("in", "ACCEPT", macro="HTTP", comment="Redirect to HTTPS")]

    BACKUP_JOBS.extend([
        {"id": "backup-7a1c2f9e-41d0", "type": "vzdump", "schedule": "sat 02:00", "storage": "nas-backup", "all": 1, "exclude": "102,111",
         "mode": "snapshot", "compress": "zstd", "enabled": 1, "notes-template": "{{guestname}}",
         "prune-backups": "keep-last=3,keep-weekly=4", "comment": "Weekly full backup", "mailnotification": "failure"},
        {"id": "backup-0b33e1d5-a9c2", "type": "vzdump", "schedule": "*-*-* 03:30", "storage": "local", "vmid": "101,110",
         "mode": "snapshot", "compress": "zstd", "enabled": 0, "notes-template": "{{guestname}} nightly", "comment": "Databases nightly"},
    ])
    if 101 in GUESTS:
        HA_RESOURCES.extend([{"sid": "vm:101", "type": "vm", "state": "started", "max_restart": 1, "max_relocate": 1, "comment": "Database must stay up"},
                             {"sid": "vm:110", "type": "vm", "state": "started", "max_restart": 1, "max_relocate": 1}])
    POOLS["production"] = {"comment": "Customer-facing services", "vms": [100, 101, 110], "storage": ["nas-backup"]}
    POOLS["lab"] = {"comment": "Things that are allowed to break", "vms": [102, 111, 203], "storage": []}

    USERS.update({
        "root@pam": {"userid": "root@pam", "enable": 1, "expire": 0, "email": "root@home.lan", "comment": "Built-in superuser", "groups": [], "tokens": {"proxima": {"comment": "Proxima on my Mac", "privsep": 0, "expire": 0}}},
        "admin@pve": {"userid": "admin@pve", "enable": 1, "expire": 0, "firstname": "Bergi", "lastname": "Mema", "email": "admin@home.lan", "comment": "Day-to-day admin (TOTP)", "groups": ["admins"], "tokens": {}},
        "automation@pve": {"userid": "automation@pve", "enable": 1, "expire": 0, "comment": "Terraform + Ansible", "groups": [], "tokens": {"terraform": {"comment": "CI pipeline", "privsep": 1, "expire": 0}}},
        "grafana@pve": {"userid": "grafana@pve", "enable": 1, "expire": 0, "comment": "Read-only metrics", "groups": ["monitoring"], "tokens": {}},
        "guest@pve": {"userid": "guest@pve", "enable": 0, "expire": now() + 30 * 86400, "comment": "Disabled until needed", "groups": [], "tokens": {}},
    })
    GROUPS.update({"admins": {"groupid": "admins", "comment": "Full administrators"}, "monitoring": {"groupid": "monitoring", "comment": "Dashboards and alerting"}})
    ACL.extend([
        {"path": "/", "type": "group", "ugid": "admins", "roleid": "Administrator", "propagate": 1},
        {"path": "/", "type": "group", "ugid": "monitoring", "roleid": "PVEAuditor", "propagate": 1},
        {"path": "/vms", "type": "user", "ugid": "automation@pve", "roleid": "PVEVMAdmin", "propagate": 1},
        {"path": "/", "type": "token", "ugid": "automation@pve!terraform", "roleid": "PVEVMAdmin", "propagate": 1},
        {"path": "/storage/nas-backup", "type": "user", "ugid": "automation@pve", "roleid": "PVEDatastoreUser", "propagate": 1},
    ])
    # Some finished history so the task list is not empty.
    for i, (kind, vid, ok) in enumerate([("vzdump", "", True), ("qmstart", "100", True), ("vzstart", "203", False),
                                          ("aptupdate", "", True), ("qmsnapshot", "100", True)]):
        if vid and int(vid) not in GUESTS:
            continue
        t = new_task(first, kind, vid, "root@pam", duration=None)
        t["starttime"] = now() - (i + 1) * 5400
        t["endtime"] = t["starttime"] + 37 + i * 11
        t["status"] = "OK" if ok else "startup for container '203' failed"
        t["log"] = [f"starting {kind}", "TASK OK" if ok else "TASK ERROR: " + t["status"]]


SERVICE_NAMES = ["corosync", "cron", "ksmtuned", "lxcfs", "postfix", "pve-cluster", "pve-firewall", "pve-ha-crm",
                 "pve-ha-lrm", "pvedaemon", "pvefw-logger", "pveproxy", "pvescheduler", "pvestatd", "qmeventd",
                 "rrdcached", "spiceproxy", "sshd", "chrony", "systemd-journald", "systemd-timesyncd"]
SERVICE_DESC = {"corosync": "Corosync Cluster Engine", "pve-cluster": "The Proxmox VE cluster filesystem",
                "pveproxy": "PVE API Proxy Server", "pvedaemon": "PVE API Daemon", "pvestatd": "PVE Status Daemon",
                "pve-firewall": "Proxmox VE firewall", "sshd": "OpenBSD Secure Shell server", "chrony": "chrony, an NTP client/server",
                "pvescheduler": "Proxmox VE scheduler", "spiceproxy": "PVE SPICE Proxy Server", "postfix": "Postfix Mail Transport Agent"}


def vol(volid, content, size, days_old, fmt=None):
    return {"volid": volid, "content": content, "size": size, "ctime": now() - days_old * 86400,
            "format": fmt or volid.rsplit(".", 1)[-1]}


def backup_vol(storage, g, days):
    t = time.gmtime(now() - days * 86400)
    stamp = time.strftime("%Y_%m_%d-02_00_%S", t)
    kind = "qemu" if g["type"] == "qemu" else "lxc"
    ext = "vma.zst" if kind == "qemu" else "tar.zst"
    return {"volid": f"{storage}:backup/vzdump-{kind}-{g['vmid']}-{stamp}.{ext}", "content": "backup", "format": ext,
            "size": int(parse_size(g["config"].get("scsi0") or g["config"].get("rootfs")) * 0.18),
            "ctime": now() - days * 86400, "vmid": g["vmid"], "subtype": kind, "notes": guest_name(g),
            "verification": {"state": "ok", "upid": ""} if days > 1 else None}


def pbs_vol(g, days):
    stamp = time.strftime("%Y-%m-%dT02:00:00Z", time.gmtime(now() - days * 86400))
    kind = "vm" if g["type"] == "qemu" else "ct"
    return {"volid": f"pbs-offsite:backup/{kind}/{g['vmid']}/{stamp}", "content": "backup", "format": f"pbs-{kind}",
            "size": int(parse_size(g["config"].get("scsi0") or g["config"].get("rootfs")) * 0.4), "ctime": now() - days * 86400,
            "vmid": g["vmid"], "subtype": g["type"], "notes": guest_name(g), "verification": {"state": "ok", "upid": ""}}


def rule(direction, action, enable=1, **kw):
    r = {"type": direction, "action": action, "enable": enable}
    r.update({k: v for k, v in kw.items() if v != ""})
    return r


def parse_size(s):
    m = re.search(r"size=(\d+(?:\.\d+)?)([KMGT]?)", s or "")
    if not m:
        return 8 * GiB
    mult = {"": 1, "K": 1024, "M": MiB, "G": GiB, "T": 1024 * GiB}[m.group(2)]
    return int(float(m.group(1)) * mult)


def fmt_size(b):
    for unit, mult in (("T", 1024 * GiB), ("G", GiB), ("M", MiB)):
        if b % mult == 0 and b >= mult:
            return f"{b // mult}{unit}"
    return f"{b // MiB}M"


# ---------------------------------------------------------------- tasks

def make_upid(node, kind, vid, user, start):
    pid = random.randint(1000, 999999)
    return f"UPID:{node}:{pid:08X}:{random.randint(0, 0xFFFFFFF):08X}:{start:08X}:{kind}:{vid}:{user}:"


def new_task(node, kind, vid, user, duration=2.0, on_done=None, log=None, fail=None):
    start = now()
    t = {"upid": make_upid(node, kind, vid, user, start), "node": node, "type": kind, "id": str(vid), "user": user,
         "starttime": start, "endtime": None, "status": None, "log": list(log or [f"task started by {user}"])}
    TASKS.insert(0, t)
    if duration is not None:
        def finish():
            with LOCK:
                err = fail
                if on_done and not err:
                    try:
                        on_done()
                    except ApiError as e:
                        err = e.message
                t["log"].append("TASK ERROR: " + err if err else "TASK OK")
                t["endtime"] = now()
                t["status"] = err or "OK"
        threading.Timer(duration, finish).start()
    return t


def require_guest(vmid, kind=None):
    g = GUESTS.get(int(vmid))
    if not g or (kind and g["type"] != kind):
        raise ApiError(500, f"Configuration file 'nodes/*/{'qemu-server' if kind == 'qemu' else 'lxc'}/{vmid}.conf' does not exist")
    return g


# ---------------------------------------------------------------- metrics

def wave(seed, t, base, amp, period=3600.0):
    r = random.Random(seed * 1000003 + int(t // 60))
    return max(0.0, base + amp * math.sin(2 * math.pi * t / period + seed) + r.uniform(-amp / 2.5, amp / 2.5))


def guest_live(g):
    vid = g["vmid"]
    running = g["status"] in ("running", "paused")
    mem = int(parse_mem(g) * (0.35 + 0.4 * wave(vid, time.time(), 0.6, 0.25, 900))) if running else 0
    cpu = wave(vid, time.time(), 0.06 + (vid % 7) * 0.03, 0.05, 300) if g["status"] == "running" else 0.0
    up = now() - g["uptime_start"] if running and g["uptime_start"] else 0
    total = (time.time() - START) + up
    return {"cpu": min(cpu, 1.0), "mem": min(mem, parse_mem(g)), "uptime": up,
            "netin": int(total * (40000 + vid * 113)) if running else 0, "netout": int(total * (21000 + vid * 71)) if running else 0,
            "diskread": int(total * (9000 + vid * 37)) if running else 0, "diskwrite": int(total * (15000 + vid * 51)) if running else 0}


def parse_mem(g):
    m = str(g["config"].get("memory", "2048"))
    m = m.split("current=")[-1].split(",")[0]
    return int(float(m)) * MiB


def guest_disk(g):
    return parse_size(g["config"].get("scsi0") or g["config"].get("rootfs"))


def rrd_points(timeframe):
    step = {"hour": 60, "day": 1800, "week": 10800, "month": 43200, "year": 604800, "decade": 6048000}.get(timeframe, 60)
    end = now() // step * step
    return [end - step * i for i in range(69, -1, -1)], step


def node_rrd(name, timeframe):
    n = NODES[name]
    seed = sum(map(ord, name))
    times, step = rrd_points(timeframe)
    out = []
    for t in times:
        if n["status"] == "offline" and t > now() - 3 * 3600:
            out.append({"time": t})
            continue
        cpu = wave(seed, t, 0.18, 0.12, 3600 if step < 600 else 86400)
        out.append({"time": t, "cpu": round(cpu, 5), "maxcpu": n["cpus"], "iowait": round(cpu * 0.08, 5),
                    "loadavg": round(cpu * n["cpus"] * 0.9, 2), "memtotal": n["maxmem"],
                    "memused": int(n["maxmem"] * wave(seed + 1, t, 0.55, 0.08, 7200)),
                    "memavailable": int(n["maxmem"] * (1 - wave(seed + 1, t, 0.55, 0.08, 7200))),
                    "swaptotal": 8 * GiB, "swapused": int(0.4 * GiB), "roottotal": n["maxdisk"], "rootused": int(n["maxdisk"] * 0.31),
                    "netin": round(wave(seed + 2, t, 2.1e6, 1.4e6, 1800), 2), "netout": round(wave(seed + 3, t, 0.9e6, 0.6e6, 2400), 2),
                    "arcsize": 8 * GiB, "pressurecpusome": round(cpu * 0.1, 4)})
    return out


def guest_rrd(g, timeframe):
    times, step = rrd_points(timeframe)
    out = []
    vid = g["vmid"]
    maxmem = parse_mem(g)
    for t in times:
        running = g["status"] == "running" and (not g["uptime_start"] or t >= g["uptime_start"])
        if not running:
            out.append({"time": t, "maxcpu": g["config"].get("cores", 1), "maxmem": maxmem, "maxdisk": guest_disk(g),
                        "cpu": 0, "mem": 0, "netin": 0, "netout": 0, "diskread": 0, "diskwrite": 0})
            continue
        out.append({"time": t, "cpu": round(wave(vid, t, 0.08 + (vid % 5) * 0.04, 0.07, 1200 if step < 600 else 86400), 5),
                    "maxcpu": g["config"].get("cores", 1), "mem": int(maxmem * wave(vid + 9, t, 0.5, 0.15, 3600)),
                    "maxmem": maxmem, "disk": 0, "maxdisk": guest_disk(g),
                    "netin": round(wave(vid + 2, t, 120000, 90000, 900), 2), "netout": round(wave(vid + 3, t, 60000, 50000, 1300), 2),
                    "diskread": round(wave(vid + 4, t, 40000, 35000, 700), 2), "diskwrite": round(wave(vid + 5, t, 90000, 60000, 500), 2)})
    return out


# ---------------------------------------------------------------- resources

def resource_list():
    out = []
    for name, n in NODES.items():
        online = n["status"] == "online"
        cpu = wave(sum(map(ord, name)), time.time(), 0.18, 0.12) if online else 0
        out.append({"id": f"node/{name}", "type": "node", "node": name, "status": n["status"],
                    "cpu": round(cpu, 5) if online else 0, "maxcpu": n["cpus"],
                    "mem": int(n["maxmem"] * 0.55) if online else 0, "maxmem": n["maxmem"],
                    "disk": int(n["maxdisk"] * 0.31) if online else 0, "maxdisk": n["maxdisk"],
                    "uptime": now() - n["boot"] if online else 0, "level": "", "cgroup-mode": 2})
    for g in GUESTS.values():
        live = guest_live(g)
        r = {"id": f"{g['type']}/{g['vmid']}", "type": g["type"], "vmid": g["vmid"], "name": guest_name(g),
             "node": g["node"], "status": "unknown" if NODES[g["node"]]["status"] != "online" else g["status"],
             "maxcpu": g["config"].get("cores", 1) * g["config"].get("sockets", 1), "maxmem": parse_mem(g),
             "maxdisk": guest_disk(g), "disk": 0 if g["type"] == "qemu" else int(guest_disk(g) * 0.4),
             "template": g["template"], **live}
        if g["config"].get("tags"):
            r["tags"] = g["config"]["tags"]
        if g.get("lock"):
            r["lock"] = g["lock"]
        if any(h["sid"] == f"{'vm' if g['type'] == 'qemu' else 'ct'}:{g['vmid']}" for h in HA_RESOURCES):
            r["hastate"] = "started"
        for pool, p in POOLS.items():
            if g["vmid"] in p["vms"]:
                r["pool"] = pool
        out.append(r)
    for sid, s in STORAGES.items():
        nodes = [s["nodes"]] if s.get("nodes") else list(NODES)
        for node in nodes:
            used = storage_used(node, sid)
            out.append({"id": f"storage/{node}/{sid}", "type": "storage", "storage": sid, "node": node,
                        "status": "available" if NODES[node]["status"] == "online" else "unknown",
                        "disk": used, "maxdisk": s["total"], "content": s["content"], "plugintype": s["type"],
                        "shared": s["shared"]})
    for pool in POOLS:
        out.append({"id": f"/pool/{pool}", "type": "pool", "pool": pool})
    for node in NODES:
        out.append({"id": f"sdn/{node}/localnetwork", "type": "sdn", "sdn": "localnetwork", "node": node, "status": "ok"})
    return out


def storage_used(node, sid):
    # Thin provisioning lets volumes add up to more than the storage holds; the real server reports what's allocated.
    return min(sum(v["size"] for v in content_for(node, sid)), int(STORAGES.get(sid, {}).get("total", 0) * 0.97))


def content_for(node, storage):
    if STORAGES.get(storage, {}).get("shared"):
        return CONTENT.setdefault(("shared", storage), [])
    return CONTENT.setdefault((node, storage), [])


# ---------------------------------------------------------------- routing

ROUTES = []


def route(method, pattern):
    def deco(fn):
        ROUTES.append((method, re.compile("^" + pattern + "$"), fn))
        return fn
    return deco


def guest_path(kind):
    return r"/nodes/(?P<node>[^/]+)/" + kind + r"/(?P<vmid>\d+)"


@route("GET", r"/version")
def version(p, u):
    return {"version": "9.0.11", "release": "9.0", "repoid": "3b6eab2a9f2bca4e"}


@route("GET", r"/access/domains")
def domains(p, u):
    return [{"realm": "pam", "type": "pam", "comment": "Linux PAM standard authentication"},
            {"realm": "pve", "type": "pve", "comment": "Proxmox VE authentication server", "default": 1}] + EXTRA_REALMS


@route("POST", r"/access/ticket")
def ticket(p, u):
    username = p.get("username", "")
    if "@" not in username and p.get("realm"):
        username = f"{username}@{p['realm']}"
    password = p.get("password", "")
    user = next((x for x in SEED["users"] if x["userid"] == username), None)
    if p.get("tfa-challenge"):
        if not user or p["tfa-challenge"] not in TICKETS or TICKETS[p["tfa-challenge"]][0] != "!tfa!" + username:
            raise ApiError(401, "authentication failure")
        kind, _, code = password.partition(":")
        if (kind == "totp" and code == user.get("totp")) or (kind == "recovery" and code == "proxima-recovery"):
            return issue_ticket(username)
        raise ApiError(401, "authentication failure")
    if password in TICKETS and TICKETS[password][0] == username:  # ticket renewal
        return issue_ticket(username)
    if not user or user["password"] != password:
        time.sleep(0.4)
        raise ApiError(401, "authentication failure")
    if user.get("totp") or user.get("webauthn"):
        offered = {"totp": True, "recovery": "available"} if user.get("totp") else {}
        if user.get("webauthn"):
            offered["webauthn"] = {"challenge": secrets.token_urlsafe(32), "timeout": 60000, "rpId": "pve.home.lan", "allowCredentials": [{"type": "public-key", "id": secrets.token_urlsafe(16)}]}
        challenge = "PVE:!tfa!" + urllib.parse.quote(json.dumps(offered)) + ":" + secrets.token_hex(8)
        TICKETS[challenge] = ("!tfa!" + username, "", time.time())
        return {"username": username, "ticket": challenge, "CSRFPreventionToken": "", "NeedTFA": 1}
    return issue_ticket(username)


@route("POST", r"/access/openid/auth-url")
def openid_auth_url(p, u):
    allow_only(p, "realm", "redirect-url")
    require(p, "realm", "redirect-url")
    realm = next((r for r in EXTRA_REALMS if r["realm"] == p["realm"] and r["type"] == "openid"), None)
    if not realm:
        raise ApiError(500, f"realm '{p['realm']}' is not an OpenID realm")
    state = secrets.token_urlsafe(16)
    OPENID_STATES[state] = (p["realm"], p["redirect-url"].rstrip("/"), None)
    return f"https://127.0.0.1:8006/mock-idp/authorize?client_id=proxmox&response_type=code&state={state}&redirect_uri={urllib.parse.quote(p['redirect-url'])}"


@route("POST", r"/access/openid/login")
def openid_login(p, u):
    allow_only(p, "code", "redirect-url", "state")
    require(p, "code", "redirect-url", "state")
    realm, redirect, code = OPENID_STATES.get(p["state"], (None, None, None))
    if not code or code != p["code"] or redirect != p["redirect-url"].rstrip("/"):
        raise ApiError(401, "authentication failure")
    del OPENID_STATES[p["state"]]
    userid = f"alice@{realm}"
    if userid not in USERS:
        USERS[userid] = {"userid": userid, "enable": 1, "expire": 0, "comment": "Created by OpenID sign-in"}
    return issue_ticket(userid)


def issue_ticket(username):
    stamp = f"{now():08X}"
    tick = f"PVE:{username}:{stamp}::" + base64.b64encode(secrets.token_bytes(48)).decode()
    csrf = f"{stamp}:" + base64.b64encode(secrets.token_bytes(20)).decode().rstrip("=")
    TICKETS[tick] = (username, csrf, time.time())
    return {"username": username, "ticket": tick, "CSRFPreventionToken": csrf, "clustername": "homelab",
            "cap": {"vms": {"VM.PowerMgmt": 1, "VM.Console": 1, "VM.Allocate": 1}, "nodes": {"Sys.PowerMgmt": 1, "Sys.Console": 1}}}


@route("PUT", r"/access/password")
def change_password(p, u):
    user = next((x for x in SEED["users"] if x["userid"] == p.get("userid")), None)
    if user:
        user["password"] = p["password"]
    return None


@route("GET", r"/cluster/status")
def cluster_status(p, u):
    out = [{"type": "cluster", "id": "cluster", "name": CLUSTER["name"], "version": 4, "nodes": len(NODES),
            "quorate": 1 if sum(n["status"] == "online" for n in NODES.values()) * 2 > len(NODES) else 0}] if CLUSTER["name"] else []
    for i, (name, n) in enumerate(NODES.items()):
        out.append({"type": "node", "id": f"node/{name}", "name": name, "nodeid": i + 1, "ip": n["ip"],
                    "online": 1 if n["status"] == "online" else 0, "local": 1 if i == 0 else 0, "level": ""})
    return out


@route("GET", r"/cluster/resources")
def cluster_resources(p, u):
    res = resource_list()
    t = p.get("type")
    if t == "vm":
        return [r for r in res if r["type"] in ("qemu", "lxc")]
    return [r for r in res if not t or r["type"] == t]


def task_summary(t):
    out = {k: t[k] for k in ("upid", "node", "type", "id", "user", "starttime")}
    out["pid"] = int(t["upid"].split(":")[2], 16)
    out["pstart"] = int(t["upid"].split(":")[3], 16)
    if t["endtime"]:
        out["endtime"], out["status"] = t["endtime"], t["status"]
    return out


@route("GET", r"/cluster/tasks")
def cluster_tasks(p, u):
    return [task_summary(t) for t in TASKS[:50]]


@route("GET", r"/cluster/nextid")
def nextid(p, u):
    vid = 100
    while vid in GUESTS:
        vid += 1
    if p.get("vmid"):
        if int(p["vmid"]) in GUESTS:
            raise ApiError(400, f"VM {p['vmid']} already exists", {"vmid": f"VM {p['vmid']} already exists"})
        return p["vmid"]
    return str(vid)


@route("GET", r"/cluster/options")
def cluster_options(p, u):
    return CLUSTER_OPTIONS


@route("PUT", r"/cluster/options")
def set_cluster_options(p, u):
    for k in p.get("delete", "").split(","):
        CLUSTER_OPTIONS.pop(k.strip(), None)
    CLUSTER_OPTIONS.update({k: v for k, v in p.items() if k != "delete"})


@route("GET", r"/nodes")
def nodes(p, u):
    return [r for r in resource_list() if r["type"] == "node"]


def online_node(node):
    if node not in NODES:
        raise ApiError(500, f"hostname lookup '{node}' failed - failed to get address info for: {node}: Name or service not known")
    if NODES[node]["status"] != "online":
        raise ApiError(595, f"No route to host")
    return NODES[node]


@route("GET", r"/nodes/(?P<node>[^/]+)/status")
def node_status(p, u, node):
    n = online_node(node)
    seed = sum(map(ord, node))
    cpu = wave(seed, time.time(), 0.18, 0.12)
    used = int(n["maxmem"] * 0.55)
    return {"cpu": round(cpu, 5), "wait": 0.0012, "uptime": now() - n["boot"],
            "loadavg": [f"{cpu * n['cpus'] * 0.9:.2f}", f"{cpu * n['cpus'] * 0.8:.2f}", f"{cpu * n['cpus'] * 0.7:.2f}"],
            "memory": {"total": n["maxmem"], "used": used, "free": n["maxmem"] - used, "available": n["maxmem"] - used},
            "swap": {"total": 8 * GiB, "used": int(0.4 * GiB), "free": int(7.6 * GiB)},
            "rootfs": {"total": n["maxdisk"], "used": int(n["maxdisk"] * 0.31), "free": int(n["maxdisk"] * 0.69), "avail": int(n["maxdisk"] * 0.64)},
            "cpuinfo": {"model": n["model"], "cpus": n["cpus"], "sockets": 1, "cores": n["cpus"] // 2, "mhz": "3399.998", "hvm": "1", "user_hz": 100, "flags": "fpu vme de pse tsc msr pae mce"},
            "kversion": "Linux 6.14.11-2-pve #1 SMP PREEMPT_DYNAMIC PMX 6.14.11-2 (2025-09-12T09:46Z)",
            "current-kernel": {"sysname": "Linux", "release": "6.14.11-2-pve", "machine": "x86_64", "version": "#1 SMP PREEMPT_DYNAMIC PMX 6.14.11-2 (2025-09-12T09:46Z)"},
            "pveversion": "pve-manager/9.0.11/3b6eab2a9f2bca4e", "ksm": {"shared": 0},
            "boot-info": {"mode": "efi", "secureboot": 0}, "idle": 0}


@route("POST", r"/nodes/(?P<node>[^/]+)/status")
def node_power(p, u, node):
    online_node(node)
    cmd = p.get("command")
    if cmd not in ("reboot", "shutdown"):
        raise ApiError(400, "Parameter verification failed.", {"command": "value 'x' does not have a value in the enumeration 'reboot, shutdown'"})
    return None  # a real node would now go away; the mock keeps running


@route("GET", r"/nodes/(?P<node>[^/]+)/rrddata")
def node_rrddata(p, u, node):
    if node not in NODES:
        raise ApiError(500, "no such node")
    return node_rrd(node, p.get("timeframe", "hour"))


@route("GET", r"/nodes/(?P<node>[^/]+)/config")
def node_config(p, u, node):
    online_node(node)
    return {**NODE_EXTRA[node].get("config", {}), "description": NODE_EXTRA[node]["description"], "digest": "f00d"}


@route("PUT", r"/nodes/(?P<node>[^/]+)/config")
def set_node_config(p, u, node):
    online_node(node)
    config = NODE_EXTRA[node].setdefault("config", {})
    for key, value in p.items():
        if key == "description":
            NODE_EXTRA[node]["description"] = value
        elif key not in ("delete", "digest"):
            config[key] = value
    for key in filter(None, p.get("delete", "").split(",")):
        if key == "description":
            NODE_EXTRA[node]["description"] = ""
        config.pop(key, None)


@route("GET", r"/nodes/(?P<node>[^/]+)/network")
def node_network(p, u, node):
    n = online_node(node)
    return [
        {"iface": "vmbr0", "type": "bridge", "active": 1, "autostart": 1, "method": "static", "method6": "manual",
         "address": n["ip"], "netmask": "24", "cidr": f"{n['ip']}/24", "gateway": "192.168.1.1",
         "bridge_ports": "enp5s0", "bridge_stp": "off", "bridge_fd": "0", "families": ["inet"], "priority": 3, "comments": "LAN"},
        {"iface": "vmbr1", "type": "bridge", "active": 1, "autostart": 1, "method": "manual", "method6": "manual",
         "bridge_ports": "", "bridge_stp": "off", "bridge_fd": "0", "bridge_vlan_aware": 1, "families": [], "priority": 4, "comments": "Internal VLAN-aware bridge"},
        {"iface": "enp5s0", "type": "eth", "active": 1, "exists": 1, "method": "manual", "method6": "manual", "families": ["inet"], "priority": 1},
        {"iface": "enp6s0", "type": "eth", "active": 0, "exists": 1, "method": "manual", "method6": "manual", "families": [], "priority": 2},
        {"iface": "wg0", "type": "unknown", "active": 1, "exists": 1, "method": "manual", "method6": "manual", "families": [], "priority": 5},
    ] + NETWORK_EXTRA.get(node, [])


@route("GET", r"/nodes/(?P<node>[^/]+)/disks/list")
def disks(p, u, node):
    online_node(node)
    taken = {osd["dev"] for osd in CEPH["osds"].values() if osd["host"] == node}
    listed = [d for d in disk_list() if d["devpath"] not in taken]
    if p.get("type") == "unused":
        return [d for d in listed if not d["used"]]
    if p.get("type") == "journal_disks":
        return [d for d in listed if d["type"] in ("ssd", "nvme")]
    return listed


def disk_list():
    return [
        {"devpath": "/dev/nvme0n1", "size": 1000204886016, "model": "Samsung SSD 980 PRO 1TB", "serial": "S5GXNF0R412345A", "type": "nvme",
         "health": "PASSED", "wearout": 97, "used": "LVM", "gpt": 1, "rpm": 0, "vendor": "", "wwn": "eui.002538b411b2c1a4", "osdid": -1, "by_id_link": "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNF0R412345A"},
        {"devpath": "/dev/sda", "size": 4000787030016, "model": "WDC_WD40EFRX-68N32N0", "serial": "WD-WCC7K0AB1234", "type": "hdd",
         "health": "PASSED", "wearout": "N/A", "used": "ZFS", "gpt": 1, "rpm": 5400, "vendor": "ATA", "wwn": "0x50014ee2b5a4c3d1", "osdid": -1},
        {"devpath": "/dev/sdb", "size": 4000787030016, "model": "WDC_WD40EFRX-68N32N0", "serial": "WD-WCC7K0AB5678", "type": "hdd",
         "health": "PASSED", "wearout": "N/A", "used": "ZFS", "gpt": 1, "rpm": 5400, "vendor": "ATA", "wwn": "0x50014ee2b5a4c3d2", "osdid": -1},
        {"devpath": "/dev/sdc", "size": 512110190592, "model": "CT500MX500SSD1", "serial": "2113E5912345", "type": "ssd",
         "health": "FAILED", "wearout": 12, "used": "", "gpt": 0, "rpm": 0, "vendor": "ATA", "wwn": "0x500a0751e5912345", "osdid": -1},
    ]


@route("GET", r"/nodes/(?P<node>[^/]+)/disks/smart")
def smart(p, u, node):
    online_node(node)
    failed = p.get("disk") == "/dev/sdc"
    return {"health": "FAILED" if failed else "PASSED", "type": "ata", "attributes": [
        {"id": "  5", "name": "Reallocated_Sector_Ct", "value": 1 if failed else 100, "worst": 1 if failed else 100, "threshold": 10, "fail": "FAILING_NOW" if failed else "-", "raw": "2048" if failed else "0", "flags": "PO--CK", "normalized": 100},
        {"id": "  9", "name": "Power_On_Hours", "value": 72, "worst": 72, "threshold": 0, "fail": "-", "raw": "24611", "flags": "-O--CK", "normalized": 72},
        {"id": "194", "name": "Temperature_Celsius", "value": 114, "worst": 103, "threshold": 0, "fail": "-", "raw": "36", "flags": "-O---K", "normalized": 114},
    ]}


@route("GET", r"/nodes/(?P<node>[^/]+)/disks/zfs")
def zfs(p, u, node):
    online_node(node)
    return disk_stores(node)["zfs"]


@route("GET", r"/nodes/(?P<node>[^/]+)/disks/zfs/(?P<name>[^/]+)")
def zfs_detail(p, u, node, name):
    online_node(node)
    pool = next((z for z in disk_stores(node)["zfs"] if z["name"] == name), None)
    if not pool:
        raise ApiError(500, f"zpool '{name}' does not exist")
    disks = [{"name": d, "state": "ONLINE", "read": 0, "write": 0, "cksum": 0, "leaf": 1} for d in ("ata-WDC_WD40EFRX-68N32N0_WD-WCC7K0AB1234", "ata-WDC_WD40EFRX-68N32N0_WD-WCC7K0AB5678")]
    return {"name": name, "state": pool["health"], "status": "", "action": "", "errors": "No known data errors",
            "scan": "scrub repaired 0B in 03:12:44 with 0 errors on Sun Oct 11 03:36:45 2026",
            "children": [{"name": name, "state": pool["health"], "read": 0, "write": 0, "cksum": 0, "leaf": 0,
                          "children": [{"name": "mirror-0", "state": "ONLINE", "read": 0, "write": 0, "cksum": 0, "leaf": 0, "children": disks}]}]}


@route("GET", r"/nodes/(?P<node>[^/]+)/services")
def services(p, u, node):
    online_node(node)
    out = []
    for name, state in NODE_EXTRA[node]["services"].items():
        out.append({"service": name, "name": name, "desc": SERVICE_DESC.get(name, f"{name} service"), "state": state,
                    "active-state": "active" if state == "running" else "inactive", "unit-state": "enabled" if name != "ksmtuned" else "disabled"})
    return sorted(out, key=lambda s: s["service"])


@route("POST", r"/nodes/(?P<node>[^/]+)/services/(?P<svc>[^/]+)/(?P<action>start|stop|restart|reload)")
def service_action(p, u, node, svc, action):
    online_node(node)
    if svc not in NODE_EXTRA[node]["services"]:
        raise ApiError(500, f"unknown service '{svc}'")
    def done():
        NODE_EXTRA[node]["services"][svc] = "dead" if action == "stop" else "running"
    return new_task(node, "srv" + action, svc, u, 1.2, done, [f"{action} service {svc}"])["upid"]


UPDATES = [
    ("pve-manager", "9.0.10", "9.0.11", "important", "The Proxmox Virtual Environment"),
    ("proxmox-kernel-6.14", "6.14.11-1", "6.14.11-2", "optional", "Latest Proxmox Kernel Image"),
    ("qemu-server", "9.0.21", "9.0.22", "optional", "Qemu Server Tools"),
    ("pve-container", "6.0.12", "6.0.13", "optional", "Proxmox VE Container management tool"),
    ("libpve-common-perl", "9.0.10", "9.0.11", "optional", "Proxmox VE base library"),
    ("zfsutils-linux", "2.3.4-pve1", "2.3.4-pve2", "optional", "command-line tools to manage OpenZFS filesystems"),
    ("openssh-server", "1:10.0p1-7", "1:10.0p1-7+deb13u1", "standard", "secure shell (SSH) server, for secure access from remote machines"),
]


@route("GET", r"/nodes/(?P<node>[^/]+)/apt/update")
def apt_list(p, u, node):
    online_node(node)
    return [{"Package": pkg, "OldVersion": old, "Version": new, "Priority": prio, "Section": "admin", "Origin": "Proxmox" if "pve" in pkg or "proxmox" in pkg or "qemu" in pkg else "Debian",
             "Arch": "amd64", "Title": title, "Description": title + "."} for pkg, old, new, prio, title in UPDATES]


@route("POST", r"/nodes/(?P<node>[^/]+)/apt/update")
def apt_refresh(p, u, node):
    online_node(node)
    return new_task(node, "aptupdate", "", u, 3.0, None, ["starting apt-get update", "Hit:1 http://deb.debian.org/debian trixie InRelease",
                                                          "Get:2 http://download.proxmox.com/debian/pve trixie InRelease [2,771 B]",
                                                          "Reading package lists...", "7 packages can be upgraded."])["upid"]


@route("GET", r"/nodes/(?P<node>[^/]+)/apt/changelog")
def apt_changelog(p, u, node):
    return f"{p.get('name')} ({dict((x[0], x[2]) for x in UPDATES).get(p.get('name'), '1.0')}) trixie; urgency=medium\n\n  * bump version, small fixes.\n\n -- Proxmox Support Team <support@proxmox.com>  Mon, 13 Oct 2026 10:12:44 +0200\n"


JOURNAL_PROCS = ["pvedaemon[2141]: <root@pam> successful auth for user 'root@pam'", "pveproxy[3021]: worker 3022 finished",
                 "systemd[1]: Started session-1234.scope - Session 1234 of User root.", "pvestatd[1955]: status update time (0.512 seconds)",
                 "kernel: vmbr0: port 3(tap100i0) entered forwarding state", "pmxcfs[1650]: [status] notice: received log",
                 "smartd[1144]: Device: /dev/sdc [SAT], FAILED SMART self-check. BACK UP DATA NOW!"]


@route("GET", r"/nodes/(?P<node>[^/]+)/journal")
def journal(p, u, node):
    """Like PVE's plain journal format: a cursor to page back first, a cursor to continue last, log lines between.
    One line a minute, so following with startcursor picks up new ones."""
    allow_only(p, "endcursor", "identifiers", "kernel", "lastentries", "priority", "service", "since", "startcursor", "structured", "unit", "units", "until")
    online_node(node)
    minute = now() // 60
    if p.get("startcursor"):
        first = int(p["startcursor"].split("=")[-1]) + 1
    else:
        first = minute - int(p.get("lastentries") or 50) + 1
    lines = [time.strftime("%b %d %H:%M:%S", time.localtime(m * 60)) + f" {node} " + JOURNAL_PROCS[m % len(JOURNAL_PROCS)] for m in range(first, minute + 1)]
    return [f"s=mock;i={first - 1}"] + lines + [f"s=mock;i={minute}"]


@route("GET", r"/nodes/(?P<node>[^/]+)/syslog")
def syslog(p, u, node):
    online_node(node)
    start, limit = int(p.get("start", 0)), int(p.get("limit", 500))
    procs = ["pvedaemon[2141]: <root@pam> successful auth for user 'root@pam'", "pveproxy[3021]: worker 3022 finished",
             "systemd[1]: Started session-1234.scope - Session 1234 of User root.", "pvestatd[1955]: status update time (0.512 seconds)",
             "kernel: vmbr0: port 3(tap100i0) entered forwarding state", "corosync[1730]:   [TOTEM ] Retransmit List: 1a",
             "pmxcfs[1650]: [status] notice: received log", "chronyd[1182]: Selected source 162.159.200.123 (2.debian.pool.ntp.org)",
             "smartd[1144]: Device: /dev/sdc [SAT], FAILED SMART self-check. BACK UP DATA NOW!", "CRON[44122]: (root) CMD (command -v debian-sa1 > /dev/null && debian-sa1 1 1)"]
    lines = []
    base = now() - 400 * 37
    for i in range(400):
        ts = time.strftime("%b %d %H:%M:%S", time.localtime(base + i * 37))
        lines.append({"n": i + 1, "t": f"{ts} {node} {procs[(i * 7) % len(procs)]}"})
    return lines[start:start + limit], {"total": len(lines)}


def find_task(upid):
    t = next((t for t in TASKS if t["upid"] == upid), None)
    if not t:
        raise ApiError(500, f"no such task '{upid}'")
    return t


@route("GET", r"/nodes/(?P<node>[^/]+)/tasks")
def node_tasks(p, u, node):
    items = [t for t in TASKS if t["node"] == node]
    if p.get("vmid"):
        items = [t for t in items if t["id"] == str(p["vmid"])]
    if p.get("errors") in ("1", "true"):
        items = [t for t in items if t["status"] and t["status"] != "OK"]
    start, limit = int(p.get("start", 0)), int(p.get("limit", 50))
    return [task_summary(t) for t in items[start:start + limit]], {"total": len(items)}


@route("GET", r"/nodes/(?P<node>[^/]+)/tasks/(?P<upid>[^/]+)/status")
def task_status(p, u, node, upid):
    t = find_task(urllib.parse.unquote(upid))
    out = task_summary(t)
    out["status"] = "stopped" if t["endtime"] else "running"
    if t["endtime"]:
        out["exitstatus"] = t["status"]
    return out


@route("GET", r"/nodes/(?P<node>[^/]+)/tasks/(?P<upid>[^/]+)/log")
def task_log(p, u, node, upid):
    t = find_task(urllib.parse.unquote(upid))
    start, limit = int(p.get("start", 0)), int(p.get("limit", 500))
    lines = [{"n": i + 1, "t": line} for i, line in enumerate(t["log"])]
    return lines[start:start + limit], {"total": len(lines)}


@route("DELETE", r"/nodes/(?P<node>[^/]+)/tasks/(?P<upid>[^/]+)")
def stop_task(p, u, node, upid):
    t = find_task(urllib.parse.unquote(upid))
    if not t["endtime"]:
        t["endtime"], t["status"] = now(), "interrupted by signal"
        t["log"].append("received interrupt")
        t["log"].append("TASK ERROR: interrupted by signal")


@route("GET", r"/nodes/(?P<node>[^/]+)/dns")
def dns(p, u, node):
    online_node(node)
    return NODE_EXTRA[node]["dns"]


def allow_only(p, *keys):
    """Like PVE: parameters the endpoint doesn't declare are refused (e.g. `delete` where there's none)."""
    extra = sorted(k for k in p if k not in keys)
    if extra:
        raise ApiError(400, "Parameter verification failed.",
                       {k: "property is not defined in schema and the schema does not allow additional properties" for k in extra})


@route("PUT", r"/nodes/(?P<node>[^/]+)/dns")
def set_dns(p, u, node):
    online_node(node)
    allow_only(p, "search", "dns1", "dns2", "dns3")
    if not p.get("search"):
        raise ApiError(400, "Parameter verification failed.", {"search": "property is missing and it is not optional"})
    NODE_EXTRA[node]["dns"] = {k: p[k] for k in ("search", "dns1", "dns2", "dns3") if p.get(k)}


@route("GET", r"/nodes/(?P<node>[^/]+)/hosts")
def hosts(p, u, node):
    online_node(node)
    return {"data": NODE_EXTRA[node]["hosts"], "digest": hashlib.sha1(NODE_EXTRA[node]["hosts"].encode()).hexdigest()}


@route("POST", r"/nodes/(?P<node>[^/]+)/hosts")
def set_hosts(p, u, node):
    online_node(node)
    NODE_EXTRA[node]["hosts"] = p.get("data", "")


@route("GET", r"/nodes/(?P<node>[^/]+)/time")
def node_time(p, u, node):
    online_node(node)
    return {"timezone": NODE_EXTRA[node]["timezone"], "time": now(), "localtime": now() + 7200}


@route("PUT", r"/nodes/(?P<node>[^/]+)/time")
def set_time(p, u, node):
    online_node(node)
    NODE_EXTRA[node]["timezone"] = p.get("timezone", "UTC")


@route("GET", r"/nodes/(?P<node>[^/]+)/certificates/info")
def certs(p, u, node):
    online_node(node)
    return [
        {"filename": "pve-root-ca.pem", "fingerprint": "4F:0A:1B:9C:22:D3:7E:15:A0:5B:6C:88:91:3E:4D:2A:7F:60:B1:C5:D8:E9:0F:12:34:56:78:9A:BC:DE:F0:11",
         "issuer": "/CN=Proxmox Virtual Environment/OU=c0ffee/O=PVE Cluster Manager CA", "subject": "/CN=Proxmox Virtual Environment/OU=c0ffee/O=PVE Cluster Manager CA",
         "notbefore": now() - 300 * 86400, "notafter": now() + 3350 * 86400, "public-key-type": "rsaEncryption", "public-key-bits": 4096, "san": []},
        {"filename": "pve-ssl.pem", "fingerprint": FINGERPRINT, "issuer": "/CN=Proxmox Virtual Environment/OU=c0ffee/O=PVE Cluster Manager CA",
         "subject": f"/OU=PVE Cluster Node/O=Proxmox Virtual Environment/CN={node}.home.lan", "notbefore": now() - 300 * 86400,
         "notafter": now() + 400 * 86400, "public-key-type": "rsaEncryption", "public-key-bits": 2048,
         "san": ["127.0.0.1", "0000:0000:0000:0000:0000:0000:0000:0001", "localhost", f"{node}.home.lan", NODES[node]["ip"]]},
    ]


@route("GET", r"/nodes/(?P<node>[^/]+)/subscription")
def subscription(p, u, node):
    return {"status": "notfound", "message": "There is no subscription key", "url": "https://www.proxmox.com/en/proxmox-virtual-environment/pricing"}


def bulk_targets(node, p):
    """The guests a bulk action covers: all of them (on that node), or the "vms" list (comma separated, or repeated keys)."""
    wanted = {int(v) for v in re.split(r"[,;\s\0]+", p.get("vms", "")) if v}
    return [g for g in GUESTS.values() if (node is None or g["node"] == node) and not g["template"] and (not wanted or int(g["vmid"]) in wanted)]


def bulk_apply(what, targets, p):
    for g in targets:
        if what in ("startall", "start") and g["status"] != "running" and (what == "start" or g["config"].get("onboot") or p.get("force")):
            g["status"], g["uptime_start"] = "running", now()
        if what in ("stopall", "shutdown"):
            g["status"], g["uptime_start"] = "stopped", None
        if what in ("suspendall", "suspend") and g["type"] == "qemu" and g["status"] == "running":
            g["status"] = "paused"


@route("POST", r"/nodes/(?P<node>[^/]+)/(?P<what>startall|stopall|suspendall)")
def bulk_power(p, u, node, what):
    allow_only(p, *{"startall": ("force", "max-workers", "vms"), "stopall": ("force-stop", "max-workers", "timeout", "vms"),
                     "suspendall": ("max-workers", "vms")}[what])
    online_node(node)
    targets = bulk_targets(node, p)
    return new_task(node, what, "", u, 3.0, lambda: bulk_apply(what, targets, p), [f"{what} for {len(targets)} guests"])["upid"]


@route("POST", r"/cluster/bulk-action/guest/(?P<what>start|shutdown|suspend|migrate)")
def cluster_bulk(p, u, what):
    allow_only(p, *{"start": ("max-workers", "maxworkers", "timeout", "vms"), "shutdown": ("force-stop", "max-workers", "maxworkers", "timeout", "vms"),
                     "suspend": ("max-workers", "maxworkers", "statestorage", "to-disk", "vms"),
                     "migrate": ("max-workers", "maxworkers", "online", "target", "vms", "with-local-disks")}[what])
    targets = bulk_targets(None, p)
    if what == "migrate":
        require(p, "target")
        online_node(p["target"])
        targets = [g for g in targets if g["node"] != p["target"]]
        def done():
            for g in targets:
                g["node"] = p["target"]
    else:
        done = lambda: bulk_apply(what, targets, p)
    return new_task(list(NODES)[0], f"bulk{what}", "", u, 3.0, done, [f"bulk {what} for {len(targets)} guests"])["upid"]


# ---------------------------------------------------------------- guests

def list_guests(node, kind):
    out = []
    for g in GUESTS.values():
        if g["node"] == node and g["type"] == kind:
            live = guest_live(g)
            out.append({"vmid": g["vmid"], "name": guest_name(g), "status": g["status"], "maxmem": parse_mem(g),
                        "maxdisk": guest_disk(g), "cpus": g["config"].get("cores", 1), "template": g["template"],
                        "tags": g["config"].get("tags", ""), **live})
    return out


@route("GET", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)")
def guests_on_node(p, u, node, kind):
    online_node(node)
    return list_guests(node, kind)


def guest_status(g):
    live = guest_live(g)
    out = {"vmid": g["vmid"] if g["type"] == "qemu" else str(g["vmid"]), "name": guest_name(g),
           "status": "running" if g["status"] == "paused" else g["status"],
           "cpus": g["config"].get("cores", 1), "maxmem": parse_mem(g), "maxdisk": guest_disk(g), "disk": 0,
           "ha": {"managed": 1, "state": "started"} if any(h["sid"].endswith(f":{g['vmid']}") for h in HA_RESOURCES) else {"managed": 0},
           "template": g["template"], **live}
    if g["config"].get("tags"):
        out["tags"] = g["config"]["tags"]
    if g["type"] == "qemu":
        out["qmpstatus"] = {"running": "running", "paused": "paused", "stopped": "stopped"}[g["status"]]
        out["agent"] = 1 if g["config"].get("agent") == "1" else 0
        if g["status"] in ("running", "paused"):
            out.update({"pid": 1000 + g["vmid"], "running-qemu": "9.2.0", "running-machine": "pc-q35-9.2+pve1",
                        "balloon": parse_mem(g), "freemem": parse_mem(g) - live["mem"]})
    else:
        out.update({"type": "lxc", "swap": 0, "maxswap": int(g["config"].get("swap", 512)) * MiB})
    if g.get("lock"):
        out["lock"] = g["lock"]
    return out


for kind in ("qemu", "lxc"):
    pass


@route("GET", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/status/current")
def current(p, u, node, kind, vmid):
    online_node(node)
    return guest_status(require_guest(vmid, kind))


GUEST_ACTIONS = {
    "qemu": {"start": "qmstart", "stop": "qmstop", "shutdown": "qmshutdown", "reboot": "qmreboot", "reset": "qmreset",
             "suspend": "qmsuspend", "resume": "qmresume"},
    "lxc": {"start": "vzstart", "stop": "vzstop", "shutdown": "vzshutdown", "reboot": "vzreboot", "suspend": "vzsuspend",
            "resume": "vzresume"},
}


@route("POST", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/status/(?P<action>[a-z]+)")
def guest_action(p, u, node, kind, vmid, action):
    online_node(node)
    g = require_guest(vmid, kind)
    task_type = GUEST_ACTIONS[kind].get(action)
    if not task_type:
        raise ApiError(501, f"Method 'POST /nodes/{node}/{kind}/{vmid}/status/{action}' not implemented")
    if g["template"]:
        raise ApiError(500, f"{'VM' if kind == 'qemu' else 'CT'} {vmid} is a template - unable to {action}")
    st = g["status"]
    label = f"{'VM' if kind == 'qemu' else 'CT'} {vmid}"
    if action == "start" and st != "stopped":
        raise ApiError(500, f"{label} already running")
    if action in ("stop", "shutdown", "reboot", "reset", "suspend") and st == "stopped":
        raise ApiError(500, f"{label} not running")
    if action == "resume" and st != "paused":
        raise ApiError(500, f"{label} not paused")
    if g.get("lock"):
        raise ApiError(500, f"{label} is locked ({g['lock']})")

    def done():
        if action in ("start", "reboot", "reset"):
            g["status"], g["uptime_start"] = "running", now()
            for k, v in list(g["pending"].items()):
                g["config"][k] = v
            g["pending"].clear()
        elif action in ("stop", "shutdown"):
            g["status"], g["uptime_start"] = "stopped", None
        elif action == "suspend":
            g["status"] = "paused"
        elif action == "resume":
            g["status"] = "running"
    duration = {"start": 2.0, "stop": 1.0, "shutdown": 3.5, "reboot": 4.0, "reset": 1.0, "suspend": 1.0, "resume": 1.0}[action]
    return new_task(node, task_type, vmid, u, duration, done, [f"{action} {label}", "requesting via QMP" if kind == "qemu" else "lxc-" + action])["upid"]


@route("GET", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/config")
def guest_config(p, u, node, kind, vmid):
    online_node(node)
    g = require_guest(vmid, kind)
    cfg = dict(g["config"])
    if p.get("current") not in ("1", "true"):
        cfg.update(g["pending"])
    return cfg


@route("GET", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/pending")
def guest_pending(p, u, node, kind, vmid):
    g = require_guest(vmid, kind)
    out = []
    for k, v in g["config"].items():
        item = {"key": k, "value": v}
        if k in g["pending"]:
            item["pending"] = g["pending"][k]
        out.append(item)
    return out


HOT = {"name", "hostname", "description", "tags", "onboot", "protection", "startup", "agent", "boot", "ostype", "nameserver", "searchdomain"}


@route("(PUT|POST)", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/config")
def set_guest_config(p, u, node, kind, vmid):
    online_node(node)
    g = require_guest(vmid, kind)
    if p.get("digest") and p["digest"] != g["config"].get("digest"):
        raise ApiError(500, "detected modified configuration - file changed by other user? Try again.")
    errors = {}
    for k in ("cores", "sockets", "memory", "swap"):
        if k in p and not re.fullmatch(r"\d+", str(p[k])):
            errors[k] = f"type check ('integer') failed - got '{p[k]}'"
    if "cores" in p and int(p["cores"] or 0) > 128:
        errors["cores"] = "value must have a maximum value of 128"
    if errors:
        raise ApiError(400, "Parameter verification failed.", errors)
    running = g["status"] != "stopped"
    for k, v in p.items():
        if k in ("delete", "digest", "node", "vmid", "revert"):
            continue
        if running and kind == "qemu" and k not in HOT:
            g["pending"][k] = v
        else:
            g["config"][k] = int(v) if re.fullmatch(r"\d+", str(v)) and k in ("cores", "sockets", "swap", "onboot", "numa") else v
    for k in [x.strip() for x in p.get("delete", "").split(",") if x.strip()]:
        g["config"].pop(k, None)
    for k in [x.strip() for x in p.get("revert", "").split(",") if x.strip()]:
        g["pending"].pop(k, None)
    g["config"]["digest"] = hashlib.sha1(json.dumps({k: v for k, v in g["config"].items() if k != "digest"}, sort_keys=True).encode()).hexdigest()
    return None


@route("PUT", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/resize")
def resize(p, u, node, kind, vmid):
    g = require_guest(vmid, kind)
    disk = p.get("disk")
    if disk not in g["config"]:
        raise ApiError(500, f"disk '{disk}' does not exist")
    m = re.fullmatch(r"(\+?)(\d+(?:\.\d+)?)([KMGT]?)", p.get("size", ""))
    if not m:
        raise ApiError(400, "Parameter verification failed.", {"size": "value does not match the regex pattern"})
    mult = {"": 1, "K": 1024, "M": MiB, "G": GiB, "T": 1024 * GiB}[m.group(3)]
    cur = parse_size(g["config"][disk])
    new = cur + int(float(m.group(2)) * mult) if m.group(1) else int(float(m.group(2)) * mult)
    if new < cur:
        raise ApiError(500, "shrinking disks is not supported")
    g["config"][disk] = re.sub(r"size=[^,]+", f"size={fmt_size(new)}", g["config"][disk])
    return new_task(node, "resize", vmid, u, 1.0)["upid"] if kind == "lxc" else None


@route("GET", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/rrddata")
def guest_rrddata(p, u, node, kind, vmid):
    return guest_rrd(require_guest(vmid, kind), p.get("timeframe", "hour"))


@route("GET", r"/nodes/(?P<node>[^/]+)/qemu/(?P<vmid>\d+)/agent/network-get-interfaces")
def agent_ifaces(p, u, node, vmid):
    g = require_guest(vmid, "qemu")
    if g["status"] != "running" or g["config"].get("agent") != "1":
        raise ApiError(500, "QEMU guest agent is not running")
    return {"result": [
        {"name": "lo", "hardware-address": "00:00:00:00:00:00", "ip-addresses": [{"ip-address": "127.0.0.1", "ip-address-type": "ipv4", "prefix": 8}]},
        {"name": "ens18", "hardware-address": mac(int(vmid)).lower(), "ip-addresses": [
            {"ip-address": f"192.168.1.{int(vmid) % 200 + 20}", "ip-address-type": "ipv4", "prefix": 24},
            {"ip-address": f"fe80::be24:11ff:fe{int(vmid) % 255:02x}:1{int(vmid) % 99:02d}", "ip-address-type": "ipv6", "prefix": 64}]},
    ]}


def require_agent(vmid):
    g = require_guest(vmid, "qemu")
    if g["status"] != "running" or g["config"].get("agent") != "1":
        raise ApiError(500, "QEMU guest agent is not running")
    return g


@route("GET", r"/nodes/(?P<node>[^/]+)/qemu/(?P<vmid>\d+)/agent/get-osinfo")
def agent_osinfo(p, u, node, vmid):
    g = require_agent(vmid)
    if g["config"].get("ostype", "").startswith("w"):
        return {"result": {"id": "mswindows", "name": "Microsoft Windows", "pretty-name": "Windows 11 Pro", "version": "Microsoft Windows 11",
                           "version-id": "11", "kernel-release": "26100", "kernel-version": "10.0", "machine": "x86_64",
                           "variant": "client", "variant-id": "client"}}
    return {"result": {"id": "debian", "name": "Debian GNU/Linux", "pretty-name": "Debian GNU/Linux 13 (trixie)", "version": "13 (trixie)",
                       "version-id": "13", "kernel-release": "6.12.48+deb13-amd64", "kernel-version": "#1 SMP PREEMPT_DYNAMIC Debian 6.12.48-1",
                       "machine": "x86_64"}}


@route("GET", r"/nodes/(?P<node>[^/]+)/qemu/(?P<vmid>\d+)/agent/get-fsinfo")
def agent_fsinfo(p, u, node, vmid):
    # Like a real guest: the root filesystem, the EFI partition, a snap image and a bind mount of the root disk.
    g = require_agent(vmid)
    disk = parse_size(g["config"].get("scsi0", ""))
    total = int(disk * 0.96)
    used = int(total * random.Random(int(vmid)).uniform(0.18, 0.97))
    if g["config"].get("ostype", "").startswith("w"):
        return {"result": [{"name": "Volume{d6cf1c2e-0000-0000-0000-100000000000}", "mountpoint": "C:\\", "type": "NTFS",
                            "total-bytes": total, "used-bytes": used, "disk": [{"bus-type": "scsi", "bus": 0, "target": 0, "unit": 0}]}]}
    root = {"bus-type": "scsi", "bus": 0, "target": 0, "unit": 0, "dev": "/dev/sda1"}
    return {"result": [
        {"name": "sda1", "mountpoint": "/", "type": "ext4", "total-bytes": total, "used-bytes": used, "disk": [root]},
        {"name": "sda15", "mountpoint": "/boot/efi", "type": "vfat", "total-bytes": 124_007_424, "used-bytes": 12_197_888, "disk": [root]},
        {"name": "loop0", "mountpoint": "/snap/core22/2045", "type": "squashfs", "total-bytes": 77_725_696, "used-bytes": 77_725_696, "disk": []},
        {"name": "sda1", "mountpoint": "/var/lib/docker/volumes", "type": "ext4", "total-bytes": total, "used-bytes": used, "disk": [root]},
    ]}


@route("GET", r"/nodes/(?P<node>[^/]+)/lxc/(?P<vmid>\d+)/interfaces")
def lxc_ifaces(p, u, node, vmid):
    g = require_guest(vmid, "lxc")
    if g["status"] != "running":
        raise ApiError(500, f"CT {vmid} not running")
    return [{"name": "lo", "hwaddr": "00:00:00:00:00:00", "inet": "127.0.0.1/8", "inet6": "::1/128"},
            {"name": "eth0", "hwaddr": mac(int(vmid)).lower(), "inet": f"192.168.1.{int(vmid) % 200 + 20}/24", "inet6": f"fe80::be24:11ff:fe00:{int(vmid)}/64"}]


@route("GET", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/snapshot")
def snapshots(p, u, node, kind, vmid):
    g = require_guest(vmid, kind)
    snaps = [dict(s) for s in SNAPSHOTS[g["vmid"]]]
    current = {"name": "current", "description": "You are here!", "running": 1 if g["status"] == "running" else 0}
    if snaps:
        current["parent"] = snaps[-1]["name"]
    return snaps + [current]


@route("POST", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/snapshot")
def create_snapshot(p, u, node, kind, vmid):
    g = require_guest(vmid, kind)
    name = p.get("snapname", "")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_\-]{1,39}", name):
        raise ApiError(400, "Parameter verification failed.", {"snapname": "invalid format - invalid configuration ID '" + name + "'"})
    if any(s["name"] == name for s in SNAPSHOTS[g["vmid"]]):
        raise ApiError(500, f"snapshot name '{name}' already used")
    def done():
        snap = {"name": name, "description": p.get("description", ""), "snaptime": now()}
        if kind == "qemu":
            snap["vmstate"] = 1 if p.get("vmstate") in ("1", "true") else 0
        if SNAPSHOTS[g["vmid"]]:
            snap["parent"] = SNAPSHOTS[g["vmid"]][-1]["name"]
        SNAPSHOTS[g["vmid"]].append(snap)
    return new_task(node, "qmsnapshot" if kind == "qemu" else "vzsnapshot", vmid, u, 2.0, done,
                    [f"snapshotting 'drive-scsi0' (local-lvm:vm-{vmid}-disk-0)", f"Logical volume \"snap_vm-{vmid}-disk-0_{name}\" created."])["upid"]


@route("DELETE", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/snapshot/(?P<name>[^/]+)")
def delete_snapshot(p, u, node, kind, vmid, name):
    g = require_guest(vmid, kind)
    snaps = SNAPSHOTS[g["vmid"]]
    if not any(s["name"] == name for s in snaps):
        raise ApiError(500, f"snapshot '{name}' does not exist")
    def done():
        parent = next(s for s in snaps if s["name"] == name).get("parent")
        for s in snaps:
            if s.get("parent") == name:
                s["parent"] = parent
                if not parent:
                    s.pop("parent")
        snaps[:] = [s for s in snaps if s["name"] != name]
    return new_task(node, "qmdelsnapshot" if kind == "qemu" else "vzdelsnapshot", vmid, u, 1.5, done)["upid"]


@route("POST", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/snapshot/(?P<name>[^/]+)/rollback")
def rollback(p, u, node, kind, vmid, name):
    g = require_guest(vmid, kind)
    snap = next((s for s in SNAPSHOTS[g["vmid"]] if s["name"] == name), None)
    if not snap:
        raise ApiError(500, f"snapshot '{name}' does not exist")
    def done():
        if snap.get("vmstate") or p.get("start") in ("1", "true"):
            g["status"], g["uptime_start"] = "running", now()
        else:
            g["status"], g["uptime_start"] = "stopped", None
        idx = SNAPSHOTS[g["vmid"]].index(snap)
        del SNAPSHOTS[g["vmid"]][idx + 1:]  # newer branch is still there in real PVE; keep the mock simple
    return new_task(node, "qmrollback" if kind == "qemu" else "vzrollback", vmid, u, 2.5, done)["upid"]


@route("POST", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/clone")
def clone(p, u, node, kind, vmid):
    g = require_guest(vmid, kind)
    newid = int(p.get("newid", 0))
    if newid in GUESTS or newid < 100:
        raise ApiError(500, f"unable to create {'VM' if kind == 'qemu' else 'CT'} {newid}: config file already exists")
    target = p.get("target") or node
    online_node(target)
    name = p.get("name") or p.get("hostname") or f"Copy-of-{guest_name(g)}"
    def done():
        c = add_guest(newid, kind, target, name, "stopped", g["config"].get("cores", 1), parse_mem(g) // MiB,
                      guest_disk(g) // GiB, g["config"].get("tags", ""))
        c["config"]["description"] = g["config"].get("description", "")
        CONTENT[(target, "local-lvm")].append({"volid": f"local-lvm:vm-{newid}-disk-0", "format": "raw", "size": guest_disk(g),
                                               "vmid": str(newid), "content": "images" if kind == "qemu" else "rootdir", "ctime": now()})
    g["lock"] = "clone"
    t = new_task(node, "qmclone" if kind == "qemu" else "vzclone", vmid, u, 4.0, done,
                 [f"create {'full' if p.get('full') in ('1', 'true') else 'linked'} clone of drive scsi0", "transferred 32.0 GiB of 32.0 GiB (100.00%)"])
    threading.Timer(4.05, lambda: g.pop("lock", None)).start()
    return t["upid"]


@route("GET", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/migrate")
def migrate_preconditions(p, u, node, kind, vmid):
    """What PVE checks before a migration: local disks and devices, and nodes that lack the guest's storage."""
    allow_only(p, "target")
    g = require_guest(vmid, kind)
    others = [n for n, info in NODES.items() if n != node and info["status"] == "online"]
    local = [k for k in g["config"] if re.match(r"^(hostpci|usb)\d+$", k) and "mapping=" not in g["config"][k]]
    disks = [{"volid": v.split(",")[0], "size": 32 * GiB, "drivename": k, "is_attached": 1}
             for k, v in g["config"].items() if re.match(r"^(scsi|virtio|sata|ide|efidisk|tpmstate)\d+$", k) and v.split(":")[0] in ("local-lvm", "local", "tank")]
    blocked = {n: {"unavailable_storages": ["tank"]} for n in others if any(d["volid"].startswith("tank:") for d in disks)}
    allowed = [n for n in others if n not in blocked]
    if kind == "lxc":
        return {"running": 1 if g["status"] == "running" else 0, "allowed-nodes": allowed, "not-allowed-nodes": blocked, "dependent-ha-resources": []}
    return {"running": 1 if g["status"] == "running" else 0, "allowed_nodes": allowed, "not_allowed_nodes": blocked, "local_disks": disks,
            "local_resources": local, "has-dbus-vmstate": 1, "mapped-resources": [], "dependent-ha-resources": []}


@route("POST", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/migrate")
def migrate(p, u, node, kind, vmid):
    allow_only(p, *(("bwlimit", "force", "migration_network", "migration_type", "online", "target", "targetstorage", "with-conntrack-state", "with-local-disks")
                    if kind == "qemu" else ("bwlimit", "online", "restart", "target", "target-storage", "timeout")))
    g = require_guest(vmid, kind)
    target = p.get("target")
    if not target or target == node:
        raise ApiError(400, "Parameter verification failed.", {"target": "target is local node."})
    online_node(target)
    if g["status"] == "running" and kind == "qemu" and p.get("online") not in ("1", "true"):
        raise ApiError(500, f"can't migrate running VM without --online")
    def done():
        g["node"] = target
    return new_task(node, "qmigrate" if kind == "qemu" else "vzmigrate", vmid, u, 5.0, done,
                    [f"starting migration of {'VM' if kind == 'qemu' else 'CT'} {vmid} to node '{target}' ({NODES[target]['ip']})",
                     "migration finished successfully (duration 00:00:05)"])["upid"]


@route("POST", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/template")
def to_template(p, u, node, kind, vmid):
    g = require_guest(vmid, kind)
    if g["status"] != "stopped":
        raise ApiError(500, "you can't convert a running VM to a template")
    def done():
        g["template"] = 1
    return new_task(node, "qmtemplate" if kind == "qemu" else "vztemplate", vmid, u, 1.5, done)["upid"]


@route("DELETE", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)")
def destroy(p, u, node, kind, vmid):
    g = require_guest(vmid, kind)
    if g["status"] != "stopped":
        raise ApiError(500, f"{'VM' if kind == 'qemu' else 'CT'} {vmid} is running - destroy failed")
    def done():
        GUESTS.pop(g["vmid"], None)
        for key in CONTENT:
            CONTENT[key] = [v for v in CONTENT[key] if not (v.get("content") in ("images", "rootdir") and str(v.get("vmid")) == str(vmid))]
        for pool in POOLS.values():
            if g["vmid"] in pool["vms"]:
                pool["vms"].remove(g["vmid"])
    return new_task(node, "qmdestroy" if kind == "qemu" else "vzdestroy", vmid, u, 2.0, done)["upid"]


@route("POST", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)")
def create_guest(p, u, node, kind):
    online_node(node)
    try:
        vmid = int(p.get("vmid", ""))
    except ValueError:
        raise ApiError(400, "Parameter verification failed.", {"vmid": "property is missing and it is not optional"})
    archive = p.get("archive") or (p.get("ostemplate") if p.get("restore") in ("1", "true") else None)
    if vmid in GUESTS and not (archive and p.get("force") in ("1", "true")):
        raise ApiError(500, f"unable to create {'VM' if kind == 'qemu' else 'CT'} {vmid} - VM {vmid} already exists on node '{GUESTS[vmid]['node']}'")
    if archive:
        def done():
            old = GUESTS.get(vmid)
            g = add_guest(vmid, kind, node, old and guest_name(old) or f"restored-{vmid}", "stopped",
                          old["config"].get("cores", 2) if old else 2, parse_mem(old) // MiB if old else 2048, 32)
            if p.get("start") in ("1", "true"):
                g["status"], g["uptime_start"] = "running", now()
        return new_task(node, "qmrestore" if kind == "qemu" else "vzrestore", vmid, u, 4.0, done,
                        [f"restore vma archive: {archive}", "progress 100% (read 34359738368 bytes, duration 3 sec)"])["upid"]
    errors = {}
    if kind == "lxc" and not p.get("ostemplate"):
        errors["ostemplate"] = "property is missing and it is not optional"
    if p.get("memory") and not re.fullmatch(r"\d+", p["memory"]):
        errors["memory"] = f"type check ('integer') failed - got '{p['memory']}'"
    if errors:
        raise ApiError(400, "Parameter verification failed.", errors)
    def done():
        disk_spec = p.get("scsi0") or p.get("virtio0") or p.get("sata0") or p.get("rootfs") or "local-lvm:8"
        m = re.match(r"([^:]+):(\d+)", disk_spec)
        size = int(m.group(2)) if m and int(m.group(2)) > 0 else (64 if "import-from" in disk_spec else 8)
        g = add_guest(vmid, kind, node, p.get("name") or p.get("hostname") or "", "stopped", int(p.get("cores", 1)),
                      int(p.get("memory", 512 if kind == "lxc" else 2048)), size, p.get("tags", ""), ostype=p.get("ostype"))
        for k in ("ide2", "net0", "agent", "cpu", "bios", "machine", "scsihw", "onboot", "description", "unprivileged", "features", "nameserver", "searchdomain", "swap"):
            if p.get(k) not in (None, ""):
                g["config"][k] = p[k]
        if p.get("start") in ("1", "true"):
            g["status"], g["uptime_start"] = "running", now()
        CONTENT[(node, "local-lvm")].append({"volid": f"local-lvm:vm-{vmid}-disk-0", "format": "raw", "size": size * GiB,
                                             "vmid": str(vmid), "content": "images" if kind == "qemu" else "rootdir", "ctime": now()})
    return new_task(node, "qmcreate" if kind == "qemu" else "vzcreate", vmid, u, 3.0, done,
                    [f"Logical volume \"vm-{vmid}-disk-0\" created.", "creating filesystem" if kind == "lxc" else "scsi0: successfully created disk"])["upid"]


# ---------------------------------------------------------------- storage

@route("GET", r"/storage")
def storage_config(p, u):
    out = []
    for s in STORAGES.values():
        out.append({k: v for k, v in s.items() if k != "total"} | {"digest": "abc"})
    return out


@route("GET", r"/storage/(?P<sid>[^/]+)")
def storage_one(p, u, sid):
    s = STORAGES.get(sid)
    if not s:
        raise ApiError(500, f"storage '{sid}' does not exist")
    return {k: v for k, v in s.items() if k != "total"} | {"digest": "abc"}


@route("PUT", r"/storage/(?P<sid>[^/]+)")
def set_storage(p, u, sid):
    s = STORAGES.get(sid)
    if not s:
        raise ApiError(500, f"storage '{sid}' does not exist")
    if "disable" in p:
        s["disable"] = int(p["disable"])
    for k in [x for x in p.get("delete", "").split(",") if x]:
        s.pop(k, None)
    if "content" in p:
        s["content"] = p["content"]


@route("GET", r"/nodes/(?P<node>[^/]+)/storage")
def node_storage(p, u, node):
    online_node(node)
    out = []
    for sid, s in STORAGES.items():
        if s.get("nodes") and s["nodes"] != node:
            continue
        if p.get("content") and p["content"] not in s["content"].split(","):
            continue
        used = storage_used(node, sid)
        out.append({"storage": sid, "type": s["type"], "content": s["content"], "shared": s["shared"], "active": 1,
                    "enabled": 0 if s.get("disable") else 1, "total": s["total"], "used": used, "avail": s["total"] - used,
                    "used_fraction": round(used / s["total"], 6)})
    return out


@route("GET", r"/nodes/(?P<node>[^/]+)/storage/(?P<sid>[^/]+)/status")
def storage_status(p, u, node, sid):
    s = STORAGES.get(sid) or {}
    if not s:
        raise ApiError(500, f"storage '{sid}' does not exist")
    used = storage_used(node, sid)
    return {"storage": sid, "type": s["type"], "content": s["content"], "shared": s["shared"], "active": 1, "enabled": 1,
            "total": s["total"], "used": used, "avail": s["total"] - used}


@route("GET", r"/nodes/(?P<node>[^/]+)/storage/(?P<sid>[^/]+)/rrddata")
def storage_rrd(p, u, node, sid):
    s = STORAGES.get(sid)
    if not s:
        raise ApiError(500, f"storage '{sid}' does not exist")
    used = storage_used(node, sid)
    times, step = rrd_points(p.get("timeframe", "day"))
    return [{"time": t, "total": s["total"], "used": int(used * (0.82 + 0.18 * i / len(times)))} for i, t in enumerate(times)]


@route("GET", r"/nodes/(?P<node>[^/]+)/storage/(?P<sid>[^/]+)/content")
def storage_content(p, u, node, sid):
    if sid not in STORAGES:
        raise ApiError(500, f"storage '{sid}' does not exist")
    items = content_for(node, sid)
    if p.get("content"):
        items = [v for v in items if v["content"] == p["content"]]
    if p.get("vmid"):
        items = [v for v in items if str(v.get("vmid")) == p["vmid"]]
    return [{k: v for k, v in x.items() if v is not None} for x in items]


def prune_marks(node, sid, p):
    """Marks one guest's backups keep/remove/protected like PVE::Storage::prune_mark_backup_group."""
    setting = p.get("prune-backups") or STORAGES[sid].get("prune-backups") or "keep-all=1"
    keep = {k: int(v) for k, v in (x.split("=") for x in setting.split(",") if "=" in x)}
    group = [v for v in content_for(node, sid) if v["content"] == "backup"
             and (not p.get("vmid") or str(v.get("vmid")) == p["vmid"]) and (not p.get("type") or v.get("subtype") == p["type"])]
    entries = sorted(({"volid": v["volid"], "ctime": v["ctime"], "vmid": v.get("vmid"), "type": v.get("subtype"),
                       "mark": "protected" if v.get("protected") else None} for v in group), key=lambda e: -e["ctime"])
    rules = [k for k in ("keep-last", "keep-hourly", "keep-daily", "keep-weekly", "keep-monthly", "keep-yearly") if keep.get(k, 0) > 0]
    if keep.get("keep-all") or not rules:
        for e in entries:
            e["mark"] = e["mark"] or "keep"
        return entries
    ids = {"keep-last": lambda t: t, "keep-hourly": lambda t: time.strftime("%Y/%m/%d/%H", time.localtime(t)),
           "keep-daily": lambda t: time.strftime("%Y/%m/%d", time.localtime(t)), "keep-weekly": lambda t: time.strftime("%G/%V", time.localtime(t)),
           "keep-monthly": lambda t: time.strftime("%Y/%m", time.localtime(t)), "keep-yearly": lambda t: time.strftime("%Y", time.localtime(t))}
    for rule in ("keep-last", "keep-hourly", "keep-daily", "keep-weekly", "keep-monthly", "keep-yearly"):
        count = keep.get(rule, 0)
        if not count:
            continue
        ident = ids[rule]
        already = {ident(e["ctime"]) for e in entries if e["mark"] == "keep"}
        newly = set()
        for e in entries:
            i = ident(e["ctime"])
            if e["mark"] or i in already:
                continue
            if i not in newly:
                if len(newly) >= count:
                    break
                newly.add(i)
                e["mark"] = "keep"
            else:
                e["mark"] = "remove"
    for e in entries:
        e["mark"] = e["mark"] or "remove"
    return entries


@route("GET", r"/nodes/(?P<node>[^/]+)/storage/(?P<sid>[^/]+)/prunebackups")
def prune_preview(p, u, node, sid):
    allow_only(p, "prune-backups", "type", "vmid")
    if sid not in STORAGES:
        raise ApiError(500, f"storage '{sid}' does not exist")
    return prune_marks(node, sid, p)


@route("DELETE", r"/nodes/(?P<node>[^/]+)/storage/(?P<sid>[^/]+)/prunebackups")
def prune_backups(p, u, node, sid):
    allow_only(p, "prune-backups", "type", "vmid")
    if sid not in STORAGES:
        raise ApiError(500, f"storage '{sid}' does not exist")
    doomed = {e["volid"] for e in prune_marks(node, sid, p) if e["mark"] == "remove"}
    items = content_for(node, sid)
    def done():
        items[:] = [v for v in items if v["volid"] not in doomed]
    return new_task(node, "prunebackups", sid, u, 1.5, done, log=[f"removing backup '{v}'" for v in sorted(doomed)] or ["nothing to prune"])["upid"]


@route("DELETE", r"/nodes/(?P<node>[^/]+)/storage/(?P<sid>[^/]+)/content/(?P<volume>.+)")
def delete_volume(p, u, node, sid, volume):
    volid = urllib.parse.unquote(volume)
    if ":" not in volid:
        volid = f"{sid}:{volid}"
    items = content_for(node, sid)
    v = next((x for x in items if x["volid"] == volid), None)
    if not v:
        raise ApiError(500, f"volume '{volid}' does not exist")
    if v.get("protected"):
        raise ApiError(500, "unable to remove protected backup - unset protection first")
    if v["content"] in ("images", "rootdir") and int(v.get("vmid", 0)) in GUESTS:
        raise ApiError(500, f"unable to delete '{volid}' - volume is still in use by VM {v['vmid']}")
    def done():
        items.remove(v)
    return new_task(node, "imgdel", volid, u, 1.0, done)["upid"]


@route("PUT", r"/nodes/(?P<node>[^/]+)/storage/(?P<sid>[^/]+)/content/(?P<volume>.+)")
def update_volume(p, u, node, sid, volume):
    volid = urllib.parse.unquote(volume)
    v = next((x for x in content_for(node, sid) if x["volid"] == volid), None)
    if not v:
        raise ApiError(500, f"volume '{volid}' does not exist")
    if "notes" in p:
        v["notes"] = p["notes"]
    if "protected" in p:
        v["protected"] = int(p["protected"])


@route("POST", r"/nodes/(?P<node>[^/]+)/storage/(?P<sid>[^/]+)/upload")
def upload(p, u, node, sid):
    content, f = p.get("content"), p.get("filename")
    if not isinstance(f, dict):
        raise ApiError(400, "Parameter verification failed.", {"filename": "property is missing and it is not optional"})
    if content not in ("iso", "vztmpl", "import"):
        raise ApiError(400, "Parameter verification failed.", {"content": f"value '{content}' does not have a value in the enumeration 'iso, vztmpl, import'"})
    if p.get("checksum"):
        algo = p.get("checksum-algorithm", "sha256")
        if hashlib.new(algo, f["data"]).hexdigest() != p["checksum"].lower():
            raise ApiError(500, "checksum mismatch")
    name = os.path.basename(f["filename"])
    items = content_for(node, sid)
    def done():
        items.append(vol(f"{sid}:{content}/{name}", content, len(f["data"]), 0))
    return new_task(node, "imgcopy", "", u, 1.0, done, [f"starting file import from: /var/tmp/pveupload-{secrets.token_hex(8)}",
                                                       f"target file: /var/lib/vz/template/{content}/{name}",
                                                       f"file size is: {len(f['data'])}", "finished file import successfully"])["upid"]


@route("POST", r"/nodes/(?P<node>[^/]+)/storage/(?P<sid>[^/]+)/download-url")
def download_url(p, u, node, sid):
    url, name, content = p.get("url", ""), p.get("filename", ""), p.get("content", "iso")
    if not url.startswith(("http://", "https://")):
        raise ApiError(400, "Parameter verification failed.", {"url": "invalid format - invalid URL"})
    if not name:
        raise ApiError(400, "Parameter verification failed.", {"filename": "property is missing and it is not optional"})
    items = content_for(node, sid)
    def done():
        items.append(vol(f"{sid}:{content}/{name}", content, 734 * MiB, 0))
    return new_task(node, "download", name, u, 4.0, done, [f"downloading {url} to /var/lib/vz/template/{content}/{name}.tmp.4123",
                                                          "--2026-10-20 00:12:01--  " + url, "Length: 769654784 (734M)", "download of '" + url + "' to '/var/lib/vz/template/" + content + "/" + name + "' finished"])["upid"]


OCI_TAGS = {"docker.io/library/nginx": ["latest", "stable", "mainline", "1.29", "1.29.1", "1.28", "1.28.0", "alpine", "stable-alpine"],
            "docker.io/library/alpine": ["latest", "edge", "3.22", "3.21", "3.20"],
            "ghcr.io/home-assistant/home-assistant": ["stable", "beta", "dev", "2025.10.2", "2025.10.1"]}


def oci_split(reference):
    """"nginx:1.29" -> ("docker.io/library/nginx", "1.29"); a tag follows the last colon after the last slash."""
    slash, colon = reference.rfind("/"), reference.rfind(":")
    ref, tag = (reference[:colon], reference[colon + 1:]) if colon > slash else (reference, "")
    first = ref.split("/")[0]
    if "/" not in ref or ("." not in first and ":" not in first and first != "localhost"):
        ref = "docker.io/" + (ref if "/" in ref else "library/" + ref)
    return ref, tag


@route("GET", r"/nodes/(?P<node>[^/]+)/query-oci-repo-tags")
def oci_tags(p, u, node):
    allow_only(p, "reference")
    require(p, "reference")
    ref, _ = oci_split(p["reference"])
    if ref not in OCI_TAGS:
        raise ApiError(500, f"failed to query tags: repository '{ref}' not found")
    return OCI_TAGS[ref]


@route("POST", r"/nodes/(?P<node>[^/]+)/storage/(?P<sid>[^/]+)/oci-registry-pull")
def oci_pull(p, u, node, sid):
    allow_only(p, "filename", "reference")
    require(p, "reference")
    ref, tag = oci_split(p["reference"])
    if not tag:
        raise ApiError(400, "Parameter verification failed.", {"reference": "reference must include a tag"})
    if ref not in OCI_TAGS or tag not in OCI_TAGS[ref]:
        raise ApiError(500, f"manifest unknown: {ref}:{tag}")
    name = (p.get("filename") or f"{ref.split('/')[-1]}_{tag}").replace(":", "_") + ".tar"
    items = content_for(node, sid)
    def done():
        items.append(vol(f"{sid}:vztmpl/{name}", "vztmpl", 78 * MiB, 0))
    return new_task(node, "download", name, u, 4.0, done, [f"Pulling {ref}:{tag}", "Copying blob sha256:1f3e46996e29 done", "Writing manifest to image destination",
                                                          f"Saved as /var/lib/vz/template/cache/{name}"])["upid"]


@route("GET", r"/nodes/(?P<node>[^/]+)/query-url-metadata")
def query_url(p, u, node):
    url = p.get("url", "")
    return {"filename": url.rstrip("/").rsplit("/", 1)[-1] or "download.iso", "size": 734 * MiB, "mimetype": "application/x-iso9660-image"}


APLINFO = [
    ("system", "debian-13-standard_13.1-1_amd64.tar.zst", "debian-13-standard", "13.1-1", "debian-13", "Debian 13 (standard)"),
    ("system", "ubuntu-25.04-standard_25.04-1.1_amd64.tar.zst", "ubuntu-25.04-standard", "25.04-1.1", "ubuntu-25.04", "Ubuntu 25.04 (standard)"),
    ("system", "alpine-3.22-default_20250617_amd64.tar.xz", "alpine-3.22-default", "20250617", "alpine-3.22", "Alpine Linux 3.22 (default)"),
    ("system", "rockylinux-9-default_20240912_amd64.tar.xz", "rockylinux-9-default", "20240912", "rockylinux-9", "Rocky Linux 9 (default)"),
    ("turnkeylinux", "debian-12-turnkey-nextcloud_18.2-1_amd64.tar.gz", "turnkey-nextcloud", "18.2-1", "debian-12", "TurnKey Nextcloud"),
    ("turnkeylinux", "debian-12-turnkey-wordpress_18.4-1_amd64.tar.gz", "turnkey-wordpress", "18.4-1", "debian-12", "TurnKey WordPress"),
]


@route("GET", r"/nodes/(?P<node>[^/]+)/aplinfo")
def aplinfo(p, u, node):
    return [{"section": s, "template": t, "package": pkg, "version": ver, "os": os_, "headline": head,
             "type": "lxc", "description": head + " container image.", "infopage": "https://pve.proxmox.com/wiki/Linux_Container",
             "location": f"http://download.proxmox.com/images/system/{t}", "sha512sum": hashlib.sha512(t.encode()).hexdigest()}
            for s, t, pkg, ver, os_, head in APLINFO]


@route("POST", r"/nodes/(?P<node>[^/]+)/aplinfo")
def download_template(p, u, node):
    t = p.get("template")
    sid = p.get("storage", "local")
    if t not in [x[1] for x in APLINFO]:
        raise ApiError(400, "Parameter verification failed.", {"template": f"no such template '{t}'"})
    items = content_for(node, sid)
    def done():
        items.append(vol(f"{sid}:vztmpl/{t}", "vztmpl", 126 * MiB, 0, fmt="tzst"))
    return new_task(node, "download", t, u, 3.0, done, [f"starting template download from: http://download.proxmox.com/images/system/{t}",
                                                       "download finished"])["upid"]


@route("POST", r"/nodes/(?P<node>[^/]+)/vzdump")
def vzdump(p, u, node):
    online_node(node)
    sid = p.get("storage", "local")
    if sid not in STORAGES:
        raise ApiError(400, "Parameter verification failed.", {"storage": f"storage '{sid}' does not exist"})
    if p.get("all") in ("1", "true"):
        targets = [g for g in GUESTS.values() if g["node"] == node and not g["template"]]
    else:
        ids = [int(x) for x in re.split(r"[,; ]+", p.get("vmid", "")) if x.strip()]
        if not ids:
            raise ApiError(400, "Parameter verification failed.", {"vmid": "you need to specify 'all' or 'vmid'"})
        targets = [GUESTS[i] for i in ids if i in GUESTS and GUESTS[i]["node"] == node]
    items = content_for(node, sid)
    def done():
        for g in targets:
            b = backup_vol(sid, g, 0)
            b["notes"] = (p.get("notes-template") or "{{guestname}}").replace("{{guestname}}", guest_name(g)).replace("{{vmid}}", str(g["vmid"])).replace("{{node}}", node)
            b["verification"] = None
            items.append(b)
        for g in targets:
            g.pop("lock", None)
    for g in targets:
        g["lock"] = "backup"
    log = [f"starting new backup job: vzdump {p.get('vmid', '--all 1')} --storage {sid} --mode {p.get('mode', 'snapshot')} --compress {p.get('compress', 'zstd')}"]
    log += [f"Starting Backup of VM {g['vmid']} ({g['type']})" for g in targets] + ["Backup job finished successfully"]
    return new_task(node, "vzdump", p.get("vmid", "") if len(targets) == 1 else "", u, 4.0, done, log)["upid"]


# ---------------------------------------------------------------- firewall

def fw_base(path):
    m = re.fullmatch(r"/cluster/sdn/vnets/([^/]+)/firewall", path)
    if m:
        return f"vnet/{m.group(1)}"
    m = re.fullmatch(r"/nodes/[^/]+/(?:qemu|lxc)/(\d+)/firewall", path)
    if m:
        return f"guest/{m.group(1)}"
    m = re.fullmatch(r"/nodes/([^/]+)/firewall", path)
    if m:
        return f"nodes/{m.group(1)}"
    return "cluster"


FW = r"(?P<base>/cluster/firewall|/nodes/[^/]+/firewall|/nodes/[^/]+/(?:qemu|lxc)/\d+/firewall|/cluster/sdn/vnets/[^/]+/firewall)"


@route("GET", FW + r"/rules")
def fw_rules(p, u, base):
    rules = FIREWALL.setdefault(fw_base(base), {"rules": [], "options": {}})["rules"]
    return [dict(r, pos=i) for i, r in enumerate(rules)]


def fw_level(base):
    return "cluster" if base == "/cluster/firewall" else "vnet" if base.startswith("/cluster/sdn/") else "guest" if re.search(r"/(qemu|lxc)/", base) else "node"


@route("POST", FW + r"/rules")
def fw_add(p, u, base):
    if p.get("type") not in ("in", "out", "forward", "group") or (not p.get("action")):
        raise ApiError(400, "Parameter verification failed.", {"action": "property is missing and it is not optional"} if not p.get("action") else {"type": "value does not have a value in the enumeration 'in, out, forward, group'"})
    # Like pve-firewall: guests filter their own traffic only, VNets only what they forward.
    if p["type"] == "forward" and fw_level(base) == "guest" or p["type"] in ("in", "out") and fw_level(base) == "vnet":
        raise ApiError(400, "Parameter verification failed.", {"type": f"{p['type']} rules are not allowed here"})
    rules = FIREWALL.setdefault(fw_base(base), {"rules": [], "options": {}})["rules"]
    r = {k: (int(v) if k == "enable" else v) for k, v in p.items() if k in ("type", "action", "enable", "source", "dest", "proto", "dport", "sport", "macro", "comment", "iface", "log") and v != ""}
    rules.insert(int(p.get("pos", 0)) if p.get("pos") else 0, r)


@route("PUT", FW + r"/rules/(?P<pos>\d+)")
def fw_update(p, u, base, pos):
    rules = FIREWALL[fw_base(base)]["rules"]
    pos = int(pos)
    if pos >= len(rules):
        raise ApiError(500, "no rule at position " + str(pos))
    if "moveto" in p:
        r = rules.pop(pos)
        rules.insert(min(int(p["moveto"]), len(rules)), r)
        return None
    for k, v in p.items():
        if k in ("delete", "digest"):
            continue
        rules[pos][k] = int(v) if k == "enable" else v
    for k in [x for x in p.get("delete", "").split(",") if x]:
        rules[pos].pop(k, None)


@route("DELETE", FW + r"/rules/(?P<pos>\d+)")
def fw_delete(p, u, base, pos):
    rules = FIREWALL[fw_base(base)]["rules"]
    if int(pos) >= len(rules):
        raise ApiError(500, "no rule at position " + pos)
    rules.pop(int(pos))


@route("GET", FW + r"/options")
def fw_options(p, u, base):
    return FIREWALL.setdefault(fw_base(base), {"rules": [], "options": {}})["options"]


FW_OPTION_KEYS = {  # what PVE accepts at each level; nodes have no policies of their own
    "cluster": ("ebtables", "enable", "log_ratelimit", "policy_forward", "policy_in", "policy_out"),
    "node": ("enable", "log_level_forward", "log_level_in", "log_level_out", "log_nf_conntrack", "ndp", "nf_conntrack_allow_invalid",
             "nf_conntrack_helpers", "nf_conntrack_max", "nf_conntrack_tcp_timeout_established", "nf_conntrack_tcp_timeout_syn_recv", "nftables",
             "nosmurfs", "protection_synflood", "protection_synflood_burst", "protection_synflood_rate", "smurf_log_level", "tcp_flags_log_level", "tcpflags"),
    "guest": ("dhcp", "enable", "ipfilter", "log_level_in", "log_level_out", "macfilter", "ndp", "policy_in", "policy_out", "radv"),
    "vnet": ("enable", "log_level_forward", "policy_forward"),
}


@route("PUT", FW + r"/options")
def fw_set_options(p, u, base):
    allow_only(p, "delete", "digest", *FW_OPTION_KEYS[fw_level(base)])
    opts = FIREWALL.setdefault(fw_base(base), {"rules": [], "options": {}})["options"]
    opts.update({k: (int(v) if k == "enable" else v) for k, v in p.items() if k not in ("delete", "digest")})
    for k in filter(None, p.get("delete", "").split(",")):
        opts.pop(k, None)


# ---------------------------------------------------------------- cluster objects

@route("GET", r"/cluster/backup/(?P<jid>[^/]+)/included_volumes")
def backup_included(p, u, jid):
    """Which guests and disks a backup job covers, as PVE's tree for the job detail window."""
    job = next((j for j in BACKUP_JOBS if j["id"] == jid), None)
    if not job:
        raise ApiError(500, f"job '{jid}' does not exist")
    if job.get("all"):
        excluded = {int(x) for x in str(job.get("exclude") or "").split(",") if x}
        vmids = [v for v in sorted(GUESTS) if int(v) not in excluded]
    elif job.get("pool"):
        vmids = [v for v in sorted(GUESTS) if GUESTS[v].get("pool") == job["pool"]]
    else:
        vmids = [v for v in sorted(GUESTS) if str(v) in str(job.get("vmid") or "").split(",")]
    if job.get("node"):
        vmids = [v for v in vmids if GUESTS[v]["node"] == job["node"]]
    disk = re.compile(r"^(scsi|virtio|sata|ide|efidisk|tpmstate|rootfs|mp)\d*$")
    children = []
    for v in vmids:
        g, volumes = GUESTS[v], []
        for key, value in sorted(g["config"].items()):
            if not disk.match(key) or not isinstance(value, str) or "media=cdrom" in value:
                continue
            name = value.split(",")[0]
            if "backup=0" in value or (key.startswith("mp") and "backup=1" not in value):
                volumes.append({"id": key, "name": name, "included": 0, "reason": "disabled"})
            else:
                volumes.append({"id": key, "name": name, "included": 1, "reason": "enabled" if "backup=1" in value else "default"})
        children.append({"id": int(v), "name": guest_name(g), "type": g["type"], "children": volumes})
    return {"children": children}


@route("GET", r"/nodes/(?P<node>[^/]+)/apt/versions")
def apt_versions(p, u, node):
    online_node(node)
    packages = [("proxmox-ve", "9.0.0"), ("pve-manager", "9.0.11"), ("proxmox-kernel-helper", "9.0.4"), ("proxmox-kernel-6.14", "6.14.11-2"),
                ("ceph-fuse", "19.2.3-pve1"), ("corosync", "3.1.9-pve2"), ("criu", "4.1-1"), ("ifupdown2", "3.3.0-1+pmx10"),
                ("libpve-access-control", "9.0.3"), ("libpve-common-perl", "9.0.10"), ("libpve-network-perl", "1.1.8"),
                ("libpve-storage-perl", "9.0.13"), ("lxc-pve", "6.0.5-1"), ("proxmox-backup-client", "4.0.15-1"),
                ("proxmox-widget-toolkit", "5.0.6"), ("pve-firewall", "6.0.3"), ("pve-firmware", "3.16-3"), ("pve-ha-manager", "5.0.5"),
                ("pve-qemu-kvm", "10.0.2-4"), ("qemu-server", "9.0.21"), ("smartmontools", "7.4-pve1"), ("zfsutils-linux", "2.3.4-pve1")]
    return [{"Package": n, "Version": v, "OldVersion": v, "CurrentState": "Installed", "Title": "", "Section": "admin", "Arch": "amd64", "Origin": "Proxmox",
             "Priority": "optional", **({"RunningKernel": "6.14.11-2-pve"} if n == "proxmox-ve" else {}),
             **({"ManagerVersion": "9.0.11/3bf5476b8a4699e2"} if n == "pve-manager" else {})} for n, v in packages]


@route("GET", r"/cluster/backup")
def backup_jobs(p, u):
    out = []
    for j in BACKUP_JOBS:
        job = dict(j)
        if job.get("enabled"):
            job["next-run"] = now() + 3 * 86400 + 7200
        out.append(job)
    return out


@route("POST", r"/cluster/backup")
def add_backup_job(p, u):
    if not p.get("schedule") or not p.get("storage"):
        raise ApiError(400, "Parameter verification failed.", {"schedule": "property is missing and it is not optional"} if not p.get("schedule") else {"storage": "property is missing and it is not optional"})
    job = {"id": "backup-" + secrets.token_hex(4) + "-" + secrets.token_hex(2), "type": "vzdump"}
    job.update({k: (int(v) if k in ("enabled", "all") else v) for k, v in p.items()})
    BACKUP_JOBS.append(job)


@route("GET", r"/cluster/backup/(?P<jid>[^/]+)")
def get_backup_job(p, u, jid):
    j = next((j for j in BACKUP_JOBS if j["id"] == jid), None)
    if not j:
        raise ApiError(500, f"Job '{jid}' does not exist")
    return j


@route("PUT", r"/cluster/backup/(?P<jid>[^/]+)")
def update_backup_job(p, u, jid):
    j = get_backup_job(p, u, jid)
    for k in [x for x in p.get("delete", "").split(",") if x]:
        j.pop(k, None)
    j.update({k: (int(v) if k in ("enabled", "all") else v) for k, v in p.items() if k != "delete"})


@route("DELETE", r"/cluster/backup/(?P<jid>[^/]+)")
def delete_backup_job(p, u, jid):
    j = get_backup_job(p, u, jid)
    BACKUP_JOBS.remove(j)


@route("GET", r"/cluster/ha/resources")
def ha_resources(p, u):
    return HA_RESOURCES


@route("POST", r"/cluster/ha/resources")
def add_ha(p, u):
    sid = p.get("sid", "")
    if not re.fullmatch(r"(vm|ct):\d+|\d+", sid):
        raise ApiError(400, "Parameter verification failed.", {"sid": "unable to parse service id"})
    if sid.isdigit():
        g = GUESTS.get(int(sid))
        sid = f"{'vm' if not g or g['type'] == 'qemu' else 'ct'}:{sid}"
    if any(h["sid"] == sid for h in HA_RESOURCES):
        raise ApiError(500, f"resource ID '{sid}' already defined")
    HA_RESOURCES.append({"sid": sid, "type": sid.split(":")[0], "state": p.get("state", "started"), "max_restart": int(p.get("max_restart", 1)),
                         "max_relocate": int(p.get("max_relocate", 1)), **({"comment": p["comment"]} if p.get("comment") else {})})


@route("PUT", r"/cluster/ha/resources/(?P<sid>[^/]+)")
def update_ha(p, u, sid):
    sid = urllib.parse.unquote(sid)
    h = next((h for h in HA_RESOURCES if h["sid"] == sid), None)
    if not h:
        raise ApiError(500, f"no such resource '{sid}'")
    h.update({k: v for k, v in p.items() if k in ("state", "comment", "max_restart", "max_relocate")})


@route("DELETE", r"/cluster/ha/resources/(?P<sid>[^/]+)")
def delete_ha(p, u, sid):
    sid = urllib.parse.unquote(sid)
    before = len(HA_RESOURCES)
    HA_RESOURCES[:] = [h for h in HA_RESOURCES if h["sid"] != sid]
    if len(HA_RESOURCES) == before:
        raise ApiError(500, f"no such resource '{sid}'")


HA_ARMING = {"state": "armed", "mode": None}


@route("POST", r"/cluster/ha/status/disarm-ha")
def ha_disarm(p, u):
    allow_only(p, "resource-mode")
    if p.get("resource-mode") not in ("freeze", "ignore"):
        raise ApiError(400, "Parameter verification failed.", {"resource-mode": "value must be 'freeze' or 'ignore'"})
    HA_ARMING.update(state="disarmed", mode=p["resource-mode"])


@route("POST", r"/cluster/ha/status/arm-ha")
def ha_arm(p, u):
    HA_ARMING.update(state="armed", mode=None)


@route("GET", r"/cluster/ha/status/current")
def ha_status(p, u):
    first = list(NODES)[0]
    out = [{"id": "quorum", "type": "quorum", "status": "OK", "quorate": 1, "node": first},
           {"id": "master", "type": "master", "status": f"{first} (active, {time.strftime('%a %b %d %H:%M:%S %Y')})", "node": first},
           {"id": "fencing", "type": "fencing", "armed-state": HA_ARMING["state"], **({"resource_mode": HA_ARMING["mode"]} if HA_ARMING["mode"] else {}),
            "status": "disarmed (" + HA_ARMING["mode"] + ")" if HA_ARMING["mode"] else "armed"}]
    for n, info in NODES.items():
        out.append({"id": f"lrm:{n}", "type": "lrm", "node": n,
                    "status": f"{n} ({'active' if info['status'] == 'online' else 'old timestamp - dead?'}, {time.strftime('%a %b %d %H:%M:%S %Y')})"})
    for h in HA_RESOURCES:
        vid = int(h["sid"].split(":")[1])
        g = GUESTS.get(vid)
        out.append({"id": f"service:{h['sid']}", "sid": h["sid"], "type": "service", "node": g["node"] if g else first,
                    "state": h["state"], "crm_state": h["state"], "request_state": h["state"],
                    "status": f"{h['sid']} ({g['node'] if g else first}, {h['state']})"})
    return out


@route("GET", r"/pools")
def pools(p, u):
    if p.get("poolid"):
        return [pool_detail(p["poolid"])]
    return [{"poolid": k, "comment": v["comment"]} for k, v in POOLS.items()]


def pool_detail(poolid):
    pool = POOLS.get(poolid)
    if not pool:
        raise ApiError(500, f"pool '{poolid}' does not exist")
    members = [r for r in resource_list() if r["type"] in ("qemu", "lxc") and r["vmid"] in pool["vms"]]
    members += [r for r in resource_list() if r["type"] == "storage" and r["storage"] in pool["storage"]]
    return {"poolid": poolid, "comment": pool["comment"], "members": members}


@route("GET", r"/pools/(?P<poolid>[^/]+)")
def get_pool(p, u, poolid):
    return pool_detail(poolid)


@route("POST", r"/pools")
def add_pool(p, u):
    poolid = p.get("poolid", "")
    if not re.fullmatch(r"[A-Za-z0-9.\-_]+", poolid):
        raise ApiError(400, "Parameter verification failed.", {"poolid": "invalid format - invalid pool ID"})
    if poolid in POOLS:
        raise ApiError(500, f"pool '{poolid}' already exists")
    POOLS[poolid] = {"comment": p.get("comment", ""), "vms": [], "storage": []}


@route("PUT", r"/pools/(?P<poolid>[^/]+)")
def update_pool(p, u, poolid):
    pool = POOLS.get(poolid)
    if not pool:
        raise ApiError(500, f"pool '{poolid}' does not exist")
    if "comment" in p:
        pool["comment"] = p["comment"]
    vms = [int(x) for x in p.get("vms", "").split(",") if x.strip()]
    if p.get("delete") in ("1", "true"):
        pool["vms"] = [v for v in pool["vms"] if v not in vms]
    else:
        pool["vms"] += [v for v in vms if v not in pool["vms"]]


@route("DELETE", r"/pools/(?P<poolid>[^/]+)")
def delete_pool(p, u, poolid):
    pool = POOLS.get(poolid)
    if not pool:
        raise ApiError(500, f"pool '{poolid}' does not exist")
    if pool["vms"] or pool["storage"]:
        raise ApiError(500, "pool not empty")
    del POOLS[poolid]


# ---------------------------------------------------------------- access

@route("GET", r"/access/users")
def users(p, u):
    out = []
    for x in USERS.values():
        item = {k: v for k, v in x.items() if k != "tokens"}
        item["realm-type"] = x["userid"].split("@")[1]
        if p.get("full") in ("1", "true"):
            item["tokens"] = [{"tokenid": tid, **t} for tid, t in x["tokens"].items()]
            item["groups"] = list(x["groups"])
        else:
            item["groups"] = ",".join(x["groups"])
        out.append(item)
    return out


@route("POST", r"/access/users")
def add_user(p, u):
    uid = p.get("userid", "")
    if not re.fullmatch(r"[^\s:/]+@[A-Za-z][A-Za-z0-9.\-_]+", uid):
        raise ApiError(400, "Parameter verification failed.", {"userid": "value does not match the regex pattern"})
    if uid in USERS:
        raise ApiError(500, f"user '{uid}' already exists")
    USERS[uid] = {"userid": uid, "enable": int(p.get("enable", 1)), "expire": int(p.get("expire", 0) or 0), "email": p.get("email", ""),
                  "firstname": p.get("firstname", ""), "lastname": p.get("lastname", ""), "comment": p.get("comment", ""),
                  "groups": [g for g in p.get("groups", "").split(",") if g], "tokens": {}}
    if p.get("password"):
        SEED["users"].append({"userid": uid, "password": p["password"]})


@route("GET", r"/access/users/(?P<uid>[^/]+)")
def get_user(p, u, uid):
    uid = urllib.parse.unquote(uid)
    if uid not in USERS:
        raise ApiError(500, f"no such user ('{uid}')")
    x = USERS[uid]
    return {k: v for k, v in x.items() if k != "tokens"} | {"tokens": {k: v for k, v in x["tokens"].items()}}


@route("PUT", r"/access/users/(?P<uid>[^/]+)")
def update_user(p, u, uid):
    uid = urllib.parse.unquote(uid)
    x = USERS.get(uid)
    if not x:
        raise ApiError(500, f"no such user ('{uid}')")
    allow_only(p, "append", "comment", "email", "enable", "expire", "firstname", "groups", "keys", "lastname")
    for k in ("email", "firstname", "lastname", "comment"):
        if k in p:
            x[k] = p[k]
    if "enable" in p:
        x["enable"] = int(p["enable"])
    if "expire" in p:
        x["expire"] = int(p["expire"] or 0)
    if "groups" in p:
        x["groups"] = [g for g in p["groups"].split(",") if g]


@route("DELETE", r"/access/users/(?P<uid>[^/]+)")
def delete_user(p, u, uid):
    uid = urllib.parse.unquote(uid)
    if uid == "root@pam":
        raise ApiError(500, "you cannot delete the root user")
    if uid not in USERS:
        raise ApiError(500, f"no such user ('{uid}')")
    del USERS[uid]
    ACL[:] = [a for a in ACL if a["ugid"] != uid and not a["ugid"].startswith(uid + "!")]


@route("GET", r"/access/users/(?P<uid>[^/]+)/token")
def tokens(p, u, uid):
    x = USERS.get(urllib.parse.unquote(uid))
    if not x:
        raise ApiError(500, "no such user")
    return [{"tokenid": tid, **t} for tid, t in x["tokens"].items()]


@route("POST", r"/access/users/(?P<uid>[^/]+)/token/(?P<tid>[^/]+)")
def add_token(p, u, uid, tid):
    uid = urllib.parse.unquote(uid)
    x = USERS.get(uid)
    if not x:
        raise ApiError(500, "no such user")
    if tid in x["tokens"]:
        raise ApiError(500, f"Token already exists.")
    x["tokens"][tid] = {"comment": p.get("comment", ""), "privsep": int(p.get("privsep", 1)), "expire": int(p.get("expire", 0) or 0)}
    secret = str(__import__("uuid").uuid4())
    SEED["tokens"].append({"tokenid": f"{uid}!{tid}", "secret": secret})
    return {"full-tokenid": f"{uid}!{tid}", "info": x["tokens"][tid], "value": secret}


@route("PUT", r"/access/users/(?P<uid>[^/]+)/token/(?P<tid>[^/]+)")
def update_token(p, u, uid, tid):
    uid = urllib.parse.unquote(uid)
    allow_only(p, "comment", "delete", "expire", "privsep", "regenerate")
    x = USERS.get(uid)
    if not x or tid not in x["tokens"]:
        raise ApiError(500, "no such token")
    t = x["tokens"][tid]
    for k in ("comment",):
        if k in p:
            t[k] = p[k]
    if "expire" in p:
        t["expire"] = int(p["expire"] or 0)
    if "privsep" in p:
        t["privsep"] = int(p["privsep"])
    for k in (p.get("delete") or "").split(","):
        if k == "comment":
            t["comment"] = ""
    out = {"full-tokenid": f"{uid}!{tid}", **t}
    if p.get("regenerate") == "1":
        secret = str(__import__("uuid").uuid4())
        SEED["tokens"][:] = [x for x in SEED["tokens"] if x["tokenid"] != f"{uid}!{tid}"] + [{"tokenid": f"{uid}!{tid}", "secret": secret}]
        out["value"] = secret
    return out


@route("GET", r"/access/permissions")
def effective_permissions(p, u):
    """What a user or token may do where, from the ACL, the roles and group membership (like PVE's permission dump)."""
    who = p.get("userid") or u
    user = who.split("!")[0]
    privs_of = dict(ROLES)
    if user == "root@pam":
        return {"/": {priv: 1 for priv in privs_of["Administrator"].split(",")}}
    groups = (USERS.get(user) or {}).get("groups", [])
    token = (USERS.get(user) or {}).get("tokens", {}).get(who.split("!")[1]) if "!" in who else None
    subjects = {("token", who)} if token else {("user", user)} | {("group", g) for g in groups}
    if token and not token.get("privsep", 1):
        subjects |= {("user", user)} | {("group", g) for g in groups}
    out = {}
    for a in ACL:
        if (a["type"], a["ugid"]) in subjects:
            for priv in privs_of.get(a["roleid"], "").split(","):
                if priv:
                    out.setdefault(a["path"], {})[priv] = max(out.get(a["path"], {}).get(priv, 0), int(a.get("propagate", 1)))
    return out


@route("DELETE", r"/access/users/(?P<uid>[^/]+)/token/(?P<tid>[^/]+)")
def delete_token(p, u, uid, tid):
    uid = urllib.parse.unquote(uid)
    x = USERS.get(uid)
    if not x or tid not in x["tokens"]:
        raise ApiError(500, "no such token")
    del x["tokens"][tid]
    SEED["tokens"][:] = [t for t in SEED["tokens"] if t["tokenid"] != f"{uid}!{tid}"]


@route("GET", r"/access/groups")
def groups(p, u):
    return [{"groupid": g, "comment": v["comment"], "users": ",".join(x["userid"] for x in USERS.values() if g in x["groups"])}
            for g, v in GROUPS.items()]


@route("POST", r"/access/groups")
def add_group(p, u):
    gid = p.get("groupid", "")
    if not re.fullmatch(r"[A-Za-z0-9.\-_]+", gid):
        raise ApiError(400, "Parameter verification failed.", {"groupid": "invalid format"})
    if gid in GROUPS:
        raise ApiError(500, f"group '{gid}' already exists")
    GROUPS[gid] = {"groupid": gid, "comment": p.get("comment", "")}


@route("DELETE", r"/access/groups/(?P<gid>[^/]+)")
def delete_group(p, u, gid):
    if gid not in GROUPS:
        raise ApiError(500, f"group '{gid}' does not exist")
    del GROUPS[gid]
    for x in USERS.values():
        if gid in x["groups"]:
            x["groups"].remove(gid)


@route("GET", r"/access/roles")
def roles(p, u):
    builtin = {r for r, _ in ROLES}
    return [{"roleid": r, "privs": privs, "special": 1 if r in builtin else 0} for r, privs in ROLES]


@route("GET", r"/access/acl")
def acl(p, u):
    return ACL


@route("PUT", r"/access/acl")
def set_acl(p, u):
    path, roles_ = p.get("path"), [r for r in p.get("roles", "").split(",") if r]
    if not path or not roles_:
        raise ApiError(400, "Parameter verification failed.", {"path": "property is missing and it is not optional"} if not path else {"roles": "property is missing and it is not optional"})
    targets = [("user", x) for x in p.get("users", "").split(",") if x] + [("group", x) for x in p.get("groups", "").split(",") if x] + \
              [("token", x) for x in p.get("tokens", "").split(",") if x]
    for kind, ugid in targets:
        for role in roles_:
            ACL[:] = [a for a in ACL if not (a["path"] == path and a["ugid"] == ugid and a["roleid"] == role)]
            if p.get("delete") not in ("1", "true"):
                ACL.append({"path": path, "type": kind, "ugid": ugid, "roleid": role, "propagate": int(p.get("propagate", 1))})


# ---------------------------------------------------------------- more datacenter objects

REPLICATION = []
SDN = {"zones": [{"zone": "localnetwork", "type": "simple", "nodes": ""}, {"zone": "lab", "type": "simple", "ipam": "pve", "dhcp": "dnsmasq"},
                 {"zone": "evpnz", "type": "evpn", "controller": "evpn1", "vrf-vxlan": 10000, "mtu": 1450, "ipam": "pve"}],
       "vnets": [{"vnet": "labnet", "zone": "lab", "alias": "Lab network"}, {"vnet": "evnet1", "zone": "evpnz", "tag": 11000, "alias": "Routed apps"}],
       "subnets": {"labnet": [{"subnet": "lab-10.20.0.0-24", "cidr": "10.20.0.0/24", "gateway": "10.20.0.1", "snat": 1, "dhcp-range": [{"start-address": "10.20.0.100", "end-address": "10.20.0.200"}]}]},
       "ips": [{"zone": "lab", "vnet": "labnet", "subnet": "10.20.0.0/24", "ip": "10.20.0.101", "mac": "BC:24:11:3A:7F:01", "hostname": "web-frontend", "vmid": 100}],
       "prefix_lists": {"lan-only": [{"seq": 10, "action": "permit", "prefix": "192.168.1.0/24", "le": 32}]},
       "route_maps": [{"route-map-id": "export-lan", "order": 10, "action": "permit", "match": ["key=ip-address-prefix-list,value=lan-only"], "set": ["key=local-preference,value=200"]}],
       "controllers": [{"controller": "evpn1", "type": "evpn", "asn": 65000, "peers": "192.168.1.11,192.168.1.12"}], "ipams": [{"ipam": "pve", "type": "pve"}], "dns": [],
       "fabrics": [{"id": "ceph", "protocol": "openfabric", "ip_prefix": "10.10.10.0/24"}],
       "fabric_nodes": [{"fabric_id": "ceph", "node_id": "pve1", "protocol": "openfabric", "ip": "10.10.10.1", "interfaces": ["name=enp6s0"]}]}
METRICS = [{"id": "influx-home", "type": "influxdb", "server": "192.168.1.30", "port": 8089, "influxdbproto": "udp"}]
TFA = {"admin@pve": [{"id": "totp-1", "type": "totp", "description": "Phone", "created": now() - 90 * 86400, "enable": 1},
                     {"id": "recovery", "type": "recovery", "description": "Recovery keys", "created": now() - 90 * 86400, "enable": 1}]}
REPOS_ENABLED = {0: True, 1: False, 2: True}


def job_covers():
    covered = set()
    for job in BACKUP_JOBS:
        if not job.get("enabled", 1):
            continue
        if job.get("all"):
            excluded = {int(x) for x in str(job.get("exclude", "")).split(",") if x.strip()}
            covered |= {v for v in GUESTS if v not in excluded}
        elif job.get("pool"):
            covered |= set(POOLS.get(job["pool"], {}).get("vms", []))
        else:
            covered |= {int(x) for x in str(job.get("vmid", "")).split(",") if x.strip()}
    return covered


@route("GET", r"/cluster/backup-info/not-backed-up")
def not_backed_up(p, u):
    covered = job_covers()
    return [{"vmid": v, "name": guest_name(g), "type": g["type"]} for v, g in GUESTS.items() if v not in covered and not g["template"]]


@route("GET", r"/nodes/(?P<node>[^/]+)/vzdump/extractconfig")
def extract_config(p, u, node):
    volume = p.get("volume", "")
    m = re.search(r"vzdump-(qemu|lxc)-(\d+)-", volume)
    if not m:
        raise ApiError(500, f"unable to parse backup file name '{volume}'")
    g = GUESTS.get(int(m.group(2)))
    cfg = g["config"] if g else {"name": f"restored-{m.group(2)}", "memory": "2048", "cores": 2}
    return "\n".join(f"{k}: {v}" for k, v in cfg.items() if k != "digest") + "\n#qmdump#map:scsi0:drive-scsi0:local-lvm:raw:\n"


# firewall groups, aliases, ipsets, log
FW_GROUPS = {"webservers": {"comment": "HTTP and HTTPS in", "rules": [rule("in", "ACCEPT", macro="HTTP"), rule("in", "ACCEPT", macro="HTTPS")]}}
FW_ALIASES = {"nas": {"name": "nas", "cidr": "192.168.1.20", "comment": "TrueNAS"}, "lan": {"name": "lan", "cidr": "192.168.1.0/24", "comment": "Home LAN"}}
FW_IPSETS = {"trusted": {"comment": "Admin workstations", "entries": [{"cidr": "192.168.1.50", "comment": "MacBook"}, {"cidr": "192.168.1.51", "comment": ""}]}}


@route("GET", r"/cluster/firewall/groups")
def fw_groups(p, u):
    return [{"group": g, "comment": v["comment"], "digest": "x"} for g, v in FW_GROUPS.items()]


@route("POST", r"/cluster/firewall/groups")
def fw_add_group(p, u):
    name = p.get("group", "")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9\-_]+", name):
        raise ApiError(400, "Parameter verification failed.", {"group": "invalid format - invalid security group name"})
    FW_GROUPS[name] = {"comment": p.get("comment", ""), "rules": []}


@route("GET", r"/cluster/firewall/groups/(?P<group>[^/]+)")
def fw_group_rules(p, u, group):
    if group not in FW_GROUPS:
        raise ApiError(500, f"no such security group '{group}'")
    return [dict(r, pos=i) for i, r in enumerate(FW_GROUPS[group]["rules"])]


@route("DELETE", r"/cluster/firewall/groups/(?P<group>[^/]+)")
def fw_delete_group(p, u, group):
    FW_GROUPS.pop(group, None)


@route("POST", r"/cluster/firewall/groups/(?P<group>[^/]+)")
def fw_group_add_rule(p, u, group):
    FW_GROUPS[group]["rules"].insert(0, {k: (int(v) if k == "enable" else v) for k, v in p.items() if v != ""})


@route("PUT", r"/cluster/firewall/groups/(?P<group>[^/]+)/(?P<pos>\d+)")
def fw_group_update_rule(p, u, group, pos):
    rules = FW_GROUPS[group]["rules"]
    if "moveto" in p:
        r = rules.pop(int(pos))
        rules.insert(min(int(p["moveto"]), len(rules)), r)
    else:
        rules[int(pos)].update({k: (int(v) if k == "enable" else v) for k, v in p.items() if k not in ("delete", "digest")})


@route("DELETE", r"/cluster/firewall/groups/(?P<group>[^/]+)/(?P<pos>\d+)")
def fw_group_delete_rule(p, u, group, pos):
    FW_GROUPS[group]["rules"].pop(int(pos))


FW_MACROS = [("BitTorrent", "BitTorrent traffic for BitTorrent 3.1 and earlier"), ("Ceph", "Ceph Storage Cluster traffic (Ceph Monitors, OSD & MDS Daemons)"),
             ("DHCPfwd", "Forwarded DHCP traffic"), ("DNS", "Domain Name System traffic (upd and tcp)"), ("FTP", "File Transfer Protocol"),
             ("Git", "Git distributed revision control traffic"), ("HTTP", "Hypertext Transfer Protocol (WWW)"), ("HTTPS", "Hypertext Transfer Protocol (WWW) over SSL"),
             ("IMAP", "Internet Message Access Protocol"), ("IMAPS", "Internet Message Access Protocol over SSL"), ("LDAP", "Lightweight Directory Access Protocol traffic"),
             ("MySQL", "MySQL server"), ("NFS", "NFS server"), ("NTP", "Network Time Protocol (ntpd)"), ("OpenVPN", "OpenVPN traffic"), ("Ping", "ICMP echo request"),
             ("PostgreSQL", "PostgreSQL server"), ("RDP", "Microsoft Remote Desktop Protocol traffic"), ("Rsync", "Rsync server"), ("SMB", "Microsoft SMB traffic"),
             ("SMTP", "Simple Mail Transfer Protocol"), ("SMTPS", "Encrypted Simple Mail Transfer Protocol"), ("SNMP", "Simple Network Management Protocol"),
             ("SSH", "Secure shell traffic"), ("Syslog", "Syslog protocol (RFC 5424) traffic"), ("VNC", "VNC traffic for VNC display's 0 - 99"),
             ("Web", "WWW traffic (HTTP and HTTPS)"), ("Webmin", "Webmin traffic")]


@route("GET", r"/cluster/firewall/macros")
def fw_macros(p, u):
    return [{"macro": m, "descr": d} for m, d in FW_MACROS]


@route("GET", r"(?P<scope>/cluster|/nodes/[^/]+/(?:qemu|lxc)/\d+)/firewall/refs")
def fw_refs(p, u, scope):
    """Aliases and IP sets a rule may name; a guest sees its own plus the datacenter's."""
    out = []
    for where in (["/cluster"] if scope == "/cluster" else [scope, "/cluster"]):
        aliases, ipsets = fw_store(where)
        label = "dc" if where == "/cluster" else "guest"
        out += [{"type": "alias", "name": a["name"], "ref": ("dc/" if where == "/cluster" and scope != "/cluster" else "") + a["name"], "comment": a.get("comment", ""), "scope": label} for a in aliases.values()]
        out += [{"type": "ipset", "name": n, "ref": "+" + ("dc/" if where == "/cluster" and scope != "/cluster" else "") + n, "comment": v.get("comment", ""), "scope": label} for n, v in ipsets.items()]
    if p.get("type"):
        out = [r for r in out if r["type"] == p["type"]]
    return out


# The datacenter and each guest have their own aliases and IP sets.
FW_SCOPE = r"(?P<scope>/cluster|/nodes/[^/]+/(?:qemu|lxc)/\d+)/firewall"
FW_GUEST_STORES = {}


def fw_store(scope):
    if scope == "/cluster":
        return FW_ALIASES, FW_IPSETS
    return FW_GUEST_STORES.setdefault(scope, ({}, {}))


@route("GET", FW_SCOPE + r"/aliases")
def fw_aliases(p, u, scope):
    return list(fw_store(scope)[0].values())


@route("POST", FW_SCOPE + r"/aliases")
def fw_add_alias(p, u, scope):
    if not p.get("name") or not p.get("cidr"):
        raise ApiError(400, "Parameter verification failed.", {"cidr": "property is missing and it is not optional"})
    fw_store(scope)[0][p["name"]] = {"name": p["name"], "cidr": p["cidr"], "comment": p.get("comment", "")}


@route("PUT", FW_SCOPE + r"/aliases/(?P<name>[^/]+)")
def fw_update_alias(p, u, scope, name):
    fw_store(scope)[0][name].update({k: v for k, v in p.items() if k in ("cidr", "comment")})


@route("DELETE", FW_SCOPE + r"/aliases/(?P<name>[^/]+)")
def fw_delete_alias(p, u, scope, name):
    fw_store(scope)[0].pop(name, None)


@route("GET", FW_SCOPE + r"/ipset")
def fw_ipsets(p, u, scope):
    return [{"name": n, "comment": v["comment"]} for n, v in fw_store(scope)[1].items()]


@route("POST", FW_SCOPE + r"/ipset")
def fw_add_ipset(p, u, scope):
    fw_store(scope)[1][p["name"]] = {"comment": p.get("comment", ""), "entries": []}


@route("GET", FW_SCOPE + r"/ipset/(?P<name>[^/]+)")
def fw_ipset_entries(p, u, scope, name):
    sets = fw_store(scope)[1]
    if name not in sets:
        raise ApiError(500, f"no such IPSet '{name}'")
    return sets[name]["entries"]


@route("POST", FW_SCOPE + r"/ipset/(?P<name>[^/]+)")
def fw_add_ipset_entry(p, u, scope, name):
    fw_store(scope)[1][name]["entries"].append({"cidr": p["cidr"], "comment": p.get("comment", ""), **({"nomatch": 1} if p.get("nomatch") == "1" else {})})


@route("DELETE", FW_SCOPE + r"/ipset/(?P<name>[^/]+)/(?P<cidr>.+)")
def fw_delete_ipset_entry(p, u, scope, name, cidr):
    cidr = urllib.parse.unquote(cidr)
    sets = fw_store(scope)[1]
    sets[name]["entries"] = [e for e in sets[name]["entries"] if e["cidr"] != cidr]


@route("DELETE", FW_SCOPE + r"/ipset/(?P<name>[^/]+)")
def fw_delete_ipset(p, u, scope, name):
    sets = fw_store(scope)[1]
    if sets.get(name, {}).get("entries"):
        raise ApiError(500, "IPSet is not empty")
    sets.pop(name, None)


@route("GET", FW + r"/log")
def fw_log(p, u, base):
    t = now()
    return [{"n": i + 1, "t": f"0 5 - {time.strftime('%d/%b/%Y:%H:%M:%S', time.localtime(t - (60 - i) * 30))} DROP: IN=fwbr100i0 OUT=fwbr100i0 SRC=10.66.0.{i % 40} DST=192.168.1.120 PROTO=TCP SPT={40000 + i} DPT=22"} for i in range(60)]


# replication
@route("GET", r"/cluster/replication")
def replication(p, u):
    return REPLICATION


@route("POST", r"/cluster/replication")
def add_replication(p, u):
    if any(r["id"] == p.get("id") for r in REPLICATION):
        raise ApiError(500, f"replication job '{p.get('id')}' already exists")
    guest, jobnum = p["id"].split("-")
    REPLICATION.append({"id": p["id"], "type": "local", "guest": int(guest), "jobnum": int(jobnum), "target": p["target"],
                        "schedule": p.get("schedule", "*/15"), "source": GUESTS.get(int(guest), {}).get("node"),
                        **({"rate": p["rate"]} if p.get("rate") else {}), **({"comment": p["comment"]} if p.get("comment") else {})})


@route("PUT", r"/cluster/replication/(?P<jid>[^/]+)")
def update_replication(p, u, jid):
    job = next((r for r in REPLICATION if r["id"] == jid), None)
    if not job:
        raise ApiError(500, f"no such job '{jid}'")
    job.update({k: (int(v) if k == "disable" else v) for k, v in p.items()})


@route("DELETE", r"/cluster/replication/(?P<jid>[^/]+)")
def delete_replication(p, u, jid):
    REPLICATION[:] = [r for r in REPLICATION if r["id"] != jid]


@route("GET", r"/nodes/(?P<node>[^/]+)/replication")
def node_replication(p, u, node):
    return [{"id": r["id"], "guest": r["guest"], "target": r["target"], "last_sync": now() - 600, "next_sync": now() + 300,
             "duration": 4.2, "fail_count": 0, "state": "ok"} for r in REPLICATION if r.get("source") == node]


@route("POST", r"/nodes/(?P<node>[^/]+)/replication/(?P<jid>[^/]+)/schedule_now")
def replicate_now(p, u, node, jid):
    return new_task(node, "replication", jid, u, 2.0)["upid"]


@route("POST", r"/cluster/ha/resources/(?P<sid>[^/]+)/migrate")
def ha_migrate(p, u, sid):
    return new_task(list(NODES)[0], "hamigrate", urllib.parse.unquote(sid).split(":")[1], u, 2.0)["upid"]


# access extras
@route("GET", r"/access/tfa")
def tfa_list(p, u):
    return [{"userid": user, "entries": entries} for user, entries in TFA.items()]


def tfa_confirm(p, u):
    """Like PVE: anyone but root@pam confirms their password to change two-factor settings."""
    if u == "root@pam":
        return
    me = next((x for x in SEED["users"] if x["userid"] == u), None)
    if not p.get("password"):
        raise ApiError(400, "Parameter verification failed.", {"password": "password is required to modify TFA data"})
    if not me or me["password"] != p["password"]:
        raise ApiError(401, "authentication failure")


@route("POST", r"/access/tfa/(?P<uid>[^/]+)")
def tfa_add(p, u, uid):
    uid = urllib.parse.unquote(uid)
    tfa_confirm(p, u)
    entries = TFA.setdefault(uid, [])
    if p.get("type") == "recovery":
        if any(e["type"] == "recovery" for e in entries):
            raise ApiError(400, "user already has recovery keys")
        keys = [secrets.token_hex(2) + "-" + secrets.token_hex(2) + "-" + secrets.token_hex(2) for _ in range(10)]
        entries.append({"id": "recovery", "type": "recovery", "description": "Recovery keys", "created": now(), "enable": 1})
        return {"id": "recovery", "recovery": keys}
    if p.get("type") == "totp":
        if not re.fullmatch(r"\d{6}", p.get("value", "")):
            raise ApiError(400, "Parameter verification failed.", {"value": "code must be 6 digits"})
        entries.append({"id": f"totp-{len(entries) + 1}", "type": "totp", "description": p.get("description", ""), "created": now(), "enable": 1})
        return {"id": f"totp-{len(entries)}"}
    if p.get("type") == "yubico":
        if not re.fullmatch(r"[a-zA-Z0-9]{44}", p.get("value", "")):
            raise ApiError(400, "Parameter verification failed.", {"value": "not a Yubico OTP (44 letters from the key)"})
        entries.append({"id": f"yubico-{len(entries) + 1}", "type": "yubico", "description": p.get("description", ""), "created": now(), "enable": 1})
        return {"id": f"yubico-{len(entries)}"}
    raise ApiError(400, "unsupported type")


@route("PUT", r"/access/tfa/(?P<uid>[^/]+)/(?P<tid>[^/]+)")
def tfa_update(p, u, uid, tid):
    uid = urllib.parse.unquote(uid)
    tfa_confirm(p, u)
    entry = next((e for e in TFA.get(uid, []) if e["id"] == tid), None)
    if not entry:
        raise ApiError(404, "no such entry")
    if "description" in p:
        entry["description"] = p["description"]
    if "enable" in p:
        entry["enable"] = int(p["enable"])


@route("DELETE", r"/access/tfa/(?P<uid>[^/]+)/(?P<tid>[^/]+)")
def tfa_delete(p, u, uid, tid):
    uid = urllib.parse.unquote(uid)
    tfa_confirm(p, u)
    TFA[uid] = [e for e in TFA.get(uid, []) if e["id"] != tid]


@route("PUT", r"/access/users/(?P<uid>[^/]+)/unlock-tfa")
def unlock_tfa(p, u, uid):
    return 0


@route("POST", r"/access/roles")
def add_role(p, u):
    if any(r == p.get("roleid") for r, _ in ROLES):
        raise ApiError(500, "role already exists")
    ROLES.append((p["roleid"], p.get("privs", "")))


@route("PUT", r"/access/roles/(?P<rid>[^/]+)")
def update_role(p, u, rid):
    for i, (r, _) in enumerate(ROLES):
        if r == rid:
            ROLES[i] = (r, p.get("privs", ""))


@route("DELETE", r"/access/roles/(?P<rid>[^/]+)")
def delete_role(p, u, rid):
    ROLES[:] = [(r, v) for r, v in ROLES if r != rid]


@route("PUT", r"/access/groups/(?P<gid>[^/]+)")
def update_group(p, u, gid):
    GROUPS[gid]["comment"] = p.get("comment", "")


EXTRA_REALMS = [{"realm": "company", "type": "ldap", "server1": "ldap.home.lan", "base_dn": "ou=people,dc=home,dc=lan", "user_attr": "uid",
                 "mode": "ldaps", "port": 636, "comment": "Company directory", "sync-defaults-options": "scope=both,enable-new=1"},
                {"realm": "authentik", "type": "openid", "comment": "Authentik", "issuer-url": "https://127.0.0.1:8006/mock-idp", "client-id": "proxmox",
                 "autocreate": 1, "username-claim": "username"}]
OPENID_STATES = {}  # state -> (realm, redirect-url, code once the "provider" signed the user in)


@route("POST", r"/access/domains")
def add_realm(p, u):
    if any(r["realm"] == p.get("realm") for r in EXTRA_REALMS) or p.get("realm") in ("pam", "pve"):
        raise ApiError(500, f"domain '{p.get('realm')}' already exists")
    EXTRA_REALMS.append({k: v for k, v in p.items() if k != "password"})


def find_realm(realm):
    builtin = {"pam": {"realm": "pam", "type": "pam", "comment": "Linux PAM standard authentication"},
               "pve": {"realm": "pve", "type": "pve", "comment": "Proxmox VE authentication server", "default": 1}}
    found = builtin.get(realm) or next((r for r in EXTRA_REALMS if r["realm"] == realm), None)
    if not found:
        raise ApiError(500, f"domain '{realm}' does not exist")
    return found


@route("GET", r"/access/domains/(?P<realm>[^/]+)")
def realm_get(p, u, realm):
    return {**find_realm(realm), "digest": "abc"}


@route("PUT", r"/access/domains/(?P<realm>[^/]+)")
def realm_update(p, u, realm):
    r = find_realm(realm)
    for k, v in p.items():
        if k not in ("delete", "digest", "password", "type", "realm"):
            r[k] = v
    for k in (p.get("delete") or "").split(","):
        r.pop(k, None)


@route("DELETE", r"/access/domains/(?P<realm>[^/]+)")
def delete_realm(p, u, realm):
    EXTRA_REALMS[:] = [r for r in EXTRA_REALMS if r["realm"] != realm]


@route("POST", r"/access/domains/(?P<realm>[^/]+)/sync")
def sync_realm(p, u, realm):
    allow_only(p, "dry-run", "enable-new", "full", "purge", "remove-vanished", "scope")
    r = find_realm(realm)
    if r["type"] not in ("ldap", "ad"):
        raise ApiError(500, f"realm '{realm}' ({r['type']}) can't be synced")
    scope = p.get("scope") or dict(x.split("=") for x in r.get("sync-defaults-options", "").split(",") if "=" in x).get("scope")
    if not scope:
        raise ApiError(500, "no sync scope given and no default configured")
    preview = "(preview) " if p.get("dry-run") == "1" else ""
    return new_task(list(NODES)[0], "auth-realm-sync", realm, u, 2.0,
                    log=[f"{preview}syncing {scope} from {r.get('server1', realm)}", f"{preview}added user 'alice@{realm}'", f"{preview}added group 'admins-{realm}'"])["upid"]


REALM_SYNC_JOBS = {}


@route("GET", r"/cluster/jobs/realm-sync")
def realm_sync_jobs(p, u):
    return [{**j, "id": i, **({"next-run": now() + 86400} if j.get("enabled", 1) else {})} for i, j in REALM_SYNC_JOBS.items()]


@route("GET", r"/cluster/jobs/realm-sync/(?P<jid>[^/]+)")
def realm_sync_job(p, u, jid):
    if jid not in REALM_SYNC_JOBS:
        raise ApiError(500, f"job '{jid}' does not exist")
    return {**REALM_SYNC_JOBS[jid], "id": jid}


@route("POST", r"/cluster/jobs/realm-sync/(?P<jid>[^/]+)")
def realm_sync_job_add(p, u, jid):
    allow_only(p, "comment", "enable-new", "enabled", "realm", "remove-vanished", "schedule", "scope")
    if jid in REALM_SYNC_JOBS:
        raise ApiError(500, f"job '{jid}' already exists")
    if not p.get("schedule"):
        raise ApiError(400, "Parameter verification failed.", {"schedule": "property is missing and it is not optional"})
    find_realm(p.get("realm", ""))
    REALM_SYNC_JOBS[jid] = dict(p)


@route("PUT", r"/cluster/jobs/realm-sync/(?P<jid>[^/]+)")
def realm_sync_job_update(p, u, jid):
    allow_only(p, "comment", "delete", "enable-new", "enabled", "remove-vanished", "schedule", "scope")
    if jid not in REALM_SYNC_JOBS:
        raise ApiError(500, f"job '{jid}' does not exist")
    REALM_SYNC_JOBS[jid].update({k: v for k, v in p.items() if k != "delete"})
    for k in (p.get("delete") or "").split(","):
        REALM_SYNC_JOBS[jid].pop(k, None)


@route("DELETE", r"/cluster/jobs/realm-sync/(?P<jid>[^/]+)")
def realm_sync_job_delete(p, u, jid):
    REALM_SYNC_JOBS.pop(jid, None)


CUSTOM_CPUS = {}
BUILTIN_CPUS = ["host", "max", "x86-64-v2", "x86-64-v2-AES", "x86-64-v3", "x86-64-v4", "kvm64", "qemu64", "Skylake-Server", "Cascadelake-Server",
                "Icelake-Server", "SapphireRapids", "EPYC", "EPYC-Rome", "EPYC-Milan", "EPYC-Genoa", "EPYC-Turin"]


@route("GET", r"/nodes/(?P<node>[^/]+)/capabilities/qemu/cpu")
def cpu_models(p, u, node):
    return [{"name": n, "vendor": "AuthenticAMD" if n.startswith("EPYC") else "GenuineIntel", "custom": 0} for n in BUILTIN_CPUS] + \
           [{"name": f"custom-{n}", "vendor": "custom", "custom": 1} for n in CUSTOM_CPUS]


@route("GET", r"/cluster/qemu/custom-cpu-models")
def custom_cpus(p, u):
    return [{"cputype": f"custom-{n}", "digest": "abc", **m} for n, m in CUSTOM_CPUS.items()]


@route("POST", r"/cluster/qemu/custom-cpu-models")
def custom_cpu_add(p, u):
    allow_only(p, "cputype", "flags", "guest-phys-bits", "hidden", "hv-vendor-id", "level", "phys-bits", "reported-model")
    name = (p.get("cputype") or "").removeprefix("custom-")
    if not name or not p.get("reported-model"):
        raise ApiError(400, "Parameter verification failed.", {"reported-model" if name else "cputype": "property is missing and it is not optional"})
    if name in CUSTOM_CPUS:
        raise ApiError(500, f"CPU model '{name}' already exists")
    CUSTOM_CPUS[name] = {k: v for k, v in p.items() if k != "cputype"}


@route("PUT", r"/cluster/qemu/custom-cpu-models/(?P<cpu>[^/]+)")
def custom_cpu_update(p, u, cpu):
    allow_only(p, "delete", "digest", "flags", "guest-phys-bits", "hidden", "hv-vendor-id", "level", "phys-bits", "reported-model")
    name = urllib.parse.unquote(cpu).removeprefix("custom-")
    if name not in CUSTOM_CPUS:
        raise ApiError(500, f"CPU model '{name}' does not exist")
    CUSTOM_CPUS[name].update({k: v for k, v in p.items() if k not in ("delete", "digest")})
    for k in (p.get("delete") or "").split(","):
        CUSTOM_CPUS[name].pop(k, None)


@route("DELETE", r"/cluster/qemu/custom-cpu-models/(?P<cpu>[^/]+)")
def custom_cpu_delete(p, u, cpu):
    CUSTOM_CPUS.pop(urllib.parse.unquote(cpu).removeprefix("custom-"), None)


# SDN, metrics, notifications, ACME, mappings, cluster join
@route("GET", r"/cluster/sdn/zones")
def sdn_zones(p, u):
    return SDN["zones"]


@route("POST", r"/cluster/sdn/zones")
def sdn_add_zone(p, u):
    SDN["zones"].append({**p, "pending": {"state": "new"}})


@route("DELETE", r"/cluster/sdn/zones/(?P<zone>[^/]+)")
def sdn_delete_zone(p, u, zone):
    SDN["zones"] = [z for z in SDN["zones"] if z["zone"] != zone]


@route("GET", r"/cluster/sdn/vnets")
def sdn_vnets(p, u):
    return SDN["vnets"]


@route("POST", r"/cluster/sdn/vnets")
def sdn_add_vnet(p, u):
    SDN["vnets"].append({**p, "pending": {"state": "new"}})
    SDN["subnets"][p["vnet"]] = []


@route("DELETE", r"/cluster/sdn/vnets/(?P<vnet>[^/]+)")
def sdn_delete_vnet(p, u, vnet):
    SDN["vnets"] = [v for v in SDN["vnets"] if v["vnet"] != vnet]


@route("GET", r"/cluster/sdn/vnets/(?P<vnet>[^/]+)/subnets")
def sdn_subnets(p, u, vnet):
    return SDN["subnets"].get(vnet, [])


@route("POST", r"/cluster/sdn/vnets/(?P<vnet>[^/]+)/subnets")
def sdn_add_subnet(p, u, vnet):
    allow_only(p, "dhcp-dns-server", "dhcp-range", "dnszoneprefix", "gateway", "lock-token", "snat", "subnet", "type", "vnet")
    require(p, "subnet", "type")
    item = {"subnet": f"{vnet_zone(vnet)}-{p['subnet'].replace('/', '-')}", "cidr": p["subnet"]}
    sdn_update_subnet_item(item, p)
    SDN["subnets"].setdefault(vnet, []).append(item)


def vnet_zone(vnet):
    return next((v["zone"] for v in SDN["vnets"] if v["vnet"] == vnet), "zone")


def sdn_update_subnet_item(item, p):
    """Like PVE, DHCP ranges come in as "start-address=a,end-address=b" strings and read back as objects."""
    for key, value in p.items():
        if key == "dhcp-range":
            item[key] = [dict(pair.split("=", 1) for pair in r.split(",")) for r in value.split("\0") if r]
        elif key not in ("delete", "digest", "type", "lock-token", "subnet", "vnet"):
            item[key] = value
    for k in (p.get("delete") or "").split(","):
        item.pop(k, None)


SDN_KEYS = {"controllers": "controller", "ipams": "ipam", "dns": "dns"}


def find_fabric(fid):
    fabric = next((f for f in SDN["fabrics"] if f["id"] == fid), None)
    if not fabric:
        raise ApiError(500, f"fabric '{fid}' does not exist")
    return fabric


@route("GET", r"/cluster/sdn/fabrics/all")
def fabrics_all(p, u):
    return {"fabrics": SDN["fabrics"], "nodes": SDN["fabric_nodes"]}


@route("GET", r"/cluster/sdn/fabrics/fabric")
def fabrics_list(p, u):
    return SDN["fabrics"]


@route("POST", r"/cluster/sdn/fabrics/fabric")
def fabrics_add(p, u):
    require(p, "id", "protocol")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,7}", p["id"]):
        raise ApiError(400, "Parameter verification failed.", {"id": "invalid fabric ID (letters and digits, up to 8 characters)"})
    if p["protocol"] not in ("openfabric", "ospf"):
        raise ApiError(400, "Parameter verification failed.", {"protocol": f"value '{p['protocol']}' does not have a value in the enumeration 'openfabric, ospf'"})
    if any(f["id"] == p["id"] for f in SDN["fabrics"]):
        raise ApiError(500, f"fabric '{p['id']}' already exists")
    item = {"state": "new"}
    update_config(item, p)
    SDN["fabrics"].append(item)


@route("GET", r"/cluster/sdn/fabrics/fabric/(?P<fid>[^/]+)")
def fabrics_get(p, u, fid):
    return find_fabric(fid)


@route("PUT", r"/cluster/sdn/fabrics/fabric/(?P<fid>[^/]+)")
def fabrics_update(p, u, fid):
    require(p, "protocol")
    fabric = find_fabric(fid)
    update_config(fabric, p)
    fabric["state"] = fabric.get("state") or "changed"


@route("DELETE", r"/cluster/sdn/fabrics/fabric/(?P<fid>[^/]+)")
def fabrics_delete(p, u, fid):
    find_fabric(fid)
    SDN["fabrics"] = [f for f in SDN["fabrics"] if f["id"] != fid]
    SDN["fabric_nodes"] = [n for n in SDN["fabric_nodes"] if n["fabric_id"] != fid]


@route("GET", r"/cluster/sdn/fabrics/node")
def fabric_nodes_all(p, u):
    return SDN["fabric_nodes"]


@route("GET", r"/cluster/sdn/fabrics/node/(?P<fid>[^/]+)")
def fabric_nodes(p, u, fid):
    find_fabric(fid)
    return [n for n in SDN["fabric_nodes"] if n["fabric_id"] == fid]


@route("POST", r"/cluster/sdn/fabrics/node/(?P<fid>[^/]+)")
def fabric_node_add(p, u, fid):
    fabric = find_fabric(fid)
    require(p, "node_id", "protocol")
    if p["node_id"] not in NODES:
        raise ApiError(500, f"node '{p['node_id']}' is not part of the cluster")
    if any(n["fabric_id"] == fid and n["node_id"] == p["node_id"] for n in SDN["fabric_nodes"]):
        raise ApiError(500, f"node '{p['node_id']}' is already in fabric '{fid}'")
    if fabric.get("ip_prefix") and not p.get("ip"):
        raise ApiError(400, "Parameter verification failed.", {"ip": "the fabric has an IPv4 prefix, so the node needs an IPv4 address"})
    item = {"fabric_id": fid}
    update_config(item, p, lists=("interfaces",))
    SDN["fabric_nodes"].append(item)


def find_fabric_node(fid, nid):
    item = next((n for n in SDN["fabric_nodes"] if n["fabric_id"] == fid and n["node_id"] == nid), None)
    if not item:
        raise ApiError(500, f"node '{nid}' is not in fabric '{fid}'")
    return item


@route("GET", r"/cluster/sdn/fabrics/node/(?P<fid>[^/]+)/(?P<nid>[^/]+)")
def fabric_node_get(p, u, fid, nid):
    return find_fabric_node(fid, nid)


@route("PUT", r"/cluster/sdn/fabrics/node/(?P<fid>[^/]+)/(?P<nid>[^/]+)")
def fabric_node_update(p, u, fid, nid):
    update_config(find_fabric_node(fid, nid), p, lists=("interfaces",))


@route("DELETE", r"/cluster/sdn/fabrics/node/(?P<fid>[^/]+)/(?P<nid>[^/]+)")
def fabric_node_delete(p, u, fid, nid):
    find_fabric_node(fid, nid)
    SDN["fabric_nodes"] = [n for n in SDN["fabric_nodes"] if not (n["fabric_id"] == fid and n["node_id"] == nid)]


@route("GET", r"/cluster/sdn/(?P<kind>controllers|ipams|dns)")
def sdn_list(p, u, kind):
    return SDN[kind]


@route("POST", r"/cluster/sdn/(?P<kind>controllers|ipams|dns)")
def sdn_add(p, u, kind):
    key = SDN_KEYS[kind]
    ident = config_id(p, key)
    require(p, "type")
    needs = {("controllers", "evpn"): ("asn", "peers"), ("controllers", "bgp"): ("asn", "node"), ("controllers", "isis"): ("node", "isis-domain", "isis-ifaces", "isis-net"),
             ("ipams", "netbox"): ("url", "token"), ("ipams", "phpipam"): ("url", "token", "section"), ("dns", "powerdns"): ("url", "key")}
    require(p, *needs.get((kind, p["type"]), ()))
    if any(x[key] == ident for x in SDN[kind]):
        raise ApiError(500, f"{key} '{ident}' already exists")
    SDN[kind].append({**{k: v for k, v in p.items() if k not in ("token", "key")}, **({"pending": {"state": "new"}} if kind == "controllers" else {})})


@route("DELETE", r"/cluster/sdn/(?P<kind>controllers|ipams|dns)/(?P<ident>[^/]+)")
def sdn_delete(p, u, kind, ident):
    SDN[kind] = [x for x in SDN[kind] if x[SDN_KEYS[kind]] != ident]


SDN_ID = {"zones": "zone", "vnets": "vnet", "controllers": "controller", "ipams": "ipam", "dns": "dns"}


@route("GET", r"/cluster/sdn/(?P<kind>zones|vnets|controllers|ipams|dns)/(?P<ident>[^/]+)")
def sdn_get_one(p, u, kind, ident):
    item = next((x for x in SDN[kind] if x[SDN_ID[kind]] == ident), None)
    if not item:
        raise ApiError(500, f"{SDN_ID[kind]} '{ident}' does not exist")
    return {k: v for k, v in item.items() if k not in ("token", "key")} | {"digest": "abc"}


@route("PUT", r"/cluster/sdn/(?P<kind>zones|vnets|controllers|ipams|dns)/(?P<ident>[^/]+)")
def sdn_update(p, u, kind, ident):
    item = next((x for x in SDN[kind] if x[SDN_ID[kind]] == ident), None)
    if not item:
        raise ApiError(500, f"{SDN_ID[kind]} '{ident}' does not exist")
    if "type" in p and p["type"] != item.get("type") and kind != "vnets":
        raise ApiError(400, "Parameter verification failed.", {"type": "can't change the type"})
    item.update({k: v for k, v in p.items() if k not in ("delete", "digest", "token", "key", "lock-token")})
    for k in (p.get("delete") or "").split(","):
        item.pop(k, None)
    if kind in ("zones", "vnets", "controllers"):
        item["pending"] = {"state": "changed"}


@route("GET", r"/cluster/sdn/vnets/(?P<vnet>[^/]+)/subnets/(?P<subnet>[^/]+)")
def sdn_subnet(p, u, vnet, subnet):
    item = next((x for x in SDN["subnets"].get(vnet, []) if x["subnet"] == subnet), None)
    if not item:
        raise ApiError(500, f"subnet '{subnet}' does not exist")
    return item


@route("PUT", r"/cluster/sdn/vnets/(?P<vnet>[^/]+)/subnets/(?P<subnet>[^/]+)")
def sdn_update_subnet(p, u, vnet, subnet):
    allow_only(p, "delete", "dhcp-dns-server", "dhcp-range", "digest", "dnszoneprefix", "gateway", "lock-token", "snat", "vnet")
    sdn_update_subnet_item(sdn_subnet(p, u, vnet, subnet), p)


@route("DELETE", r"/cluster/sdn/vnets/(?P<vnet>[^/]+)/subnets/(?P<subnet>[^/]+)")
def sdn_delete_subnet(p, u, vnet, subnet):
    SDN["subnets"][vnet] = [x for x in SDN["subnets"].get(vnet, []) if x["subnet"] != subnet]


@route("GET", r"/cluster/sdn/ipams/(?P<ipam>[^/]+)/status")
def sdn_ipam_status(p, u, ipam):
    if ipam != "pve":
        raise ApiError(500, "only the built-in IPAM can list its entries")
    out = []
    for vnet, subnets in SDN["subnets"].items():
        zone = next((v["zone"] for v in SDN["vnets"] if v["vnet"] == vnet), "")
        for sub in subnets:
            if sub.get("gateway"):
                out.append({"zone": zone, "vnet": vnet, "subnet": sub["cidr"], "ip": sub["gateway"], "gateway": 1})
    return out + SDN["ips"]


@route("POST", r"/cluster/sdn/vnets/(?P<vnet>[^/]+)/ips")
def sdn_add_ip(p, u, vnet):
    allow_only(p, "ip", "mac", "zone")
    require(p, "ip", "zone")
    if any(x["ip"] == p["ip"] for x in SDN["ips"]):
        raise ApiError(500, f"IP '{p['ip']}' is already in use")
    SDN["ips"].append({"zone": p["zone"], "vnet": vnet, "subnet": "10.20.0.0/24", "ip": p["ip"], **({"mac": p["mac"]} if p.get("mac") else {})})


@route("PUT", r"/cluster/sdn/vnets/(?P<vnet>[^/]+)/ips")
def sdn_update_ip(p, u, vnet):
    allow_only(p, "ip", "mac", "vmid", "zone")
    entry = next((x for x in SDN["ips"] if x["ip"] == p.get("ip")), None)
    if not entry:
        raise ApiError(500, f"IP '{p.get('ip')}' isn't mapped")
    entry.update({k: (int(v) if k == "vmid" else v) for k, v in p.items() if k in ("mac", "vmid")})


@route("DELETE", r"/cluster/sdn/vnets/(?P<vnet>[^/]+)/ips")
def sdn_delete_ip(p, u, vnet):
    allow_only(p, "ip", "mac", "zone")
    SDN["ips"] = [x for x in SDN["ips"] if x["ip"] != p.get("ip")]


@route("GET", r"/cluster/sdn/dry-run")
def sdn_dry_run(p, u):
    allow_only(p, "node")
    require(p, "node")
    pending = [x for x in SDN["zones"] + SDN["vnets"] if x.get("pending")]
    if not pending:
        return {"frr-diff": "", "interfaces-diff": ""}
    lines = []
    for x in pending:
        name = x.get("vnet") or x.get("zone")
        lines += [f"+auto {name}", f"+iface {name}", "+\tbridge_ports none", "+\tbridge_stp off", "+\tbridge_fd 0", ""]
    return {"interfaces-diff": "--- /etc/network/interfaces.d/sdn\n+++ /etc/network/interfaces.d/sdn (pending)\n" + "\n".join(lines),
            "frr-diff": ""}


@route("GET", r"/cluster/sdn/prefix-lists")
def prefix_lists(p, u):
    return [{"id": i, "entries": [f"action={e['action']},prefix={e['prefix']},seq={e['seq']}" + (f",le={e['le']}" if e.get("le") else "") + (f",ge={e['ge']}" if e.get("ge") else "") for e in entries]}
            for i, entries in SDN["prefix_lists"].items()]


@route("POST", r"/cluster/sdn/prefix-lists")
def prefix_list_add(p, u):
    allow_only(p, "digest", "entries", "id", "lock-token")
    if p.get("id") in SDN["prefix_lists"]:
        raise ApiError(500, f"prefix list '{p['id']}' already exists")
    SDN["prefix_lists"][config_id(p, "id")] = []


@route("DELETE", r"/cluster/sdn/prefix-lists/(?P<pid>[^/]+)")
def prefix_list_delete(p, u, pid):
    SDN["prefix_lists"].pop(pid, None)


@route("GET", r"/cluster/sdn/prefix-lists/(?P<pid>[^/]+)/entries")
def prefix_entries(p, u, pid):
    if pid not in SDN["prefix_lists"]:
        raise ApiError(500, f"prefix list '{pid}' does not exist")
    return SDN["prefix_lists"][pid]


@route("POST", r"/cluster/sdn/prefix-lists/(?P<pid>[^/]+)/entries")
def prefix_entry_add(p, u, pid):
    allow_only(p, "action", "ge", "le", "lock-token", "prefix", "seq")
    require(p, "action", "prefix")
    entries = SDN["prefix_lists"].setdefault(pid, [])
    seq = int(p.get("seq") or (max([e["seq"] for e in entries] or [0]) + 10))
    entries.append({"seq": seq, "action": p["action"], "prefix": p["prefix"], **{k: int(p[k]) for k in ("ge", "le") if p.get(k)}})
    entries.sort(key=lambda e: e["seq"])


@route("PUT", r"/cluster/sdn/prefix-lists/(?P<pid>[^/]+)/entries/(?P<seq>\d+)")
def prefix_entry_update(p, u, pid, seq):
    allow_only(p, "action", "delete", "digest", "ge", "le", "lock-token", "prefix")
    e = next((x for x in SDN["prefix_lists"].get(pid, []) if x["seq"] == int(seq)), None)
    if not e:
        raise ApiError(500, f"entry {seq} does not exist")
    e.update({k: (int(v) if k in ("ge", "le") else v) for k, v in p.items() if k in ("action", "prefix", "ge", "le")})
    for k in (p.get("delete") or "").split(","):
        e.pop(k, None)


@route("DELETE", r"/cluster/sdn/prefix-lists/(?P<pid>[^/]+)/entries/(?P<seq>\d+)")
def prefix_entry_delete(p, u, pid, seq):
    SDN["prefix_lists"][pid] = [x for x in SDN["prefix_lists"].get(pid, []) if x["seq"] != int(seq)]


@route("GET", r"/cluster/sdn/route-maps")
def route_maps(p, u):
    return [{"id": i} for i in sorted({e["route-map-id"] for e in SDN["route_maps"]})]


@route("GET", r"/cluster/sdn/route-maps/entries")
def route_map_entries(p, u):
    return [dict(e, digest="abc") for e in SDN["route_maps"]]


@route("POST", r"/cluster/sdn/route-maps/entries")
def route_map_entry_add(p, u):
    allow_only(p, "action", "call", "digest", "exit-action", "lock-token", "match", "order", "route-map-id", "set")
    require(p, "action", "order", "route-map-id")
    if any(e["route-map-id"] == p["route-map-id"] and e["order"] == int(p["order"]) for e in SDN["route_maps"]):
        raise ApiError(500, f"entry {p['order']} already exists in {p['route-map-id']}")
    as_list = lambda v: [x for x in (v or "").split("\0") if x]
    SDN["route_maps"].append({"route-map-id": p["route-map-id"], "order": int(p["order"]), "action": p["action"],
                              "match": as_list(p.get("match")), "set": as_list(p.get("set")),
                              **{k: p[k] for k in ("call", "exit-action") if p.get(k)}})


@route("PUT", r"/cluster/sdn/route-maps/entries/(?P<rid>[^/]+)/entry/(?P<order>\d+)")
def route_map_entry_update(p, u, rid, order):
    allow_only(p, "action", "call", "delete", "digest", "exit-action", "lock-token", "match", "set")
    e = next((x for x in SDN["route_maps"] if x["route-map-id"] == rid and x["order"] == int(order)), None)
    if not e:
        raise ApiError(500, f"entry {order} does not exist in {rid}")
    for k in ("action", "call", "exit-action"):
        if k in p:
            e[k] = p[k]
    for k in ("match", "set"):
        if k in p:
            e[k] = [x for x in p[k].split("\0") if x]
    for k in (p.get("delete") or "").split(","):
        e.pop(k, None)


@route("DELETE", r"/cluster/sdn/route-maps/entries/(?P<rid>[^/]+)/entry/(?P<order>\d+)")
def route_map_entry_delete(p, u, rid, order):
    SDN["route_maps"] = [x for x in SDN["route_maps"] if not (x["route-map-id"] == rid and x["order"] == int(order))]


@route("GET", r"/nodes/(?P<node>[^/]+)/sdn/zones/(?P<zone>[^/]+)/ip-vrf")
def node_sdn_ip_vrf(p, u, node, zone):
    if not any(z["zone"] == zone and z.get("type") == "evpn" for z in SDN["zones"]):
        raise ApiError(500, f"zone '{zone}' is not an EVPN zone")
    return [{"ip": "10.30.0.0/24", "metric": 0, "protocol": "connected", "nexthops": ["vrfbr_evpn1"]},
            {"ip": "10.30.1.0/24", "metric": 20, "protocol": "bgp", "nexthops": ["192.168.1.12"]}]


@route("GET", r"/nodes/(?P<node>[^/]+)/sdn/vnets/(?P<vnet>[^/]+)/mac-vrf")
def node_sdn_mac_vrf(p, u, node, vnet):
    return [{"mac": "bc:24:11:5e:21:0a", "ip": "10.30.0.20", "nexthop": ""}, {"mac": "bc:24:11:9c:33:41", "ip": "10.30.0.31", "nexthop": "192.168.1.12"}]


@route("GET", r"/nodes/(?P<node>[^/]+)/sdn/zones")
def node_sdn_zones(p, u, node):
    return [{"zone": z["zone"], "status": "pending" if z.get("pending") else "available"} for z in SDN["zones"]]


@route("GET", r"/nodes/(?P<node>[^/]+)/sdn/zones/(?P<zone>[^/]+)/content")
def node_sdn_zone_content(p, u, node, zone):
    return [{"vnet": v["vnet"], "status": "pending" if v.get("pending") else "available", **({"statusmsg": "not applied yet"} if v.get("pending") else {})}
            for v in SDN["vnets"] if v["zone"] == zone]


@route("GET", r"/nodes/(?P<node>[^/]+)/sdn/zones/(?P<zone>[^/]+)/bridges")
def node_sdn_zone_bridges(p, u, node, zone):
    return [{"name": v["vnet"], "vlan_filtering": "1" if v.get("vlanaware") else "0", "ports": [{"name": f"tap{g['vmid']}i0", "vmid": g["vmid"], "index": 0}
             for g in list(GUESTS.values())[:1]]} for v in SDN["vnets"] if v["zone"] == zone]


@route("GET", r"/nodes/(?P<node>[^/]+)/sdn/fabrics/(?P<fid>[^/]+)/(?P<what>routes|neighbors|interfaces)")
def node_sdn_fabric(p, u, node, fid, what):
    find_fabric(fid)
    if what == "routes":
        return [{"route": "10.10.10.2/32", "via": ["enp6s0"]}]
    if what == "neighbors":
        return [{"neighbor": "pve2", "status": "Up", "uptime": "3d 4h"}]
    return [{"name": "enp6s0", "type": "point-to-point", "state": "up"}]


@route("PUT", r"/cluster/sdn")
def sdn_apply(p, u):
    for item in SDN["zones"] + SDN["vnets"] + SDN["controllers"] + SDN["fabrics"]:
        item.pop("pending", None)
    return new_task(list(NODES)[0], "reloadnetworkall", "", u, 2.0)["upid"]


@route("GET", r"/cluster/metrics/server")
def metrics(p, u):
    return METRICS


@route("POST", r"/cluster/metrics/server/(?P<mid>[^/]+)")
def add_metric(p, u, mid):
    METRICS.append({"id": mid, **p})


@route("DELETE", r"/cluster/metrics/server/(?P<mid>[^/]+)")
def delete_metric(p, u, mid):
    METRICS[:] = [m for m in METRICS if m["id"] != mid]


NOTIF_TARGETS = [{"name": "mail-to-root", "type": "sendmail", "mailto-user": ["root@pam"], "comment": "Send mails to root@pam's email address", "origin": "builtin"},
                 {"name": "ntfy-phone", "type": "webhook", "comment": "Push to phone", "origin": "user-created"}]
NOTIF_MATCHERS = [{"name": "default-matcher", "target": ["mail-to-root"], "comment": "Route all notifications to mail-to-root", "origin": "builtin"}]
HA_RULES = [{"rule": "db-on-pve1", "type": "node-affinity", "resources": "vm:101", "nodes": "pve1:2,pve2:1", "strict": 0, "comment": "Prefer the faster node"}]
MAPPINGS = {"pci": [{"id": "gpu0", "description": "NVIDIA RTX A2000", "map": ["node=pve1,path=0000:01:00,id=10de:2531"]}], "usb": [],
            "dir": [{"id": "media", "description": "Movies and music", "map": ["node=pve1,path=/tank/media", "node=pve2,path=/mnt/nas/media"]}]}
ACME = {"accounts": ["default"], "plugins": [{"plugin": "cloudflare", "type": "dns", "api": "cf", "data": "Q0ZfVG9rZW49eHh4"}]}
CLUSTER = {"name": None if os.environ.get("MOCK_PVE_STANDALONE") else "homelab"}
CONFIG_ID = r"[A-Za-z][A-Za-z0-9\-_.]*"


def require(p, *keys):
    missing = {k: "property is missing and it is not optional" for k in keys if not p.get(k)}
    if missing:
        raise ApiError(400, "Parameter verification failed.", missing)


def config_id(p, key):
    require(p, key)
    if not re.fullmatch(CONFIG_ID, p[key]):
        raise ApiError(400, "Parameter verification failed.", {key: f"invalid configuration ID '{p[key]}'"})
    return p[key]


@route("GET", r"/cluster/notifications/targets")
def notif_targets(p, u):
    return [{k: t[k] for k in ("name", "type", "comment", "origin", "disable") if k in t} for t in NOTIF_TARGETS]


@route("POST", r"/cluster/notifications/endpoints/(?P<kind>sendmail|smtp|gotify|webhook)")
def notif_add_target(p, u, kind):
    name = config_id(p, "name")
    require(p, *{"smtp": ("server", "from-address"), "gotify": ("server", "token"), "webhook": ("url", "method")}.get(kind, ()))
    if kind in ("sendmail", "smtp") and not (p.get("mailto") or p.get("mailto-user")):
        raise ApiError(400, "Parameter verification failed.", {"mailto": "at least one recipient (mailto or mailto-user) is required"})
    if any(t["name"] == name for t in NOTIF_TARGETS):
        raise ApiError(500, f"target '{name}' already exists")
    target = {"type": kind, "origin": "user-created"}
    update_config(target, p, lists=("mailto", "mailto-user", "header", "secret"))
    NOTIF_TARGETS.append(target)


def find_target(name):
    target = next((t for t in NOTIF_TARGETS if t["name"] == name), None)
    if not target:
        raise ApiError(500, f"endpoint '{name}' does not exist")
    return target


@route("GET", r"/cluster/notifications/endpoints/(?P<kind>[^/]+)/(?P<name>[^/]+)")
def notif_get_target(p, u, kind, name):
    out = {k: v for k, v in find_target(name).items() if k not in ("password", "token", "origin")}
    if "secret" in out:
        out["secret"] = [s.split(",value=")[0] for s in out["secret"]]
    return out


@route("PUT", r"/cluster/notifications/endpoints/(?P<kind>[^/]+)/(?P<name>[^/]+)")
def notif_update_target(p, u, kind, name):
    target = find_target(name)
    update_config(target, p, lists=("mailto", "mailto-user", "header", "secret"))
    if target["origin"] == "builtin":
        target["origin"] = "modified-builtin"


@route("DELETE", r"/cluster/notifications/endpoints/(?P<kind>[^/]+)/(?P<name>[^/]+)")
def notif_delete_target(p, u, kind, name):
    target = next((t for t in NOTIF_TARGETS if t["name"] == name), None)
    if not target:
        raise ApiError(500, f"endpoint '{name}' does not exist")
    if target["origin"] == "builtin":
        raise ApiError(500, f"cannot delete built-in target '{name}'")
    if any(name in m["target"] for m in NOTIF_MATCHERS):
        raise ApiError(500, f"target '{name}' is still used by a matcher")
    NOTIF_TARGETS.remove(target)


@route("GET", r"/cluster/notifications/matchers")
def notif_matchers(p, u):
    return NOTIF_MATCHERS


@route("POST", r"/cluster/notifications/matchers")
def notif_add_matcher(p, u):
    name = config_id(p, "name")
    if any(m["name"] == name for m in NOTIF_MATCHERS):
        raise ApiError(500, f"matcher '{name}' already exists")
    unknown = [t for t in filter(None, p.get("target", "").split("\0")) if not any(x["name"] == t for x in NOTIF_TARGETS)]
    if unknown:
        raise ApiError(500, f"target '{unknown[0]}' does not exist")
    matcher = {"origin": "user-created"}
    update_config(matcher, p, lists=("target", "match-severity", "match-field"))
    NOTIF_MATCHERS.append(matcher)


@route("GET", r"/cluster/notifications/matchers/(?P<name>[^/]+)")
def notif_get_matcher(p, u, name):
    matcher = next((m for m in NOTIF_MATCHERS if m["name"] == name), None)
    if not matcher:
        raise ApiError(500, f"matcher '{name}' does not exist")
    return {k: v for k, v in matcher.items() if k != "origin"}


@route("PUT", r"/cluster/notifications/matchers/(?P<name>[^/]+)")
def notif_update_matcher(p, u, name):
    matcher = next((m for m in NOTIF_MATCHERS if m["name"] == name), None)
    if not matcher:
        raise ApiError(500, f"matcher '{name}' does not exist")
    unknown = [t for t in filter(None, p.get("target", "").split("\0")) if not any(x["name"] == t for x in NOTIF_TARGETS)]
    if unknown:
        raise ApiError(500, f"target '{unknown[0]}' does not exist")
    update_config(matcher, p, lists=("target", "match-severity", "match-field"))


@route("DELETE", r"/cluster/notifications/matchers/(?P<name>[^/]+)")
def notif_delete_matcher(p, u, name):
    if any(m["name"] == name and m["origin"] == "builtin" for m in NOTIF_MATCHERS):
        raise ApiError(500, f"cannot delete built-in matcher '{name}'")
    NOTIF_MATCHERS[:] = [m for m in NOTIF_MATCHERS if m["name"] != name]


@route("POST", r"/cluster/notifications/targets/(?P<name>[^/]+)/test")
def notif_test(p, u, name):
    return None


@route("GET", r"/nodes/(?P<node>[^/]+)/vzdump/defaults")
def vzdump_defaults(p, u, node):
    allow_only(p, "storage")
    # /etc/vzdump.conf on the mock nodes: back up to the NAS with zstd, keep notes.
    return {"storage": "nas-backup", "mode": "snapshot", "compress": "zstd", "notes-template": "{{guestname}} on {{node}}", "prune-backups": "keep-last=3,keep-weekly=4"}


@route("GET", r"/cluster/jobs/schedule-analyze")
def schedule_analyze(p, u):
    allow_only(p, "iterations", "schedule", "starttime")
    require(p, "schedule")
    spec = p["schedule"].strip()
    start = int(p.get("starttime") or now())
    count = int(p.get("iterations") or 10)
    # Enough of systemd calendar events for the common forms: "*/N", "HH:MM", "daily", "weekly", "sat 02:00", "mon..fri HH:MM".
    days = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}
    m = re.fullmatch(r"(?:(mon|tue|wed|thu|fri|sat|sun)(?:\.\.(mon|tue|wed|thu|fri|sat|sun))?\s+)?(\d{1,2}):(\d{2})|\*/(\d+)|daily|weekly|monthly|hourly", spec)
    if not m:
        raise ApiError(400, "Parameter verification failed.", {"schedule": f"value '{spec}' does not look like a valid calendar event"})
    out, t = [], time.localtime(start)
    candidates = []
    if spec == "hourly" or m.group(5):
        step = 3600 if spec == "hourly" else int(m.group(5)) * 60
        first = start - start % step + step
        candidates = [first + i * step for i in range(count)]
    else:
        hour, minute = (int(m.group(3)), int(m.group(4))) if m.group(3) else (0, 0)
        allowed = set(range(7))
        if m.group(1):
            a, b = days[m.group(1)], days[m.group(2) or m.group(1)]
            allowed = set(range(a, b + 1))
        if spec == "weekly":
            allowed = {0}
        day = 0
        while len(candidates) < count and day < 800:
            # mktime normalizes the day and keeps the wall-clock time across daylight saving changes, like systemd.
            moment = int(time.mktime((t.tm_year, t.tm_mon, t.tm_mday + day, hour, minute, 0, 0, 0, -1)))
            lt = time.localtime(moment)
            if moment > start and lt.tm_wday in allowed and (spec != "monthly" or lt.tm_mday == 1):
                candidates.append(moment)
            day += 1
    return [{"timestamp": c, "utc": time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(c))} for c in candidates[:count]]


@route("GET", r"/cluster/acme/account")
def acme_accounts(p, u):
    return [{"name": name} for name in ACME["accounts"]]


ACME_DIRECTORIES = {"https://acme-v02.api.letsencrypt.org/directory": ("Let's Encrypt V2", {"termsOfService": "https://letsencrypt.org/documents/LE-SA-v1.5-February-24-2025.pdf", "website": "https://letsencrypt.org"}),
                    "https://acme-staging-v02.api.letsencrypt.org/directory": ("Let's Encrypt V2 Staging", {"termsOfService": "https://letsencrypt.org/documents/LE-SA-v1.5-February-24-2025.pdf"}),
                    "https://acme.zerossl.com/v2/DV90": ("ZeroSSL", {"termsOfService": "https://secure.trust-provider.com/repository/docs/Legacy/20221001_Certificate_Subscriber_Agreement_v_2_5_click.pdf", "externalAccountRequired": 1})}


@route("GET", r"/cluster/acme/directories")
def acme_directories(p, u):
    return [{"name": name, "url": url} for url, (name, _) in ACME_DIRECTORIES.items() if "zerossl" not in url]


@route("GET", r"/cluster/acme/meta")
def acme_meta(p, u):
    allow_only(p, "directory")
    entry = ACME_DIRECTORIES.get(p.get("directory") or "https://acme-v02.api.letsencrypt.org/directory")
    if not entry:
        raise ApiError(500, "unable to fetch directory: 404 Not Found")
    return entry[1]


@route("POST", r"/cluster/acme/account")
def acme_register(p, u):
    allow_only(p, "contact", "directory", "eab-hmac-key", "eab-kid", "name", "tos_url")
    name = p.get("name") or "default"
    require(p, "contact")
    meta = ACME_DIRECTORIES.get(p.get("directory") or "https://acme-v02.api.letsencrypt.org/directory", ("", {}))[1]
    if meta.get("externalAccountRequired") and not (p.get("eab-kid") and p.get("eab-hmac-key")):
        raise ApiError(500, "ACME CA requires external account binding.")
    if meta.get("termsOfService") and p.get("tos_url") != meta["termsOfService"]:
        raise ApiError(500, "Terms of service must be accepted.")
    if name in ACME["accounts"]:
        raise ApiError(500, f"ACME account config file '{name}' already exists.")
    return new_task(list(NODES)[0], "acmeregister", name, u, 2.0, on_done=lambda: ACME["accounts"].append(name),
                    log=["Registering new ACME account..", f"Registration successful, account URL: 'https://acme-v02.api.letsencrypt.org/acme/acct/12345'"])["upid"]


@route("DELETE", r"/cluster/acme/account/(?P<name>[^/]+)")
def acme_deactivate(p, u, name):
    if name not in ACME["accounts"]:
        raise ApiError(500, f"ACME account config file '{name}' does not exist.")
    return new_task(list(NODES)[0], "acmedeactivate", name, u, 1.5, on_done=lambda: ACME["accounts"].remove(name))["upid"]


@route("GET", r"/cluster/acme/tos")
def acme_tos(p, u):
    return "https://letsencrypt.org/documents/LE-SA-v1.5-February-24-2025.pdf"


@route("GET", r"/cluster/acme/challenge-schema")
def acme_schema(p, u):
    return [{"id": api, "name": name, "type": "dns", "schema": {}} for api, name in
            [("cf", "Cloudflare Managed DNS"), ("acmedns", "acme-dns"), ("route53", "Amazon Route53 (AWS)"), ("ovh", "OVH"), ("desec", "deSEC.io")]]


@route("GET", r"/cluster/acme/plugins")
def acme_plugins(p, u):
    return ACME["plugins"]


@route("POST", r"/cluster/acme/plugins")
def acme_add_plugin(p, u):
    plugin = config_id(p, "id")
    require(p, "type")
    if any(x["plugin"] == plugin for x in ACME["plugins"]):
        raise ApiError(500, f"plugin '{plugin}' already exists")
    ACME["plugins"].append({"plugin": plugin, "type": p["type"], **({"api": p["api"]} if p.get("api") else {}), **({"data": p["data"]} if p.get("data") else {})})


@route("DELETE", r"/cluster/acme/plugins/(?P<plugin>[^/]+)")
def acme_delete_plugin(p, u, plugin):
    ACME["plugins"] = [x for x in ACME["plugins"] if x["plugin"] != plugin]


@route("GET", r"/cluster/ha/rules")
def ha_rules(p, u):
    return HA_RULES


@route("POST", r"/cluster/ha/rules")
def ha_add_rule(p, u):
    rule = config_id(p, "rule")
    require(p, "type", "resources")
    if p["type"] == "node-affinity":
        require(p, "nodes")
    if any(r["rule"] == rule for r in HA_RULES):
        raise ApiError(500, f"HA rule '{rule}' already defined")
    HA_RULES.append(p)


@route("PUT", r"/cluster/ha/rules/(?P<rule>[^/]+)")
def ha_update_rule(p, u, rule):
    require(p, "type")
    item = next((r for r in HA_RULES if r["rule"] == rule), None)
    if not item:
        raise ApiError(500, f"HA rule '{rule}' does not exist")
    if p["type"] != item["type"]:
        raise ApiError(400, "Parameter verification failed.", {"type": f"rule '{rule}' is a {item['type']} rule"})
    update_config(item, p)


@route("DELETE", r"/cluster/ha/rules/(?P<rule>[^/]+)")
def ha_delete_rule(p, u, rule):
    HA_RULES[:] = [r for r in HA_RULES if r["rule"] != rule]


@route("GET", r"/cluster/mapping/(?P<kind>pci|usb|dir)")
def mappings(p, u, kind):
    return MAPPINGS[kind]


@route("POST", r"/cluster/mapping/(?P<kind>pci|usb|dir)")
def mapping_add(p, u, kind):
    mid = config_id(p, "id")
    require(p, "map")
    if any(m["id"] == mid for m in MAPPINGS[kind]):
        raise ApiError(500, f"{kind} mapping '{mid}' already exists")
    MAPPINGS[kind].append({"id": mid, "map": p["map"].split("\0"), **({"description": p["description"]} if p.get("description") else {})})


@route("PUT", r"/cluster/mapping/(?P<kind>pci|usb|dir)/(?P<mid>[^/]+)")
def mapping_update(p, u, kind, mid):
    item = next((m for m in MAPPINGS[kind] if m["id"] == mid), None)
    if not item:
        raise ApiError(500, f"{kind} mapping '{mid}' does not exist")
    update_config(item, p, lists=("map",))


@route("DELETE", r"/cluster/mapping/(?P<kind>pci|usb|dir)/(?P<mid>[^/]+)")
def mapping_delete(p, u, kind, mid):
    MAPPINGS[kind] = [m for m in MAPPINGS[kind] if m["id"] != mid]


@route("GET", r"/nodes/(?P<node>[^/]+)/hardware/pci/(?P<pci>[^/]+)/mdev")
def hardware_mdev(p, u, node, pci):
    pci = urllib.parse.unquote(pci)
    if not pci.startswith("0000:01:00") and pci != "gpu0":
        raise ApiError(500, f"PCI device '{pci}' does not support mediated devices")
    return [{"type": "nvidia-63", "name": "GRID P4-1Q", "description": "num_heads=4, frl_config=60, framebuffer=1024M, max_resolution=5120x2880, max_instance=8", "available": 8},
            {"type": "nvidia-65", "name": "GRID P4-4Q", "description": "num_heads=4, frl_config=60, framebuffer=4096M, max_resolution=5120x2880, max_instance=2", "available": 0}]


@route("GET", r"/nodes/(?P<node>[^/]+)/capabilities/qemu/machines")
def qemu_machines(p, u, node):
    allow_only(p, "arch")
    out = []
    for version in ("10.0", "9.2", "9.1", "9.0", "8.2", "8.1", "8.0"):
        for kind, prefix in (("q35", "pc-q35"), ("i440fx", "pc-i440fx")):
            out.append({"id": f"{prefix}-{version}+pve1" if version in ("10.0", "9.2") else f"{prefix}-{version}", "type": kind,
                        "version": f"{version}+pve1" if version in ("10.0", "9.2") else version})
    return out


@route("GET", r"/cluster/qemu/cpu-flags")
def cluster_cpu_flags(p, u):
    allow_only(p, "accel", "arch")
    return qemu_cpu_flags({}, u, list(NODES)[0]) + [{"name": n, "description": "", "supported-on": list(NODES)} for n in ("avx2", "avx512f", "sse4_2", "x2apic", "invtsc")]


@route("GET", r"/nodes/(?P<node>[^/]+)/capabilities/qemu/cpu-flags")
def qemu_cpu_flags(p, u, node):
    allow_only(p, "accel", "arch")
    return [{"name": n, "description": d, "supported-on": list(NODES)} for n, d in (
        ("md-clear", "Required to let the guest OS know if MDS is mitigated correctly"),
        ("pcid", "Meltdown fix cost reduction on Westmere, Sandy-, and IvyBridge Intel CPUs"),
        ("spec-ctrl", "Allows improved Spectre mitigation with Intel CPUs"),
        ("ssbd", "Protection for \"Speculative Store Bypass\" for Intel models"),
        ("ibpb", "Allows improved Spectre mitigation with AMD CPUs"),
        ("virt-ssbd", "Basis for \"Speculative Store Bypass\" protection for AMD models"),
        ("amd-ssbd", "Improves Spectre mitigation performance with AMD CPUs, best used with \"virt-ssbd\""),
        ("amd-no-ssb", "Notifies guest OS that host is not vulnerable for Spectre on AMD CPUs"),
        ("pdpe1gb", "Allow guest OS to use 1GB size pages, if host HW supports it"),
        ("hv-tlbflush", "Improve performance in overcommitted Windows guests. May lead to guest bluescreens on old CPUs."),
        ("hv-evmcs", "Improve performance for nested virtualization. Only supported on Intel CPUs."),
        ("aes", "Activate AES instruction set for HW acceleration."),
        ("nested-virt", "Enable nested virtualization (resolved to vmx or svm when the VM starts)"))]


@route("GET", r"/nodes/(?P<node>[^/]+)/hardware/pci")
def hardware_pci(p, u, node):
    online_node(node)
    return [{"id": "0000:00:02.0", "class": "0x030000", "vendor": "0x8086", "device": "0x3e92", "vendor_name": "Intel Corporation", "device_name": "CoffeeLake-S GT2 [UHD Graphics 630]", "iommugroup": 1},
            {"id": "0000:01:00.0", "class": "0x030000", "vendor": "0x10de", "device": "0x2531", "vendor_name": "NVIDIA Corporation", "device_name": "GA106 [RTX A2000 12GB]", "iommugroup": 12},
            {"id": "0000:01:00.1", "class": "0x040300", "vendor": "0x10de", "device": "0x228e", "vendor_name": "NVIDIA Corporation", "device_name": "GA106 High Definition Audio Controller", "iommugroup": 12},
            {"id": "0000:03:00.0", "class": "0x020000", "vendor": "0x8086", "device": "0x1533", "vendor_name": "Intel Corporation", "device_name": "I210 Gigabit Network Connection", "iommugroup": 14}]


@route("GET", r"/nodes/(?P<node>[^/]+)/hardware/usb")
def hardware_usb(p, u, node):
    online_node(node)
    return [{"busnum": 1, "devnum": 3, "port": 2, "usbpath": "1-2", "vendid": "0x10c4", "prodid": "0xea60", "manufacturer": "Silicon Labs", "product": "Sonoff Zigbee 3.0 USB Dongle Plus", "speed": "12"},
            {"busnum": 1, "devnum": 4, "port": 4, "usbpath": "1-4", "vendid": "0x046d", "prodid": "0xc52b", "manufacturer": "Logitech, Inc.", "product": "Unifying Receiver", "speed": "12"},
            {"busnum": 2, "devnum": 2, "port": 1, "usbpath": "2-1", "vendid": "0x0781", "prodid": "0x5583", "manufacturer": "SanDisk Corp.", "product": "Ultra Fit", "speed": "5000"}]


@route("GET", r"/cluster/config/join")
def cluster_join(p, u):
    if not CLUSTER["name"]:
        raise ApiError(500, "unable to read file '/etc/pve/corosync.conf' - No such file or directory")
    return {"preferred_node": list(NODES)[0], "config_digest": "c0ffee",
            "totem": {"cluster_name": CLUSTER["name"], "config_version": "4", "interface": {"0": {"linknumber": "0"}}, "ip_version": "ipv4-6", "secauth": "on", "version": "2"},
            "nodelist": [{"name": n, "nodeid": str(i + 1), "pve_addr": info["ip"], "pve_fp": FINGERPRINT, "quorum_votes": "1", "ring0_addr": info["ip"]}
                         for i, (n, info) in enumerate(NODES.items())]}


@route("POST", r"/cluster/config")
def cluster_create(p, u):
    name = config_id(p, "clustername")
    if CLUSTER["name"]:
        raise ApiError(500, "cluster config '/etc/pve/corosync.conf' already exists")
    return new_task(list(NODES)[0], "clustercreate", name, u, 2.0, on_done=lambda: CLUSTER.update(name=name))["upid"]


@route("POST", r"/cluster/config/join")
def cluster_join_post(p, u):
    require(p, "hostname", "fingerprint", "password")
    if CLUSTER["name"]:
        raise ApiError(500, "detected the following error(s):\n* this host already contains virtual guests\n* corosync is already running, is this node already in a cluster?!")
    return new_task(list(NODES)[0], "clusterjoin", "", u, 3.0, on_done=lambda: CLUSTER.update(name="homelab"))["upid"]


# node extras
@route("GET", r"/nodes/(?P<node>[^/]+)/apt/repositories")
def apt_repos(p, u, node):
    repos = [{"Types": ["deb"], "URIs": ["http://deb.debian.org/debian"], "Suites": ["trixie", "trixie-updates"], "Components": ["main", "contrib"], "Enabled": REPOS_ENABLED[0]},
             {"Types": ["deb"], "URIs": ["https://enterprise.proxmox.com/debian/pve"], "Suites": ["trixie"], "Components": ["pve-enterprise"], "Enabled": REPOS_ENABLED[1]},
             {"Types": ["deb"], "URIs": ["http://download.proxmox.com/debian/pve"], "Suites": ["trixie"], "Components": ["pve-no-subscription"], "Enabled": REPOS_ENABLED[2]}]
    return {"files": [{"path": "/etc/apt/sources.list.d/debian.sources", "repositories": repos[:1]},
                      {"path": "/etc/apt/sources.list.d/pve.sources", "repositories": repos[1:]}],
            "standard-repos": [{"handle": "enterprise", "name": "Enterprise", "status": 1 if REPOS_ENABLED[1] else 0},
                               {"handle": "no-subscription", "name": "No-Subscription", "status": 1 if REPOS_ENABLED[2] else 0},
                               {"handle": "test", "name": "Test", "status": None}],
            "errors": [], "infos": [], "digest": "d1g3st"}


@route("POST", r"/nodes/(?P<node>[^/]+)/apt/repositories")
def apt_repo_toggle(p, u, node):
    path, index = p.get("path", ""), int(p.get("index", 0))
    REPOS_ENABLED[index + (1 if path.endswith("pve.sources") else 0)] = p.get("enabled") == "1"


@route("PUT", r"/nodes/(?P<node>[^/]+)/apt/repositories")
def apt_repo_add(p, u, node):
    return None


@route("GET", r"/nodes/(?P<node>[^/]+)/report")
def node_report(p, u, node):
    return f"==== general system info ====\n\n# hostname\n{node}\n\n# pveversion --verbose\nproxmox-ve: 9.0.0 (running kernel: 6.14.11-2-pve)\npve-manager: 9.0.11\n\n==== storage ====\n\n# pvesm status\nName         Type     Status   Total\nlocal        dir      active   98566144\n"


@route("POST", r"/nodes/(?P<node>[^/]+)/certificates/custom")
def upload_cert(p, u, node):
    if "BEGIN CERTIFICATE" not in p.get("certificates", ""):
        raise ApiError(400, "Parameter verification failed.", {"certificates": "not a PEM certificate"})


@route("DELETE", r"/nodes/(?P<node>[^/]+)/certificates/custom")
def delete_cert(p, u, node):
    return None


@route("POST", r"/nodes/(?P<node>[^/]+)/certificates/acme/certificate")
def acme_order(p, u, node):
    if not any(k.startswith("acmedomain") for k in NODE_EXTRA[node].get("config", {})):
        raise ApiError(500, "No ACME domains configured for this node. Add a domain under Certificates first.")
    return new_task(node, "acmenewcert", "", u, 3.0, log=["Loading ACME account details", "Placing ACME order", "Validating domain", "Certificate installed"])["upid"]


@route("POST", r"/nodes/(?P<node>[^/]+)/wakeonlan")
def wake(p, u, node):
    raise ApiError(500, f"No wake-on-LAN MAC address configured for '{node}'")


DISK_STORES = {}


def disk_stores(node):
    """Volume groups, thin pools, directories and ZFS pools made on a node's disks; create adds, destroy removes."""
    return DISK_STORES.setdefault(node, {
        "lvm": [{"name": "pve", "size": 999116767232, "free": 16106127360, "pv": "/dev/nvme0n1p3"}],
        "lvmthin": [{"lv": "data", "vg": "pve", "lv_size": 832 * GiB, "used": int(832 * GiB * 0.81), "metadata_size": 8 * GiB, "metadata_used": int(8 * GiB * 0.12)}],
        "directory": [{"path": "/mnt/pve/backups", "device": "/dev/sdd1", "type": "ext4", "options": "defaults", "unitfile": "/etc/systemd/system/mnt-pve-backups.mount"}],
        "zfs": [{"name": "tank", "size": 3985729650688, "alloc": 1820000000000, "free": 2165729650688, "frag": 7, "dedup": 1.0, "health": "ONLINE"}],
    })


# Storage scans: what the Add Storage forms offer to pick from.
@route("GET", r"/nodes/(?P<node>[^/]+)/scan/(?P<kind>nfs|cifs|pbs|iscsi)")
def scan_remote(p, u, node, kind):
    need = {"nfs": ("server",), "cifs": ("server",), "pbs": ("server", "username", "password"), "iscsi": ("portal",)}[kind]
    allow_only(p, *{"nfs": ("server",), "cifs": ("server", "username", "password", "domain"),
                    "pbs": ("server", "username", "password", "fingerprint", "port"), "iscsi": ("portal",)}[kind])
    require(p, *need)
    host = p.get("server") or p.get("portal")
    if not host.startswith(("192.168.", "10.", "nas", "pbs", "truenas")):
        raise ApiError(500, f"storage '{host}' is not online")
    if kind == "nfs":
        return [{"path": "/mnt/tank/pve", "options": "192.168.1.0/24"}, {"path": "/mnt/tank/isos", "options": "*"}]
    if kind == "cifs":
        if not p.get("username"):
            raise ApiError(500, "NT_STATUS_ACCESS_DENIED")
        return [{"share": "proxmox", "description": "Proxmox backups"}, {"share": "media", "description": ""}]
    if kind == "pbs":
        return [{"store": "store1", "comment": "Main datastore"}, {"store": "offsite"}]
    return [{"target": "iqn.2005-10.org.freenas.ctl:pve", "portal": host + ":3260"}]


@route("GET", r"/nodes/(?P<node>[^/]+)/scan/(?P<kind>lvm|lvmthin|zfs)")
def scan_local(p, u, node, kind):
    stores = disk_stores(node)
    if kind == "lvm":
        return [{"vg": vg["name"]} for vg in stores["lvm"]]
    if kind == "lvmthin":
        require(p, "vg")
        return [{"lv": t["lv"]} for t in stores["lvmthin"] if t.get("vg") == p["vg"]]
    return [{"pool": z["name"]} for z in stores["zfs"]]


@route("GET", r"/nodes/(?P<node>[^/]+)/disks/lvm")
def disks_lvm(p, u, node):
    vgs = [{"name": vg["name"], "size": vg["size"], "free": vg["free"], "leaf": 0,
            "children": [{"name": vg["pv"], "size": vg["size"], "free": vg["free"], "leaf": 1}]} for vg in disk_stores(node)["lvm"]]
    return [{"leaf": 0, "children": vgs}]


@route("GET", r"/nodes/(?P<node>[^/]+)/disks/lvmthin")
def disks_lvmthin(p, u, node):
    return disk_stores(node)["lvmthin"]


@route("GET", r"/nodes/(?P<node>[^/]+)/disks/directory")
def disks_directory(p, u, node):
    return disk_stores(node)["directory"]


@route("POST", r"/nodes/(?P<node>[^/]+)/disks/(?P<kind>lvm|lvmthin|directory|zfs)")
def disks_create(p, u, node, kind):
    if not p.get("name"):
        raise ApiError(400, "Parameter verification failed.", {"name": "property is missing and it is not optional"})
    name, stores = p["name"], disk_stores(node)
    entry = {"lvm": {"name": name, "size": 477 * GiB, "free": 477 * GiB, "pv": p.get("device", "/dev/sdc")},
             "lvmthin": {"lv": name, "vg": name, "lv_size": 470 * GiB, "used": 0, "metadata_size": 4 * GiB, "metadata_used": 0},
             "directory": {"path": f"/mnt/pve/{name}", "device": p.get("device", "/dev/sdc") + "1", "type": p.get("filesystem", "ext4"),
                           "options": "defaults", "unitfile": f"/etc/systemd/system/mnt-pve-{name}.mount"},
             "zfs": {"name": name, "size": 477 * GiB, "alloc": 0, "free": 477 * GiB, "frag": 0, "dedup": 1.0, "health": "ONLINE"}}[kind]
    stores[kind].append(entry)
    return new_task(node, {"zfs": "zfscreate", "lvm": "lvmcreate", "lvmthin": "lvmthincreate", "directory": "dircreate"}[kind], name, u, 3.0)["upid"]


@route("DELETE", r"/nodes/(?P<node>[^/]+)/disks/(?P<kind>lvm|lvmthin|directory|zfs)/(?P<name>[^/]+)")
def disks_destroy(p, u, node, kind, name):
    allow_only(p, "cleanup-config", "cleanup-disks", *(("volume-group",) if kind == "lvmthin" else ()))
    if kind == "lvmthin" and not p.get("volume-group"):
        raise ApiError(400, "Parameter verification failed.", {"volume-group": "property is missing and it is not optional"})
    stores = disk_stores(node)
    key = {"lvm": "name", "lvmthin": "lv", "zfs": "name"}.get(kind)
    before = len(stores[kind])
    if kind == "directory":
        stores[kind] = [d for d in stores[kind] if d["path"].rsplit("/", 1)[-1] != name]
    else:
        stores[kind] = [d for d in stores[kind] if d[key] != name]
    if len(stores[kind]) == before:
        raise ApiError(500, f"no such {kind} storage '{name}'")
    log = [f"destroying {kind} '{name}'"] + (["removing storage configuration"] if p.get("cleanup-config") == "1" else []) + (["wiping disks"] if p.get("cleanup-disks") == "1" else [])
    return new_task(node, {"zfs": "zfsremove", "lvm": "lvmremove", "lvmthin": "lvmthinremove", "directory": "dirremove"}[kind], name, u, 2.0, log=log)["upid"]


@route("POST", r"/nodes/(?P<node>[^/]+)/disks/initgpt")
def disks_initgpt(p, u, node):
    if p.get("disk") != "/dev/sdc":
        raise ApiError(500, f"disk '{p.get('disk')}' is already in use")
    return new_task(node, "diskinit", p["disk"], u, 1.5)["upid"]


@route("PUT", r"/nodes/(?P<node>[^/]+)/disks/wipedisk")
def disks_wipe(p, u, node):
    if p.get("disk") != "/dev/sdc":
        raise ApiError(500, f"disk '{p.get('disk')}' is used by LVM/ZFS - refusing to wipe")
    return new_task(node, "wipedisk", p["disk"], u, 2.0)["upid"]


# Ceph moves through "missing" (packages not installed), "installed" (not configured) and "ready".
CEPH = {"state": "missing" if PROFILE == "stress" else "ready",
        "osds": {0: {"in": 1, "up": 1, "host": "pve1", "dev": "/dev/nvme1n1"}, 1: {"in": 1, "up": 1, "host": "pve2", "dev": "/dev/nvme1n1"},
                 2: {"in": 1, "up": 1, "host": "pve1", "dev": "/dev/nvme2n1"}},
        "pools": [{"pool": 1, "pool_name": ".mgr", "size": 3, "min_size": 2, "pg_num": 1, "bytes_used": 2 * 1024 ** 2, "percent_used": 0.0001},
                  {"pool": 2, "pool_name": "vm-pool", "size": 3, "min_size": 2, "pg_num": 128, "bytes_used": 412 * GiB, "percent_used": 0.18}],
        "mon": [{"name": "pve1", "host": "pve1"}, {"name": "pve2", "host": "pve2"}],
        "mgr": [{"name": "pve1", "host": "pve1"}, {"name": "pve2", "host": "pve2"}],
        "mds": [], "fs": [],
        "flags": {"noout": 0, "noin": 0, "nobackfill": 0, "norebalance": 0, "norecover": 0, "noscrub": 0, "nodeep-scrub": 0, "pause": 0},
        "mutes": {}}
CEPH_FLAG_TEXT = {"noout": "OSDs will not automatically be marked out after the configured interval",
                  "noin": "OSDs that were previously marked out will not be marked back in when they start",
                  "nobackfill": "Backfilling of PGs is suspended", "norebalance": "Rebalancing of PGs is suspended",
                  "norecover": "Recovery of PGs is suspended", "noscrub": "Scrubbing is disabled", "nodeep-scrub": "Deep Scrubbing is disabled",
                  "pause": "Pauses read and writes"}


def ceph_node(node, need="ready"):
    online_node(node)
    if CEPH["state"] == "missing":
        raise ApiError(500, "binary not installed: /usr/bin/ceph-mon")
    if CEPH["state"] == "installed" and need == "ready":
        raise ApiError(500, "pveceph configuration not initialized - missing '/etc/pve/ceph.conf'")


@route("GET", r"/nodes/(?P<node>[^/]+)/ceph/releases")
def ceph_releases(p, u, node):
    return [{"release": "squid", "version": "19.2", "available": 1}, {"release": "tentacle", "version": "20.2", "available": 1}]


@route("POST", r"/nodes/(?P<node>[^/]+)/ceph/init")
def ceph_init(p, u, node):
    ceph_node(node, need="installed")
    if CEPH["state"] == "ready":
        raise ApiError(500, "Ceph is already configured (/etc/pve/ceph.conf exists)")
    require(p, "network")
    CEPH.update(state="ready", osds={}, pools=[], mon=[], mgr=[], mds=[], fs=[])


@route("GET", r"/nodes/(?P<node>[^/]+)/ceph/status")
def ceph_status(p, u, node):
    ceph_node(node)
    checks = {}
    if any(not osd["in"] or not osd["up"] for osd in CEPH["osds"].values()):
        checks["PG_DEGRADED"] = {"severity": "HEALTH_WARN", "summary": {"message": "Degraded data redundancy: 1204/315000 objects degraded (0.382%), 12 pgs degraded"}}
    if len(CEPH["osds"]) < 3:
        checks["TOO_FEW_OSDS"] = {"severity": "HEALTH_WARN", "summary": {"message": f"OSD count {len(CEPH['osds'])} < osd_pool_default_size 3"}}
    if any(CEPH["flags"].values()):
        checks["OSDMAP_FLAGS"] = {"severity": "HEALTH_WARN", "summary": {"message": ",".join(k for k, v in CEPH["flags"].items() if v) + " flag(s) set"}}
    checks["RECENT_CRASH"] = {"severity": "HEALTH_WARN", "summary": {"message": "1 daemons have recently crashed", "count": 1}}
    for code, check in checks.items():
        if code in CEPH["mutes"]:
            check["muted"] = True
    used = sum(pool["bytes_used"] for pool in CEPH["pools"]) * 3
    loud = [c for c in checks.values() if not c.get("muted")]
    return {"fsid": "4f1b3a52-6a1e-4f43-9a8e-0c6d1e5b2a77",
            "health": {"status": "HEALTH_WARN" if loud else "HEALTH_OK", "checks": checks,
                       "mutes": [{"code": c, "sticky": m["sticky"], "summary": checks.get(c, {}).get("summary", {}).get("message", ""), "count": 1} for c, m in CEPH["mutes"].items()]},
            "pgmap": {"bytes_used": used, "bytes_total": len(CEPH["osds"]) * 1800 * GiB, "num_pgs": sum(pool["pg_num"] for pool in CEPH["pools"]),
                      "num_objects": 105012 if CEPH["pools"] else 0, "read_bytes_sec": 12_400_000, "write_bytes_sec": 3_350_000}}


@route("PUT", r"/cluster/ceph/health-mute/(?P<code>[^/]+)")
def ceph_mute(p, u, code):
    allow_only(p, "sticky", "ttl", "value")
    if p.get("value") in ("1", "true"):
        CEPH["mutes"][code] = {"sticky": p.get("sticky") in ("1", "true"), "ttl": p.get("ttl")}
    else:
        CEPH["mutes"].pop(code, None)


@route("POST", r"/cluster/ceph/restart-bulk")
def ceph_restart_cluster(p, u):
    allow_only(p, "dry-run", "force", "only-outdated", "service-type", "timeout")
    kind = p.get("service-type")
    if kind not in ("mon", "mgr", "mds", "osd"):
        raise ApiError(400, "Parameter verification failed.", {"service-type": "value must be one of mon, mgr, mds, osd"})
    daemons = [f"osd.{i}" for i in sorted(CEPH["osds"])] if kind == "osd" else [f"{kind}.{d['name']}" for d in CEPH[kind]]
    verb = "would restart" if p.get("dry-run") == "1" else "restarting"
    return new_task(list(NODES)[0], "cephrestartbulk", kind, u, 2.5, log=[f"rolling restart plan: {', '.join(daemons) or 'nothing to do'}"] + [f"{verb} {d}" for d in daemons])["upid"]


@route("POST", r"/nodes/(?P<node>[^/]+)/ceph/restart-bulk")
def ceph_restart_node(p, u, node):
    ceph_node(node)
    allow_only(p, "dry-run", "force", "only-outdated", "resume", "service-type", "set-noout", "timeout")
    if p.get("service-type") != "osd":
        raise ApiError(400, "Parameter verification failed.", {"service-type": "only 'osd' can be restarted per node"})
    daemons = [f"osd.{i}" for i, o in sorted(CEPH["osds"].items()) if o["host"] == node]
    verb = "would restart" if p.get("dry-run") == "1" else "restarting"
    return new_task(node, "cephrestartbulk", "osd", u, 2.5, log=([f"setting noout on {', '.join(daemons)}"] if p.get("set-noout") == "1" else []) + [f"{verb} {d}" for d in daemons])["upid"]


@route("GET", r"/nodes/(?P<node>[^/]+)/ceph/rules")
def ceph_rules(p, u, node):
    ceph_node(node)
    return [{"name": "replicated_rule"}, {"name": "nvme-only"}]


@route("GET", r"/nodes/(?P<node>[^/]+)/ceph/cmd-safety")
def ceph_cmd_safety(p, u, node):
    """Like Ceph's ok-to-stop / safe-to-destroy, roughly."""
    ceph_node(node)
    service, sid, action = p.get("service"), p.get("id"), p.get("action")
    if service == "osd":
        osd = CEPH["osds"].get(int(sid or -1))
        if not osd:
            raise ApiError(500, f"OSD {sid} does not exist")
        if action == "stop":
            up = sum(1 for o in CEPH["osds"].values() if o["up"])
            return {"safe": up > 3, "status": "" if up > 3 else f"{up - 1} OSDs would stay up; some placement groups would become inactive"}
        return {"safe": not osd["in"] and not osd["up"], "status": "" if not osd["in"] and not osd["up"] else "OSD is still in use: mark it out and stop it first"}
    if service == "mon":
        left = len(CEPH["mon"]) - 1
        return {"safe": left >= 2 or action == "stop" and left >= 1, "status": "" if left >= 2 else f"only {left} monitor would remain; the cluster loses quorum"}
    return {"safe": True, "status": ""}


@route("GET", r"/nodes/(?P<node>[^/]+)/ceph/osd")
def ceph_osds(p, u, node):
    ceph_node(node)
    hosts = sorted({osd["host"] for osd in CEPH["osds"].values()})
    return {"flags": "sortbitwise,recovery_deletes,purged_snapdirs,pglog_hardlimit",
            "root": {"name": "default", "type": "root", "children": [
                {"name": host, "type": "host", "children": [
                    {"id": i, "name": f"osd.{i}", "type": "osd", "host": host, "in": osd["in"], "status": "up" if osd["up"] else "down",
                     "device_class": "nvme", "crush_weight": 1.7466, "percent_used": 23.4, "total_space": 1800 * GiB}
                    for i, osd in sorted(CEPH["osds"].items()) if osd["host"] == host]}
                for host in hosts]}}


@route("POST", r"/nodes/(?P<node>[^/]+)/ceph/osd")
def ceph_create_osd(p, u, node):
    ceph_node(node)
    require(p, "dev")
    if any(osd["host"] == node and osd["dev"] == p["dev"] for osd in CEPH["osds"].values()):
        raise ApiError(500, f"device '{p['dev']}' is already in use")
    osd_id = max(CEPH["osds"], default=-1) + 1
    return new_task(node, "cephcreateosd", p["dev"].split("/")[-1], u, 3.0,
                    on_done=lambda: CEPH["osds"].__setitem__(osd_id, {"in": 1, "up": 1, "host": node, "dev": p["dev"]}))["upid"]


def require_osd(osd):
    if int(osd) not in CEPH["osds"]:
        raise ApiError(500, f"osd.{osd} does not exist")
    return CEPH["osds"][int(osd)]


@route("DELETE", r"/nodes/(?P<node>[^/]+)/ceph/osd/(?P<osd>\d+)")
def ceph_destroy_osd(p, u, node, osd):
    ceph_node(node)
    item = require_osd(osd)
    if item["in"]:
        raise ApiError(500, f"osd is in - unable to destroy (mark it out first)")
    if item["up"]:
        raise ApiError(500, f"osd is still running - stop it first")
    return new_task(node, "cephdestroyosd", osd, u, 2.0, on_done=lambda: CEPH["osds"].pop(int(osd), None))["upid"]


@route("POST", r"/nodes/(?P<node>[^/]+)/ceph/osd/(?P<osd>\d+)/(?P<action>in|out|scrub)")
def ceph_osd_action(p, u, node, osd, action):
    ceph_node(node)
    item = require_osd(osd)
    if action != "scrub":
        item["in"] = 1 if action == "in" else 0


@route("POST", r"/nodes/(?P<node>[^/]+)/ceph/(?P<action>start|stop|restart)")
def ceph_service(p, u, node, action):
    ceph_node(node)
    service = p.get("service", "ceph.target")
    kind, _, name = service.partition(".")
    if kind == "osd":
        require_osd(name)["up"] = 0 if action == "stop" else 1
    return new_task(node, "srv" + action, service, u, 1.0)["upid"]


@route("GET", r"/nodes/(?P<node>[^/]+)/ceph/(?P<kind>mon|mgr|mds)")
def ceph_daemons(p, u, node, kind):
    ceph_node(node)
    addr = {n: info["ip"] for n, info in NODES.items()}
    return [{"name": d["name"], "host": d["host"], "addr": f"{addr.get(d['host'], '')}:6789/0", "state": "active" if kind == "mgr" and i == 0 else ("standby" if kind != "mon" else "running"),
             **({"quorum": 1} if kind == "mon" else {})} for i, d in enumerate(CEPH[kind])]


@route("POST", r"/nodes/(?P<node>[^/]+)/ceph/(?P<kind>mon|mgr|mds)/(?P<name>[^/]+)")
def ceph_create_daemon(p, u, node, kind, name):
    ceph_node(node)
    if any(d["name"] == name for d in CEPH[kind]):
        raise ApiError(500, f"{kind} '{name}' already exists")
    def done():
        CEPH[kind].append({"name": name, "host": node})
        if kind == "mon" and not CEPH["mgr"]:
            CEPH["mgr"].append({"name": name, "host": node})
    return new_task(node, f"cephcreate{kind}", name, u, 2.0, on_done=done)["upid"]


@route("DELETE", r"/nodes/(?P<node>[^/]+)/ceph/(?P<kind>mon|mgr|mds)/(?P<name>[^/]+)")
def ceph_destroy_daemon(p, u, node, kind, name):
    ceph_node(node)
    if kind == "mon" and len(CEPH["mon"]) == 1:
        raise ApiError(500, "can't remove last monitor")
    return new_task(node, f"cephdestroy{kind}", name, u, 2.0,
                    on_done=lambda: CEPH.__setitem__(kind, [d for d in CEPH[kind] if d["name"] != name]))["upid"]


@route("GET", r"/nodes/(?P<node>[^/]+)/ceph/fs")
def ceph_fs_list(p, u, node):
    ceph_node(node)
    return CEPH["fs"]


@route("POST", r"/nodes/(?P<node>[^/]+)/ceph/fs/(?P<name>[^/]+)")
def ceph_fs_create(p, u, node, name):
    ceph_node(node)
    if not CEPH["mds"]:
        raise ApiError(500, "need an MDS before creating a CephFS")
    def done():
        CEPH["fs"].append({"name": name, "data_pool": f"{name}_data", "metadata_pool": f"{name}_metadata"})
        for suffix in ("data", "metadata"):
            CEPH["pools"].append({"pool": len(CEPH["pools"]) + 1, "pool_name": f"{name}_{suffix}", "size": 3, "min_size": 2, "pg_num": 32, "bytes_used": 0, "percent_used": 0})
    return new_task(node, "cephfscreate", name, u, 2.0, on_done=done)["upid"]


@route("GET", r"/nodes/(?P<node>[^/]+)/ceph/cfg/raw")
def ceph_conf(p, u, node):
    ceph_node(node)
    mons = " ".join(NODES[d["host"]]["ip"] for d in CEPH["mon"] if d["host"] in NODES)
    return (f"[global]\n\tauth_client_required = cephx\n\tauth_cluster_required = cephx\n\tauth_service_required = cephx\n"
            f"\tcluster_network = 192.168.1.0/24\n\tfsid = 4f1b3a52-6a1e-4f43-9a8e-0c6d1e5b2a77\n\tmon_allow_pool_delete = true\n"
            f"\tmon_host = {mons}\n\tosd_pool_default_min_size = 2\n\tosd_pool_default_size = 3\n\tpublic_network = 192.168.1.0/24\n\n"
            "[client]\n\tkeyring = /etc/pve/priv/$cluster.$name.keyring\n")


@route("GET", r"/nodes/(?P<node>[^/]+)/ceph/cfg/db")
def ceph_conf_db(p, u, node):
    ceph_node(node)
    return [{"section": "global", "name": "osd_pool_default_pg_autoscale_mode", "value": "on", "level": "advanced", "can_update_at_runtime": 1},
            {"section": "mgr", "name": "mgr/dashboard/server_addr", "value": "::", "level": "advanced", "can_update_at_runtime": 0}]


@route("GET", r"/nodes/(?P<node>[^/]+)/ceph/crush")
def ceph_crush(p, u, node):
    ceph_node(node)
    lines = ["# begin crush map", "tunable choose_total_tries 50", "", "# devices"]
    lines += [f"device {i} osd.{i} class nvme" for i in sorted(CEPH["osds"])]
    lines += ["", "# rules", "rule replicated_rule {", "\tid 0", "\ttype replicated", "\tstep take default", "\tstep chooseleaf firstn 0 type host", "\tstep emit", "}", "", "# end crush map"]
    return "\n".join(lines) + "\n"


@route("GET", r"/nodes/(?P<node>[^/]+)/ceph/log")
def ceph_log(p, u, node):
    ceph_node(node)
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now() - 60))
    return [{"n": i + 1, "t": f"{stamp}.{i:06d}+0200 mon.{node} (mon.0) {i} : cluster [DBG] pgmap v{1200 + i}: 129 pgs: 129 active+clean; 412 GiB data, 1.2 TiB used, 4.1 TiB / 5.3 TiB avail"}
            for i in range(12)]


@route("GET", r"/cluster/ceph/flags")
def ceph_flags(p, u):
    if CEPH["state"] != "ready":
        raise ApiError(500, "pveceph configuration not initialized")
    return [{"name": k, "value": v, "description": CEPH_FLAG_TEXT[k]} for k, v in CEPH["flags"].items()]


@route("PUT", r"/cluster/ceph/flags")
def ceph_set_flags(p, u):
    for k, v in p.items():
        if k in CEPH["flags"]:
            CEPH["flags"][k] = 1 if v in ("1", "true") else 0
    return new_task(list(NODES)[0], "cephsetflags", "", u, 1.0)["upid"]


@route("GET", r"/nodes/(?P<node>[^/]+)/ceph/pool")
def ceph_pools(p, u, node):
    ceph_node(node)
    return CEPH["pools"]


@route("POST", r"/nodes/(?P<node>[^/]+)/ceph/pool")
def ceph_add_pool(p, u, node):
    ceph_node(node)
    name = config_id(p, "name")
    if any(pool["pool_name"] == name for pool in CEPH["pools"]):
        raise ApiError(500, f"pool '{name}' already exists")
    if p.get("crush_rule") and p["crush_rule"] not in ("replicated_rule", "nvme-only"):
        raise ApiError(500, f"crush rule '{p['crush_rule']}' does not exist")
    pool = {"pool": len(CEPH["pools"]) + 1, "pool_name": name, "size": int(p.get("size", 3)), "min_size": int(p.get("min_size", 2)), "pg_num": int(p.get("pg_num", 32)),
            "crush_rule_name": p.get("crush_rule", "replicated_rule"), "pg_autoscale_mode": p.get("pg_autoscale_mode", "on"), "bytes_used": 0, "percent_used": 0}
    return new_task(node, "cephcreatepool", name, u, 2.0, on_done=lambda: CEPH["pools"].append(pool))["upid"]


@route("PUT", r"/nodes/(?P<node>[^/]+)/ceph/pool/(?P<name>[^/]+)")
def ceph_edit_pool(p, u, node, name):
    ceph_node(node)
    pool = next((x for x in CEPH["pools"] if x["pool_name"] == name), None)
    if not pool:
        raise ApiError(500, f"pool '{name}' does not exist")
    for key in ("size", "min_size", "pg_num"):
        if key in p:
            pool[key] = int(p[key])
    if "pg_autoscale_mode" in p:
        pool["pg_autoscale_mode"] = p["pg_autoscale_mode"]
    return new_task(node, "cephsetpool", name, u, 1.0)["upid"]


@route("DELETE", r"/nodes/(?P<node>[^/]+)/ceph/pool/(?P<name>[^/]+)")
def ceph_delete_pool(p, u, node, name):
    ceph_node(node)
    return new_task(node, "cephdestroypool", name, u, 2.0, on_done=lambda: CEPH["pools"].__setitem__(slice(None), [x for x in CEPH["pools"] if x["pool_name"] != name]))["upid"]


FS_TREE = {
    "": [("etc", "d"), ("home", "d"), ("root", "d"), ("var", "d")],
    "etc": [("fstab", "f", 512), ("hostname", "f", 12), ("hosts", "f", 220), ("nginx", "d"), ("ssh", "d")],
    "etc/nginx": [("nginx.conf", "f", 1480), ("sites-enabled", "d")],
    "etc/nginx/sites-enabled": [("default", "f", 2412)],
    "etc/ssh": [("sshd_config", "f", 3250)],
    "home": [("admin", "d")],
    "home/admin": [(".bashrc", "f", 3771), ("notes.md", "f", 845), ("projects", "d")],
    "home/admin/projects": [("app.tar.gz", "f", 18_204_331)],
    "root": [(".bash_history", "f", 9321)],
    "var": [("lib", "d"), ("log", "d")],
    "var/lib": [],
    "var/log": [("auth.log", "f", 88_221), ("syslog", "f", 1_204_331)],
}


def restore_base(volid):
    image = "drive-scsi0.img.fidx" if "/vm/" in volid else "root.pxar.didx"
    return image, (f"/{image}/part/2" if "/vm/" in volid else f"/{image}")


def restore_items(volid, path):
    image, base = restore_base(volid)
    fixed = {"/": [(image, "v")], f"/{image}": [("part", "d")], f"/{image}/part": [("1", "d"), ("2", "d")], f"/{image}/part/1": [("EFI", "d")],
             f"/{image}/part/1/EFI": []} if "/vm/" in volid else {"/": [(image, "v")]}
    if path in fixed:
        return fixed[path]
    rel = path[len(base):].strip("/") if path == base or path.startswith(base + "/") else None
    if rel is None or rel not in FS_TREE:
        raise ApiError(500, f"'{path}' is not a directory in this backup")
    return FS_TREE[rel]


def b64(text):
    return base64.b64encode(text.encode()).decode()


@route("GET", r"/nodes/(?P<node>[^/]+)/storage/(?P<sid>[^/]+)/file-restore/list")
def file_restore_list(p, u, node, sid):
    if STORAGES.get(sid, {}).get("type") != "pbs":
        raise ApiError(500, "file-restore is only available for Proxmox Backup Server storages")
    path = base64.b64decode(p.get("filepath", "Lw==")).decode() or "/"
    items = restore_items(p.get("volume", ""), path)
    if path.endswith("drive-scsi0.img.fidx") or path.endswith("root.pxar.didx"):
        time.sleep(1.5)  # the real thing boots a restore VM here
    return [{"filepath": b64(path.rstrip("/") + "/" + item[0]), "text": item[0], "type": item[1], "leaf": 1 if item[1] == "f" else 0,
             **({"size": item[2]} if len(item) > 2 else {}), "mtime": now() - 86400} for item in items]


@route("GET", r"/nodes/(?P<node>[^/]+)/storage/(?P<sid>[^/]+)/import-metadata")
def import_metadata(p, u, node, sid):
    volid = p.get("volume", "")
    if not any(v["volid"] == volid for v in content_for(node, sid)):
        raise ApiError(500, f"volume '{volid}' does not exist")
    name = volid.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    if volid.endswith(".ova"):
        return {"type": "vm", "source": volid, "create-args": {"name": name, "ostype": "l26", "memory": 4096, "cores": 2, "sockets": 1, "bios": "ovmf", "scsihw": "virtio-scsi-single"},
                "disks": {"scsi0": {"volid": f"{volid}/{name}-disk1.vmdk", "size": 32 * GiB}, "efidisk0": {"volid": f"{volid}/nvram", "size": 0}},
                "net": {"net0": {"model": "virtio"}}, "warnings": [{"type": "ova-needs-extracting"}]}
    windows = "win" in name
    return {"type": "vm", "source": volid,
            "create-args": {"name": name, "ostype": "win10" if windows else "l26", "memory": 8192 if windows else 4096, "cores": 4, "sockets": 1,
                            "bios": "ovmf" if windows else "seabios", "scsihw": "pvscsi", "ide2": f"{volid.rsplit('/', 2)[0]}/iso/setup.iso,media=cdrom"},
            "disks": {"scsi0": {"volid": volid.replace(".vmx", ".vmdk"), "size": 64 * GiB},
                      **({"scsi1": {"volid": volid.replace(".vmx", "_1.vmdk"), "size": 500 * GiB}, "efidisk0": {"volid": volid.replace(".vmx", ".nvram")}} if windows else {})},
            "net": {"net0": {"model": "vmxnet3", "macaddr": "00:50:56:9a:%02x:34" % len(name)}},
            "warnings": [{"type": "guest-is-running"}] if name == "web01" else []}


class RawFile:
    def __init__(self, data, name):
        self.data, self.name = data, name


@route("GET", r"/nodes/(?P<node>[^/]+)/storage/(?P<sid>[^/]+)/file-restore/download")
def file_restore_download(p, u, node, sid):
    path = base64.b64decode(p.get("filepath", "")).decode()
    name = path.rstrip("/").split("/")[-1] or "backup"
    _, base = restore_base(p.get("volume", ""))
    rel = path[len(base):].strip("/") if path.startswith(base) else None
    if rel is not None and rel not in FS_TREE:
        return RawFile(f"Contents of {path} (from the mock backup)\n".encode(), name)
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        def add(folder, prefix):
            for item in FS_TREE.get(folder, []):
                child = f"{folder}/{item[0]}".strip("/")
                if item[1] == "d":
                    add(child, f"{prefix}{item[0]}/")
                else:
                    archive.writestr(f"{prefix}{item[0]}", f"Contents of /{child} (from the mock backup)\n")
        if rel is None:
            archive.writestr("README.txt", "This folder holds a file system; open it to restore its files.\n")
        else:
            add(rel, "")
    return RawFile(buffer.getvalue(), name + ".zip")


@route("POST", r"/nodes/(?P<node>[^/]+)/spiceshell")
def spiceshell(p, u, node):
    online_node(node)
    return {"type": "spice", "host": f"pvespiceproxy:{secrets.token_hex(8)}:0:{node}::{secrets.token_hex(8)}", "port": 61000, "tls-port": 61001,
            "password": secrets.token_hex(12), "proxy": f"http://{p.get('proxy', '127.0.0.1')}:3128", "title": f"Shell on {node}", "delete-this-file": 1}


@route("POST", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/spiceproxy")
def spiceproxy(p, u, node, kind, vmid):
    g = require_guest(int(vmid))
    if g["status"] != "running":
        raise ApiError(500, f"VM {vmid} not running")
    return {"type": "spice", "host": f"pvespiceproxy:{secrets.token_hex(8)}:{vmid}:{node}::{secrets.token_hex(8)}", "port": 61000, "tls-port": 61001,
            "password": secrets.token_hex(12), "proxy": f"http://{p.get('proxy', '127.0.0.1')}:3128", "title": f"VM {vmid} - {guest_name(g)}",
            "delete-this-file": 1, "toggle-fullscreen": "Shift+F11", "release-cursor": "Ctrl+Alt+R", "secure-attention": "Ctrl+Alt+Ins",
            "host-subject": f"OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN={node}.home.lan",
            "ca": "-----BEGIN CERTIFICATE-----\\nMIIBmock\\n-----END CERTIFICATE-----\\n"}


NETWORK_EXTRA = {}


@route("POST", r"/nodes/(?P<node>[^/]+)/network")
def network_create(p, u, node):
    NETWORK_EXTRA.setdefault(node, []).append({"iface": p["iface"], "type": p.get("type", "bridge"), "active": 0, "autostart": int(p.get("autostart", 1)),
                                               "method": "static" if p.get("cidr") else "manual", "families": ["inet"],
                                               **{k: v for k, v in p.items() if k not in ("type", "autostart")}})


@route("PUT", r"/nodes/(?P<node>[^/]+)/network")
def network_apply(p, u, node):
    for iface in NETWORK_EXTRA.get(node, []):
        iface["active"] = 1
    return new_task(node, "srvreload", "networking", u, 2.0)["upid"]


@route("DELETE", r"/nodes/(?P<node>[^/]+)/network")
def network_revert(p, u, node):
    NETWORK_EXTRA[node] = [i for i in NETWORK_EXTRA.get(node, []) if i["active"]]


@route("PUT", r"/nodes/(?P<node>[^/]+)/network/(?P<iface>[^/]+)")
def network_update(p, u, node, iface):
    for item in NETWORK_EXTRA.get(node, []):
        if item["iface"] == iface:
            item.update(p)


@route("DELETE", r"/nodes/(?P<node>[^/]+)/network/(?P<iface>[^/]+)")
def network_delete(p, u, node, iface):
    NETWORK_EXTRA[node] = [i for i in NETWORK_EXTRA.get(node, []) if i["iface"] != iface]


@route("POST", r"/storage")
def add_storage(p, u):
    sid = p.get("storage", "")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9\-_.]+", sid):
        raise ApiError(400, "Parameter verification failed.", {"storage": "invalid format - storage ID"})
    if sid in STORAGES:
        raise ApiError(500, f"storage ID '{sid}' already defined")
    STORAGES[sid] = {**p, "shared": int(p.get("shared", 1 if p.get("type") in ("nfs", "cifs", "pbs") else 0)), "total": 2000 * GiB}


@route("DELETE", r"/storage/(?P<sid>[^/]+)")
def delete_storage(p, u, sid):
    STORAGES.pop(sid, None)


@route("POST", r"/nodes/(?P<node>[^/]+)/qemu/(?P<vmid>\d+)/monitor")
def monitor(p, u, node, vmid):
    g = require_guest(vmid, "qemu")
    if g["status"] == "stopped":
        raise ApiError(500, f"VM {vmid} not running")
    cmd = p.get("command", "").strip()
    replies = {"info status": f"VM status: {'paused' if g['status'] == 'paused' else 'running'}",
               "info version": "9.2.0pve1",
               "info block": f"drive-scsi0 (#block112): /dev/pve/vm-{vmid}-disk-0 (raw)\n    Attached to:      scsi0\n    Cache mode:       writeback, direct",
               "help": "info [subcommand] -- show various information about the system state\nsystem_reset -- reset the system\nsendkey keys [hold_ms] -- send keys to the VM"}
    return replies.get(cmd, f"unknown command: '{cmd.split(' ')[0]}'")


@route("POST", r"/nodes/(?P<node>[^/]+)/(?P<kind>qemu|lxc)/(?P<vmid>\d+)/(?P<what>move_disk|move_volume)")
def move_disk(p, u, node, kind, vmid, what):
    g = require_guest(vmid, kind)
    key = p.get("disk") or p.get("volume")
    target = p.get("storage")
    if key not in g["config"] or target not in STORAGES:
        raise ApiError(400, "Parameter verification failed.", {"storage": f"storage '{target}' does not exist"})
    def done():
        g["config"][key] = re.sub(r"^[^:]+:", f"{target}:", g["config"][key])
    return new_task(node, "qmmove" if kind == "qemu" else "move_volume", vmid, u, 3.0, done)["upid"]


@route("POST", r"/nodes/(?P<node>[^/]+)/migrateall")
def migrate_all(p, u, node):
    allow_only(p, "max-workers", "maxworkers", "target", "vms", "with-local-disks")
    require(p, "target")
    target = p.get("target")
    online_node(target)
    guests = [g for g in bulk_targets(node, p)]
    def done():
        for g in guests:
            g["node"] = target
    return new_task(node, "migrateall", "", u, 4.0, done)["upid"]


# ---------------------------------------------------------------- HTTP plumbing

def form(text):
    """Repeated keys (array parameters) are joined with NUL, as PVE's HTTP server does."""
    out = {}
    for key, value in urllib.parse.parse_qsl(text, keep_blank_values=True):
        out[key] = out[key] + "\0" + value if key in out else value
    return out


def update_config(item, p, lists=()):
    """Apply a PUT: set the given keys, drop the ones named in `delete`."""
    for key, value in p.items():
        if key not in ("delete", "digest"):
            item[key] = list(filter(None, value.split("\0"))) if key in lists else value
    for key in filter(None, p.get("delete", "").split(",")):
        item.pop(key, None)


def parse_multipart(raw, ctype):
    msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
        f"Content-Type: {ctype}\r\nMIME-Version: 1.0\r\n\r\n".encode() + raw)
    out = {}
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition")
        data = part.get_payload(decode=True) or b""
        if part.get_filename():
            out[name] = {"filename": part.get_filename(), "data": data}
        else:
            out[name] = data.decode(errors="replace")
    return out


CONSOLE_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>{title}</title>
<style>html,body{{margin:0;height:100%;background:#0c0c0c;color:#d7d7d7;font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace}}
#t{{padding:14px 16px;white-space:pre-wrap}} .p{{color:#7ee787}} .c{{display:inline-block;width:8px;height:15px;background:#d7d7d7;vertical-align:-3px;animation:b 1s steps(1) infinite}}
@keyframes b{{50%{{opacity:0}}}}</style></head><body><div id="t"></div>
<script>
// Echoes what's typed, so typing into a console can be checked by hand against the mock.
const t = document.getElementById("t"), prompt = {prompt};
// The live connection, like Proxmox's vncwebsocket: the mock logs when it opens and when the page lets it go.
const socket = new WebSocket("wss://" + location.host + "/mock-console-ws" + location.search);
let shown = {banner}, line = "";
function draw() {{
  t.textContent = shown;
  const p = document.createElement("span"); p.className = "p"; p.textContent = prompt;
  const c = document.createElement("span"); c.className = "c";
  t.append(p, " " + line, c);
}}
document.addEventListener("keydown", e => {{
  if (e.metaKey) return;
  if (e.key === "Enter") {{ shown += prompt + " " + line + "\\n" + (line.trim() ? line.trim() + ": received by the mock console\\n" : ""); line = ""; }}
  else if (e.key === "Backspace") line = line.slice(0, -1);
  else if (e.key.length === 1 && !e.ctrlKey) line += e.key;
  else return;
  e.preventDefault(); draw();
}});
draw();
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "pve-api-daemon/3.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if os.environ.get("MOCK_PVE_VERBOSE"):
            sys.stderr.write("%s %s\n" % (self.command, self.path))

    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def do_PUT(self):
        self.dispatch("PUT")

    def do_DELETE(self):
        self.dispatch("DELETE")

    def send_raw(self, status, ctype, body, reason=None):
        self.send_response(status, reason)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "max-age=0")
        self.end_headers()
        self.wfile.write(body)

    def cookie_user(self):
        cookies = self.headers.get("Cookie", "")
        m = re.search(r"PVEAuthCookie=([^;]+)", cookies)
        if not m:
            return None, None
        tick = urllib.parse.unquote(m.group(1))
        info = TICKETS.get(tick)
        if not info or info[0].startswith("!tfa!") or time.time() - info[2] > 7200:
            return None, None
        return info[0], info[1]

    def token_user(self):
        auth = self.headers.get("Authorization", "")
        m = re.fullmatch(r"PVEAPIToken=([^!]+)!([^=]+)=(.+)", auth.strip())
        if not m:
            return None
        full, secret = f"{m.group(1)}!{m.group(2)}", m.group(3)
        if any(t["tokenid"] == full and t["secret"] == secret for t in SEED["tokens"]):
            return full
        return None

    def dispatch(self, method):
        url = urllib.parse.urlsplit(self.path)
        query = form(url.query)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        ctype = self.headers.get("Content-Type", "")
        body = {}
        if ctype.startswith("application/x-www-form-urlencoded"):
            body = form(raw.decode())
        elif ctype.startswith("application/json") and raw:
            body = {k: (str(v) if not isinstance(v, str) else v) for k, v in json.loads(raw).items()}
        elif ctype.startswith("multipart/form-data"):
            body = parse_multipart(raw, ctype)
        params = {**query, **body}

        if url.path == "/mock-console-ws":
            key = self.headers.get("Sec-WebSocket-Key", "")
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            self.wfile.flush()
            what = f"{query.get('console', '?')} {query.get('vmid') or query.get('node', '')}"
            print(f"console socket opened: {what}", flush=True)
            try:
                # Read frames until the client closes: a close frame (opcode 8) or the connection dropping.
                while (head := self.rfile.read(2)) and len(head) == 2:
                    size = head[1] & 0x7F
                    if size >= 126:
                        size = int.from_bytes(self.rfile.read(2 if size == 126 else 8), "big")
                    self.rfile.read((4 if head[1] & 0x80 else 0) + size)
                    if head[0] & 0x0F == 8:
                        self.wfile.write(b"\x88\x00")
                        break
            except OSError:
                pass
            print(f"console socket closed: {what}", flush=True)
            self.close_connection = True
            return

        if url.path == "/" and "console" in query:
            user, _ = self.cookie_user()
            if not user:
                return self.send_raw(401, "text/html", b"<h1>401 No ticket</h1>", "No ticket")
            node = query.get("node", "pve")
            target = query.get("vmname") or (f"VM {query['vmid']}" if query.get("vmid") else node)
            kind = query["console"]
            banner = {"kvm": f"noVNC (mock) connected to {target}\n\nDebian GNU/Linux 13 {target} tty1\n",
                      "lxc": f"Connected to CT {query.get('vmid')} ({target})\n\nDebian GNU/Linux 13 {target} console\n",
                      "shell": f"Linux {node} 6.14.11-2-pve #1 SMP PREEMPT_DYNAMIC PMX 6.14.11-2 x86_64\n\nThe programs included with the Debian GNU/Linux system are free software.\nLast login: {time.strftime('%a %b %d %H:%M:%S %Y')} from 192.168.1.50 on pts/0\n",
                      "upgrade": f"Starting system upgrade: apt-get dist-upgrade\nReading package lists... Done\nBuilding dependency tree... Done\n7 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n",
                      "cmd": f"pveceph install {' '.join(query.get('cmd-opts', '').split(chr(0)))}\nupdating /etc/apt/sources.list.d/ceph.sources\nReading package lists... Done\nSetting up ceph-mon ... Done\n\ninstalled Ceph successfully!\n"}.get(kind, "")
            if kind == "cmd" and query.get("cmd") == "ceph_install" and CEPH["state"] == "missing":
                CEPH["state"] = "installed"
            prompt = f"root@{target}:~#" if kind != "upgrade" else "Do you want to continue? [Y/n]"
            page = CONSOLE_PAGE.format(title=html.escape(f"{target} - Proxmox Console"), banner=json.dumps(banner + "\n"), prompt=json.dumps(prompt))
            return self.send_raw(200, "text/html; charset=utf-8", page.encode())

        if url.path == "/mock-idp/authorize":
            # A stand-in OpenID provider: one button that sends the browser back to Proxmox with a code.
            state = query.get("state", "")
            if state not in OPENID_STATES:
                return self.send_raw(400, "text/html", b"<h1>unknown state</h1>", "Bad Request")
            realm, redirect, _ = OPENID_STATES[state]
            code = secrets.token_hex(8)
            OPENID_STATES[state] = (realm, redirect, code)
            back = f"{redirect}/?code={code}&state={urllib.parse.quote(state)}"
            denied = f"{redirect}/?error=access_denied&error_description={urllib.parse.quote('The user cancelled the sign-in.')}&state={urllib.parse.quote(state)}"
            page = f"""<!doctype html><html><head><meta charset="utf-8"><title>Mock IdP</title><style>body{{font:15px -apple-system;margin:48px;color:#222}}
a{{display:inline-block;margin:8px 8px 0 0;padding:10px 16px;border-radius:8px;background:#fd4b2d;color:#fff;text-decoration:none}} a.no{{background:#888}}</style></head>
<body><h2>authentik (mock)</h2><p>Sign in to <b>{html.escape(realm)}</b> for Proxmox VE.</p><a id="yes" href="{html.escape(back)}">Sign in as alice</a><a class="no" href="{html.escape(denied)}">Cancel</a></body></html>"""
            return self.send_raw(200, "text/html; charset=utf-8", page.encode())

        m = re.match(r"^/api2/(json|extjs)(/.*?)/?$", url.path)
        if not m:
            return self.send_raw(404, "text/plain", b"not found", "Not Found")
        fmt, api = m.groups()
        open_paths = {("POST", "/access/ticket"), ("GET", "/access/domains"), ("POST", "/access/openid/auth-url"), ("POST", "/access/openid/login")}
        user = None
        if (method, api) not in open_paths:
            user, csrf = self.cookie_user()
            if user:
                if method != "GET" and self.headers.get("CSRFPreventionToken") != csrf:
                    return self.send_raw(401, "text/plain", b"Permission denied - invalid csrf token", "Permission denied - invalid csrf token")
            else:
                user = self.token_user()
            if not user:
                time.sleep(0.2)
                return self.send_raw(401, "application/json", json.dumps({"data": None}).encode(), "No ticket")
        for rmethod, regex, fn in ROUTES:
            if not re.fullmatch(rmethod, method):
                continue
            mm = regex.match(api)
            if not mm:
                continue
            try:
                with LOCK:
                    result = fn(params, user, **mm.groupdict())
                extra = {}
                if isinstance(result, RawFile):
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(len(result.data)))
                    self.send_header("Content-Disposition", f'attachment; filename="{result.name}"')
                    self.end_headers()
                    self.wfile.write(result.data)
                    return
                if isinstance(result, tuple):
                    result, extra = result
                return self.respond(fmt, 200, result, extra=extra)
            except ApiError as e:
                return self.respond(fmt, e.status, None, message=e.message, errors=e.errors)
            except Exception as e:  # keep the mock alive and visible
                import traceback
                traceback.print_exc()
                return self.respond(fmt, 500, None, message=f"mock error: {e}")
        return self.respond(fmt, 501, None, message=f"Method '{method} {api}' not implemented")

    def respond(self, fmt, status, data, message=None, errors=None, extra=None):
        if fmt == "extjs":
            body = {"data": data, "success": 1 if status == 200 else 0}
            if status != 200:
                body["message"] = (message or "") + "\n"
                body["status"] = status
            if errors:
                body["errors"] = errors
            body.update(extra or {})
            return self.send_raw(200, "application/json;charset=UTF-8", json.dumps(body).encode())
        body = {"data": data}
        if errors:
            body["errors"] = errors
        body.update(extra or {})
        return self.send_raw(status, "application/json;charset=UTF-8", json.dumps(body).encode(), message)


def main():
    global FINGERPRINT
    cert, key, FINGERPRINT = ensure_cert()
    build_state()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print(f"mock PVE ({PROFILE}) on https://127.0.0.1:{PORT}  SHA-256 {FINGERPRINT}", flush=True)
    srv.serve_forever()


FINGERPRINT = ""

if __name__ == "__main__":
    main()
