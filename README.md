# Proxima

A native macOS 26 app for managing Proxmox VE, written in SwiftUI with Liquid Glass.

## Run it

1. Open `Proxima.xcodeproj` in Xcode 26.
2. Press ⌘R.

From the terminal:

```
xcodebuild -project Proxima.xcodeproj -scheme Proxima -configuration Release -derivedDataPath .build build
open .build/Build/Products/Release/Proxima.app
```

Run the unit tests with ⌘U in Xcode, or `xcodebuild test -project Proxima.xcodeproj -scheme Proxima -destination 'platform=macOS'`.

## Connect to your server

1. Choose **Add Server**.
2. Enter the address (for example `192.168.100.50`). You can also paste the web UI URL; the port is detected.
3. Enter the user, realm and password, or switch to **API Token**.
   - For an OpenID Connect realm (Authentik, Keycloak…), choose the realm and **Continue**: the provider's sign-in page opens in a sheet, and Proxima catches the return to the server. The provider needs the server's address (for example `https://192.168.100.50:8006`) as a redirect URI, as for the web interface.
   - With two-factor on, Proxima asks for a code from your authenticator app, a YubiKey OTP or a recovery key.
   - Accounts that only have a security key (WebAuthn) sign in through the web interface instead. macOS only lets web browsers use security keys with a self-hosted server, so Proxima explains this and offers to open it.
4. On first connect, Proxima shows the server's certificate fingerprint.
   - Compare it with `pve-ssl.pem` in the web UI under *Node → System → Certificates*, then choose **Trust and Connect**.
   - From then on Proxima accepts only that exact certificate, or one macOS already trusts.

**Use a dedicated account.** Prefer a separate user with the role it needs, or an API token, over root. API tokens do everything except open consoles; Proxmox only allows those for password sessions.

**Two macOS prompts can appear:**

- **Local Network access**, on the first connection to a server on your LAN. Allow it. If it was denied, Proxima says so and opens *System Settings → Privacy & Security → Local Network* for you.
- **Keychain access**, after you rebuild the app. The app is signed locally, so macOS treats each build as new. Choose **Always Allow**, or set your team under *Signing & Capabilities* to stop the prompt.

## What it covers

### Datacenter

- **Overview:** live dashboard with cluster health, CPU, memory and storage, a node "rack" with one light per guest, the busiest guests, recent tasks and storage use.
- **Guests:** a sortable table of every guest with filters; bulk start, shut down, reboot and stop for the selection; and bulk start, shut down, suspend and migrate across the cluster, with a guest picker, timeout, forced stop, target node and parallel jobs.
- **Backups:** jobs (create, edit, enable or disable, run now, see which guests and disks each covers) plus a warning for guests no job covers, and a schedule simulator. Schedule fields offer the web UI's examples.
- **Replication:** jobs (create, run now, enable or disable, delete) with last and next sync.
- **Storage:** add Directory, LVM, LVM-Thin, ZFS, NFS, SMB/CIFS, Proxmox Backup Server, iSCSI or ESXi (to import from) storage, with a Scan button that lists an NFS server's exports, an SMB server's shares, a backup server's datastores, an iSCSI portal's targets or a node's volume groups, thin pools and ZFS pools; edit it, enable or disable it, remove it.
- **Permissions:**
  - access control (ACLs)
  - users (create, edit with expiry date, change password, unlock two-factor, show effective permissions, delete)
  - API tokens (create with expiry date, edit, regenerate the secret, show effective permissions, delete; secrets are shown once)
  - two-factor: add an authenticator app (TOTP, with a QR code), a YubiKey OTP or recovery keys, for yourself or (as root) any user, and enable, disable or remove any entry. Proxmox asks for your password unless you're root@pam.
  - groups, pools, custom roles
  - realms (LDAP, Active Directory, OpenID Connect: add, edit; sync now with options and a preview; scheduled sync jobs)
- **High Availability:** status, arming and disarming (freeze or ignore, PVE 9), resources (add, edit, migrate, remove), and node or resource affinity rules (PVE 9) or groups (PVE 8): add, edit, enable or disable, delete.
- **Firewall:** rules (add, edit, toggle, reorder, delete; in, out and forward rules where Proxmox allows them; the server's macros and pickers for aliases and IP sets), security groups, aliases and IP sets (also per guest), and the options for each level: policies, ebtables and the log rate limit for the datacenter; NDP, SMURF and TCP-flag filtering, connection tracking (limits, timeouts, protocol helpers), nftables and log levels for nodes; DHCP, NDP, router advertisements, MAC and IP filters and log levels for guests.
- **SDN:** add and edit zones (Simple, VLAN, QinQ, VXLAN, EVPN), VNets, subnets (with DHCP ranges), fabrics (OpenFabric, OSPF) with their member nodes and links, controllers (EVPN, BGP, IS-IS, with route maps), IPAM (NetBox, phpIPAM) and DNS (PowerDNS); each VNet's firewall; the built-in IPAM's addresses with IP mappings to add, change or remove; BGP prefix lists and route maps; a preview of what Apply would change on a node, then Apply.
- **Options:**
  - notes (Markdown) and cluster options
  - cluster: members, create a cluster, join one (paste the join information), copy join information
  - metric servers (InfluxDB, Graphite)
  - notifications: sendmail, SMTP, Gotify and webhook targets and matchers (add, edit, enable or disable, delete), a test send
  - ACME: register accounts with any CA (the server's list or a directory URL, its terms, External Account Binding when the CA needs it) or deactivate them, DNS challenge plugins
  - resource mappings: PCI and USB devices picked from each node's hardware list, and directories for virtiofs; add, edit, delete
  - custom CPU models (PVE 9), offered with the server's own CPU types wherever a VM's CPU is chosen
  - subscriptions
- **Tasks:** the cluster task log, a live log viewer and stopping a running task.

### Nodes

- **Summary:** status, live charts, notes and the versions of Proxmox's packages (to copy into a forum post).
- **Shell:** in the page, in its own window, or over SPICE in Remote Viewer.
- **System:** DNS, hosts file, time zone, certificates (upload, remove, set the ACME domain, order with ACME), subscription key, wake-on-LAN, system report.
- **Network:** create a bridge, bond or VLAN; edit, delete, apply or revert.
- **SDN:** each zone's state on the node with its VNets and the guests on them; EVPN routes and MAC tables; fabric interfaces, neighbors and routes.
- **Disks:** S.M.A.R.T., initialize with GPT, wipe, and LVM, LVM-Thin, directory and ZFS: create, destroy (optionally removing the storage and wiping the disks), ZFS pool details.
- **Services:** start, stop, restart, reload.
- **Updates:** refresh, upgrade in a console, changelogs, repositories.
- **Ceph:**
  - install it (the installer runs in a console window), then configure the network and replicas
  - health, usage, global flags, ceph.conf, the configuration database, the CRUSH map and the log
  - monitors, managers and metadata servers: create, start, stop, restart, destroy
  - OSDs: create (with DB/WAL disks and encryption), mark in or out, start, stop, scrub, destroy
  - pools (create with CRUSH rule and autoscaling, edit, delete) and CephFS
  - mute and unmute health warnings; rolling restarts of monitors, managers, metadata servers or OSDs; Ceph's own safety check before stopping or destroying a daemon
- **Also:** live system log, firewall and log, task history, permissions, bulk start, shut down, suspend or migrate of the node's guests, reboot, shut down.

### Virtual machines and containers

- **Summary:** live status, IP addresses from the guest agent, Markdown notes and charts.
- **Console:** noVNC for VMs, xterm.js for containers; embedded or in its own window. SPICE opens in Remote Viewer if it's installed.
- **VM hardware:** every device, with editors for:
  - memory and ballooning, processors with CPU flags, BIOS, display (with video memory and VNC clipboard), machine (with a pinned version and vIOMMU) and SCSI controller. Editing keeps the settings an editor doesn't show, such as CPU flags set in the web interface.
  - disks: add, change options, resize, move storage, detach, delete
  - CD/DVD media and network devices
  - EFI disk, TPM, and USB or PCI passthrough picked from the node's devices or a mapping, with mediated device types (vGPU) for GPUs that offer them
  - shared folders (virtiofs) from a directory mapping
  - serial, audio, VirtIO RNG and CloudInit drives
  - raw values for anything else
  - pending changes are flagged and can be reverted
- **Cloud-Init:** user, password, SSH keys, DNS, IP configuration, custom files, regenerate the image.
- **Containers:** resources (memory, swap, CPU, root disk and mount points with resize and move, device passthrough such as `/dev/dri`), network interfaces and DNS.
- **Options:** name, tags, start at boot and order, OS type, boot order (drag to reorder), hotplug, ACPI, KVM, RTC, SMBIOS, guest agent, protection, container features, hookscript.
- **Monitor:** the QEMU monitor of a running VM.
- **Snapshots:** a timeline with take, roll back, edit and delete.
- **Backups:** back up now (starting from the node's backup defaults), restore, notes, protection, view the stored configuration, prune by retention rules with a preview, delete.
- **Also:** replication, tasks, firewall and permissions per guest.
- **Power and lifecycle:** start, shut down, reboot, stop, reset, pause, resume, clone (full or linked, to any node), migrate (Proxmox's checks first: only nodes that can take the guest, local disks and devices; live, with local disks, keeping network connections), convert to template, destroy (type the ID to confirm).
- **Create:** stepped wizards for new VMs and containers.

### Storage

- Usage over time.
- Each content type gets its own tab:
  - **Backups:** restore to a new or existing guest; on Proxmox Backup Server, browse a backup and download single files or folders.
  - **ISO images:** upload from the Mac with progress (Proxima sends the file's SHA-256 so Proxmox rejects a damaged transfer), or download straight to the server from a URL.
  - **Container templates:** the same, plus the Proxmox template catalog and pulling OCI images (Docker Hub or any registry, with its tags listed) for application containers.
  - **Disk images:** list, with orphaned images marked.
  - **Import:** upload OVA/OVF appliances; import them, or a guest on an ESXi host, as a new VM, with a storage per disk and VirtIO SCSI preparation for Windows.
  - **Snippets:** list. Proxmox doesn't accept snippet uploads over its API; copy them to the node over SSH.
- Permissions.

### Mac extras

- A menu bar panel with cluster load and one-click start or shut down for every guest.
- **Guest** and **Node** menus in the menu bar with every action for what's selected in the sidebar: power, console, SPICE, clone, migrate, back up, snapshot, destroy; shell, start or stop all guests, reboot, shut down.
- Files restored from a backup open the standard Save panel.
- Keyboard shortcuts:
  - ⌘R refresh
  - ⌘N new VM, ⇧⌘N new container
  - ⌘1–3 Overview, Guests, Tasks
- Search the sidebar by name, ID, tag or node.
- Group the sidebar by node, type, tag or pool.

### Web interface only

- Security keys (WebAuthn and U2F): signing in with one, and adding one. macOS only lets web browsers use security keys with a self-hosted server, so Proxima opens the web interface for these. Keys added there can be listed, disabled and removed in Proxima.

## Fake server for development

`MockPVE/mock_pve.py` imitates the Proxmox API on `https://127.0.0.1:8006`, with a self-signed certificate, tickets, CSRF, API tokens, TOTP and an OpenID realm (`authentik`, with a stand-in provider page). It keeps state: guests, tasks, snapshots, backups, users and firewall rules all change as you use the app. Test logins are created in `MockPVE/seed-users.json` on first run.

```
python3 MockPVE/mock_pve.py                          # a two-node homelab with Ceph
MOCK_PVE_PROFILE=stress python3 MockPVE/mock_pve.py  # 140 guests, long names, an offline node, Ceph not installed
MOCK_PVE_STANDALONE=1 python3 MockPVE/mock_pve.py    # not in a cluster yet, to try create and join
```

Debug builds also read these variables, meant only for testing against the mock. Release builds leave them out.

- `PROXIMA_DEBUG_SECRET` signs in to `127.0.0.1` without typing.
- `PROXIMA_DEBUG_PLACE` opens a page, for example `guest:100`, `node:pve1` or `options`.
- `PROXIMA_DEBUG_TAB` opens a tab on that page, for example `hardware` or `notifications`.
- `PROXIMA_DEBUG_SHEET` opens a guest sheet, for example `createVM`, `clone:9000` or `migrate:100`, or a bulk action: `bulk:start`, `bulk:shutdown:pve1`.
- `PROXIMA_DEBUG_ACTION` opens a form, for example `add-pci`, `edit-processors`, `edit-machine`, `add-ha-rule`, `join-cluster`, `create-osd`, `restore-files`, `restore-download` (also starts downloading the first entry, which opens the Save panel), `edit-tfa`, `import-guest`, `pull-oci`, `add-nfs`, `add-lvmthin`, `schedule-simulator`, `register-acme`, `edit-zone`, `sdn-firewall`, `sdn-ipam` or `sdn-review`.
- `PROXIMA_DEBUG_STEP` opens a create wizard on that step (with `PROXIMA_DEBUG_SHEET=createVM` or `createCT`).
- `PROXIMA_DEBUG_APPEARANCE` set to `light` or `dark` overrides the system appearance for the app.
- `PROXIMA_DEBUG_CONSOLE_DUMP` set to a folder saves what an embedded console renders, as PNG and text (WebKit doesn't draw while the screen is locked).
- `PROXIMA_DEBUG_NAV` set to a file moves the running app whenever the file changes. The file holds `<place> [tab]`, as for `PROXIMA_DEBUG_PLACE`, or `appearance light|dark`.
- `PROXIMA_DEBUG_TFA` set to methods (for example `webauthn` or `totp,recovery`) opens the second-factor step of sign-in, when no server is saved yet. `PROXIMA_DEBUG_ADDRESS` fills in the address.

## Check a real server

`Tools/livecheck.sh` builds Proxima's own networking code into a small command-line check and runs it against a server, without signing in. It doesn't need the app's Local Network permission.

```
Tools/livecheck.sh 192.168.100.50
```

It checks that the self-signed certificate is caught and matches OpenSSL's fingerprint, that pinning it lets requests through (and a wrong pin doesn't), that realms load, that the server answers 401 to requests and file downloads without a session, and that error messages decode.

`Tools/apicheck.sh` checks every API call Proxima makes against that server's own API schema (the file behind the web UI's API viewer, which needs no sign-in): that each path exists, takes that method, and accepts the parameter names sent, and that edit forms don't send `delete` where the server has none.

```
Tools/apicheck.sh 192.168.100.50
```

The same checks run as tests inside the app once Proxima is allowed in *Local Network* settings:

```
TEST_RUNNER_PROXIMA_LIVE_HOST=192.168.100.50 xcodebuild test -project Proxima.xcodeproj -scheme Proxima -only-testing:ProximaTests/LiveServer
```
