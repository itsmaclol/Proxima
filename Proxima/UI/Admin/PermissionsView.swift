import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Datacenter → Permissions.
struct PermissionsView: View {
    @State private var section = "acl"

    var body: some View {
        AdminPage(title: "Permissions", subtitle: "Who can do what, and how they sign in", symbol: "person.2", colors: [.blue, .purple]) {
            EmptyView()
        } content: {
            TabStrip(tabs: [PageTab(id: "acl", title: "Access", symbol: "key"),
                            PageTab(id: "users", title: "Users", symbol: "person"),
                            PageTab(id: "tokens", title: "API Tokens", symbol: "key.horizontal"),
                            PageTab(id: "tfa", title: "Two-Factor", symbol: "lock.shield"),
                            PageTab(id: "groups", title: "Groups", symbol: "person.3"),
                            PageTab(id: "pools", title: "Pools", symbol: "tray.2"),
                            PageTab(id: "roles", title: "Roles", symbol: "theatermasks"),
                            PageTab(id: "realms", title: "Realms", symbol: "building.columns")], selection: $section)
                .padding(.bottom, 6)
            switch section {
            case "users": UsersList()
            case "tokens": TokensList()
            case "tfa": TwoFactorList()
            case "groups": GroupsList()
            case "pools": PoolsList()
            case "roles": RolesList()
            case "realms": RealmsList()
            default: PermissionsList(path: nil)
            }
        }
    }
}

// MARK: Access control

/// ACL entries — all of them, or just one path (a guest, node, storage or pool).
struct PermissionsList: View {
    @Environment(Session.self) private var session
    let path: String?
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add Permission", systemImage: "plus") { adding = true }
                Spacer()
                if path != nil { Text("Permissions set on parent paths with propagation also apply here.").font(.callout).foregroundStyle(.secondary) }
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            ResourceList(path: "/access/acl", id: { "\($0.string("path") ?? "")|\($0.string("type") ?? "")|\($0.string("ugid") ?? "")|\($0.string("roleid") ?? "")" },
                         columns: [APIColumn("Path", key: "path", width: 180, monospaced: true),
                                   APIColumn("Type", width: 70) { $0.string("type")?.capitalized ?? "" },
                                   APIColumn("User, group or token", key: "ugid", width: 220),
                                   APIColumn("Role", key: "roleid", width: 160),
                                   APIColumn("Propagate", width: 80) { $0.bool("propagate") ? "Yes" : "No" }],
                         emptyTitle: "No permissions here", emptySymbol: "key",
                         emptyMessage: path == nil ? nil : "Nobody has a role on this path directly.",
                         transform: { list in path.map { p in list.filter { $0.string("path") == p } } ?? list }) { _ in } delete: { row in
                Deletion(title: "Remove…") { remove(row) }
            }
        }
        .sheet(isPresented: $adding) { AddPermissionSheet(path: path) }
    }

    private func remove(_ row: Row) {
        let kind = row["type"] ?? "user"
        let key = kind == "group" ? "groups" : (kind == "token" ? "tokens" : "users")
        session.confirmation = Confirmation(title: "Remove \(row["roleid"] ?? "") for \(row["ugid"] ?? "")?",
                                            message: "On \(row["path"] ?? "").", actionTitle: "Remove", destructive: true) {
            await session.run("Remove the permission", .put, "/access/acl",
                              ["path": row["path"] ?? "", "roles": row["roleid"] ?? "", key: row["ugid"] ?? "", "delete": "1"])
        }
    }
}

private struct AddPermissionSheet: View {
    @Environment(Session.self) private var session
    let path: String?

    var body: some View {
        Prepared(load: {
            let userList = (try? await session.client.list("/access/users", ["full": "1"])) ?? []
            let groupList = (try? await session.client.list("/access/groups")) ?? []
            let roleList = (try? await session.client.list("/access/roles")) ?? []
            let tokens = userList.flatMap { user in user.objects("tokens").compactMap { token in token.text("tokenid").map { "\(user.string("userid") ?? "")!\($0)" } } }
            return (userList.compactMap { $0.text("userid") }, groupList.compactMap { $0.text("groupid") },
                    tokens, roleList.compactMap { $0.text("roleid") }.sorted())
        }) { loaded in
            let (users, groups, tokens, roles) = loaded
            FormSheet(title: "Add permission", fields: [
                FormField(key: "path", label: "Path", prompt: "/, /vms/100, /storage/local, /pool/lab", required: true, lockedOnEdit: true),
                FormField(key: "kind", label: "Grant to", kind: .choice([.init("users", "User"), .init("groups", "Group"), .init("tokens", "API token")]), required: true),
                FormField(key: "ugid", label: "Who", kind: .choice((users.map { FormField.Choice($0, "User \($0)") }
                                                                     + groups.map { FormField.Choice($0, "Group \($0)") }
                                                                     + tokens.map { FormField.Choice($0, "Token \($0)") })), required: true),
                FormField(key: "roles", label: "Role", kind: .choice(roles.map { FormField.Choice($0) }), required: true),
                FormField(key: "propagate", label: "Propagate to child paths", kind: .toggle),
            ], initial: ["path": path ?? "/", "kind": "users", "propagate": "1", "roles": "PVEVMUser"], submitTitle: "Add") { result in
                var params = ["path": result["path"], "roles": result["roles"], "propagate": result["propagate"] == "1" ? "1" : "0"]
                params[result["kind"]] = result["ugid"]
                return await session.run("Add the permission", .put, "/access/acl", params)
            }
        }
    }
}

// MARK: Users

private struct UsersList: View {
    @Environment(Session.self) private var session
    @State private var editing: Row??
    @State private var password: Row?
    @State private var permissionsOf: Row?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add User", systemImage: "plus") { editing = .some(nil) }
                Spacer()
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            ResourceList(path: "/access/users", query: ["full": "1"], id: { $0.string("userid") ?? "" },
                         columns: [APIColumn("User", key: "userid", width: 180),
                                   APIColumn("Name", width: 160) { "\($0.string("firstname") ?? "") \($0.string("lastname") ?? "")".trimmingCharacters(in: .whitespaces) },
                                   APIColumn("Email", key: "email", width: 180),
                                   APIColumn("Enabled", width: 70) { $0["enable"] == nil || $0.bool("enable") ? "Yes" : "No" },
                                   APIColumn("Expires", width: 110) { ($0.int("expire") ?? 0) > 0 ? Date(timeIntervalSince1970: Double($0.int("expire")!)).formatted(date: .abbreviated, time: .omitted) : "Never" },
                                   APIColumn("Groups", width: 140) { $0.strings("groups").joined(separator: ", ") },
                                   APIColumn("Comment", key: "comment", width: 220)],
                         emptyTitle: "No users", emptySymbol: "person", open: { editing = .some($0) }) { row in
                Button("Edit…") { editing = .some(row) }
                Button("Change Password…") { password = row }
                Button("Unlock Two-Factor") { Task { await session.run("Unlock two-factor for \(row.id)", .put, "/access/users/\(row.id.enc)/unlock-tfa") } }
                Button("Show Permissions") { permissionsOf = row }
            } delete: { row in
                row.id == "root@pam" ? nil : Deletion { session.confirmDelete("Delete user \(row.id)?", message: "Their API tokens and permissions are removed too.", path: "/access/users/\(row.id.enc)") }
            }
        }
        .sheet(item: Binding(get: { editing.map { Edit(row: $0) } }, set: { editing = $0.map(\.row) })) { edit in
            UserEditor(row: edit.row)
        }
        .sheet(item: $permissionsOf) { EffectivePermissionsSheet(userid: $0.id) }
        .debugAction("user-permissions") { permissionsOf = Row(id: "automation@pve", json: [:]) }
        .sheet(item: $password) { row in
            FormSheet(title: "Change password for \(row.id)", message: "Only for Proxmox VE (pve) realm users; Linux PAM passwords change on the host.", fields: [
                FormField(key: "password", label: "New password", kind: .secure, required: true),
                FormField(key: "confirm", label: "Repeat password", kind: .secure, required: true),
                FormField(key: "confirmation-password", label: "Your current password", kind: .secure, help: "Proxmox asks for it when changing another user's password"),
            ], submitTitle: "Change") { result in
                guard result["password"] == result["confirm"] else {
                    session.alert = AlertItem(title: "The passwords don't match", message: "Type the same new password twice.")
                    return false
                }
                var params = ["userid": row.id, "password": result["password"]]
                if !result["confirmation-password"].isEmpty { params["confirmation-password"] = result["confirmation-password"] }
                return await session.run("Change the password", .put, "/access/password", params)
            }
        }
    }

    private struct Edit: Identifiable {
        let row: Row?
        var id: String { row?.id ?? "new" }
    }
}

private struct UserEditor: View {
    @Environment(Session.self) private var session
    let row: Row?

    var body: some View {
        Prepared(load: {
            let realms = (try? await session.client.list("/access/domains")) ?? []
            let groups = (try? await session.client.list("/access/groups")) ?? []
            return (realms.compactMap { $0.text("realm") }, groups.compactMap { $0.text("groupid") })
        }) { loaded in
            let (realms, groups) = loaded
            let json = row?.json ?? [:]
            FormSheet(title: row == nil ? "Add user" : "Edit \(row!.id)", fields: [
                FormField(key: "username", label: "Username", prompt: "alice", required: true, lockedOnEdit: true),
                FormField(key: "realm", label: "Realm", kind: .choice(realms.map { FormField.Choice($0) }), required: true, lockedOnEdit: true),
                FormField(key: "password", label: "Password", kind: .secure, help: "Only for the pve realm", lockedOnEdit: true),
                FormField(key: "firstname", label: "First name"),
                FormField(key: "lastname", label: "Last name"),
                FormField(key: "email", label: "Email"),
                FormField(key: "expire", label: "Expires", kind: .date),
                FormField(key: "groups", label: "Groups", kind: .multiChoice(groups.map { FormField.Choice($0) })),
                FormField(key: "enable", label: "Enabled", kind: .toggle),
                FormField(key: "comment", label: "Comment"),
            ], initial: [
                "username": row.map { String($0.id.split(separator: "@").first ?? "") } ?? "",
                "realm": row.map { String($0.id.split(separator: "@").last ?? "") } ?? (realms.contains("pve") ? "pve" : realms.first ?? ""),
                "firstname": json.string("firstname") ?? "", "lastname": json.string("lastname") ?? "", "email": json.string("email") ?? "",
                "groups": json.strings("groups").joined(separator: ","), "enable": json["enable"] == nil || json.bool("enable") ? "1" : "0",
                "comment": json.string("comment") ?? "", "expire": json.string("expire") ?? "0",
            ], isEdit: row != nil, submitTitle: row == nil ? "Add" : "Save") { result in
                if let row {
                    var params = result.changed
                    params.removeValue(forKey: "username"); params.removeValue(forKey: "realm")
                    // Users have no `delete` parameter: an empty value clears a field, as in the web UI.
                    for key in result.cleared { params[key] = "" }
                    return await session.run("Save \(row.id)", .put, "/access/users/\(row.id.enc)", params)
                }
                var params = result.changed
                params["userid"] = "\(result["username"])@\(result["realm"])"
                params.removeValue(forKey: "username"); params.removeValue(forKey: "realm")
                return await session.run("Add user \(params["userid"] ?? "")", .post, "/access/users", params)
            }
        }
    }
}

// MARK: API tokens

private struct TokensList: View {
    @Environment(Session.self) private var session
    @State private var adding = false
    @State private var created: JSONObject?
    @State private var editing: Row?
    @State private var permissionsOf: Row?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add Token", systemImage: "plus") { adding = true }
                Spacer()
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            ResourceList(path: "/access/users", query: ["full": "1"], id: { $0.string("full") ?? "" },
                         columns: [APIColumn("Token", key: "full", width: 260, monospaced: true),
                                   APIColumn("Comment", key: "comment", width: 240),
                                   APIColumn("Expires", width: 120) { ($0.int("expire") ?? 0) > 0 ? Date(timeIntervalSince1970: Double($0.int("expire")!)).formatted(date: .abbreviated, time: .omitted) : "Never" },
                                   APIColumn("Privilege separation", width: 140) { $0["privsep"] == nil || $0.bool("privsep") ? "Yes" : "No" }],
                         emptyTitle: "No API tokens", emptySymbol: "key.horizontal",
                         emptyMessage: "Tokens let scripts and tools like Terraform use the API without a password.",
                         transform: { users in
                             users.flatMap { user in
                                 user.objects("tokens").map { token in
                                     var token = token
                                     token["full"] = "\(user.string("userid") ?? "")!\(token.string("tokenid") ?? "")"
                                     token["user"] = user.string("userid")
                                     return token
                                 }
                             }
                         }, open: { editing = $0 }) { row in
                Button("Edit…") { editing = row }
                Button("Show Permissions") { permissionsOf = row }
                Button("Regenerate Secret…") { regenerate(row) }
            } delete: { row in
                Deletion {
                    let user = row["user"] ?? "", token = row["tokenid"] ?? ""
                    session.confirmDelete("Delete token \(row.id)?", message: "Anything using it stops working immediately.",
                                          path: "/access/users/\(user.enc)/token/\(token.enc)")
                }
            }
        }
        .sheet(isPresented: $adding) {
            Prepared(load: { ((try? await session.client.list("/access/users")) ?? []).compactMap { $0.text("userid") } }) { users in
                FormSheet(title: "Add API token", fields: [
                    FormField(key: "user", label: "User", kind: .choice(users.map { FormField.Choice($0) }), required: true),
                    FormField(key: "tokenid", label: "Token name", prompt: "terraform", required: true),
                    FormField(key: "comment", label: "Comment"),
                    FormField(key: "privsep", label: "Privilege separation", kind: .toggle, help: "The token needs its own permissions instead of inheriting the user's"),
                    FormField(key: "expire", label: "Expires", kind: .date),
                ], initial: ["user": session.userid.components(separatedBy: "!").first ?? "", "privsep": "1", "expire": "0"], submitTitle: "Create") { result in
                    let response = await session.call("Create the token", .post, "/access/users/\(result["user"].enc)/token/\(result["tokenid"].enc)",
                                                      ["comment": result["comment"], "privsep": result["privsep"] == "1" ? "1" : "0", "expire": result["expire"].isEmpty ? "0" : result["expire"]])
                    guard let data = response, let object = data as? JSONObject else { return false }
                    created = object
                    return true
                }
            }
        }
        .sheet(item: Binding(get: { created.map { Secret(json: $0) } }, set: { if $0 == nil { created = nil } })) { secret in
            SecretSheet(title: secret.json["regenerated"] == nil ? "Token created" : "New secret",
                        message: secret.json["regenerated"] == nil ? "Copy the secret now. Proxmox shows it only once."
                                                                   : "The old secret stopped working. Copy the new one now; Proxmox shows it only once.",
                        rows: [("Token ID", secret.json.string("full-tokenid") ?? ""), ("Secret", secret.json.string("value") ?? "")])
        }
        .sheet(item: $permissionsOf) { EffectivePermissionsSheet(userid: $0.id) }
        .debugAction("edit-token") {
            Task {
                // Visual checks: the first API token.
                for user in (try? await session.client.list("/access/users", ["full": "1"])) ?? [] {
                    if var token = user.objects("tokens").first {
                        token["user"] = user.string("userid")
                        editing = Row(id: "\(user.string("userid") ?? "")!\(token.string("tokenid") ?? "")", json: token)
                        return
                    }
                }
            }
        }
        .sheet(item: $editing) { row in
            FormSheet(title: "Edit \(row.id)", fields: [
                FormField(key: "comment", label: "Comment"),
                FormField(key: "expire", label: "Expires", kind: .date),
                FormField(key: "privsep", label: "Privilege separation", kind: .toggle, help: "The token needs its own permissions instead of inheriting the user's"),
            ], initial: ["comment": row["comment"] ?? "", "expire": row["expire"] ?? "0",
                         "privsep": row.json["privsep"] == nil || row.json.bool("privsep") ? "1" : "0"], isEdit: true) { result in
                await session.run("Save \(row.id)", .put, "/access/users/\((row["user"] ?? "").enc)/token/\((row["tokenid"] ?? "").enc)", result.params)
            }
        }
    }

    /// A new secret for the token; whatever used the old one loses access.
    private func regenerate(_ row: Row) {
        session.confirmation = Confirmation(title: "Regenerate the secret of \(row.id)?",
                                            message: "Scripts and tools using the current secret stop working until you give them the new one.",
                                            actionTitle: "Regenerate", destructive: true) {
            let path = "/access/users/\((row["user"] ?? "").enc)/token/\((row["tokenid"] ?? "").enc)"
            guard let response = await session.call("Regenerate the secret", .put, path, ["regenerate": "1"]), var object = response as? JSONObject else { return }
            object["full-tokenid"] = object["full-tokenid"] ?? row.id
            object["regenerated"] = 1
            created = object
        }
    }

    private struct Secret: Identifiable {
        let json: JSONObject
        var id: String { json.string("full-tokenid") ?? "" }
    }
}

/// What a user or API token may do on each path once groups, roles and propagation are applied, like the web UI's
/// Permissions window. Privileges that don't pass down to child paths are marked.
struct EffectivePermissionsSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let userid: String

    var body: some View {
        Prepared(load: { () -> JSONObject? in try? await session.client.object("/access/permissions", ["userid": userid]) }) { tree in
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Permissions of \(userid)").font(.title2.bold())
                    Text("What it may do on each path after groups, roles and propagation. Privileges in italics apply to that path only.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let tree, !tree.isEmpty {
                    List(tree.keys.sorted(using: KeyPathComparator(\.self, comparator: .localizedStandard)), id: \.self) { path in
                        let privileges = (tree[path] as? JSONObject) ?? [:]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(path).font(.system(.body, design: .monospaced)).fontWeight(.medium)
                            privileges.keys.sorted().reduce(Text("")) { text, name in
                                let entry = Text(name).italic(!jsonBool(privileges[name]))
                                return text == Text("") ? entry : Text("\(text), \(entry)")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                    .listStyle(.inset)
                } else {
                    ContentUnavailableView("No permissions", systemImage: "lock",
                                           description: Text("\(userid) can't do anything yet. Grant it a role under Access."))
                }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
            .controlSize(.large)
            .padding(24)
            .frame(width: 660, height: 540)
        }
    }
}

/// Shows values that can't be retrieved again, with copy buttons.
struct SecretSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "key.fill").font(.title2.bold())
            Text(message).foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.0).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(row.1).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(nil)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(row.1, forType: .string)
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 560)
    }
}

// MARK: Two-factor

private struct TwoFactorList: View {
    @Environment(Session.self) private var session
    @State private var enrolling: Enrollment?
    @State private var recovery: [String]?
    @State private var changing: Change?

    enum Enrollment: String, Identifiable {
        case totp, yubico, recovery
        var id: String { rawValue }
    }

    /// Editing or removing an entry, which anyone but root@pam confirms with their password.
    private struct Change: Identifiable {
        let row: Row
        let remove: Bool
        var id: String { row.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add Authenticator App", systemImage: "qrcode") { enrolling = .totp }
                Button("Add YubiKey OTP", systemImage: "key.horizontal") { enrolling = .yubico }
                Button("Add Recovery Keys", systemImage: "list.number") { enrolling = .recovery }
                Button("Add Security Key", systemImage: "key.viewfinder") { explainSecurityKeys() }
                Spacer()
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            ResourceList(path: "/access/tfa", id: { "\($0.string("userid") ?? "")/\($0.string("id") ?? "")" },
                         columns: [APIColumn("User", key: "userid", width: 180),
                                   APIColumn("Type", width: 110) { row in
                                       ["totp": "TOTP", "recovery": "Recovery keys", "webauthn": "WebAuthn", "yubico": "Yubico OTP", "u2f": "U2F"][row.string("type") ?? ""]
                                           ?? (row.string("type") ?? "").uppercased()
                                   },
                                   APIColumn("Description", key: "description", width: 220),
                                   APIColumn("Created", width: 150) { Format.epoch($0.int("created")).map(Format.dateTime) ?? "" },
                                   APIColumn("Enabled", width: 70) { $0["enable"] == nil || $0.bool("enable") ? "Yes" : "No" }],
                         emptyTitle: "No second factors", emptySymbol: "lock.shield",
                         emptyMessage: "Add an authenticator app so a stolen password alone isn't enough.",
                         transform: { list in
                             list.flatMap { user in
                                 user.objects("entries").map { entry in
                                     var entry = entry
                                     entry["userid"] = user.string("userid")
                                     return entry
                                 }
                             }
                         }, open: { changing = Change(row: $0, remove: false) }) { row in
                let owner = TFAOwner(session: session)
                let enabled = Self.enabled(row)
                Button("Edit…") { changing = Change(row: row, remove: false) }
                Button(enabled ? "Disable" : "Enable") {
                    if owner.needsPassword {
                        changing = Change(row: row, remove: false)
                    } else {
                        Task { await session.run(enabled ? "Disable the second factor" : "Enable the second factor", .put, Self.path(row), ["enable": enabled ? "0" : "1"]) }
                    }
                }
            } delete: { row in
                Deletion(title: "Remove…") {
                    if TFAOwner(session: session).needsPassword {
                        changing = Change(row: row, remove: true)
                    } else {
                        session.confirmDelete("Remove this \(row["type"] ?? "") factor for \(row["userid"] ?? "")?", path: Self.path(row))
                    }
                }
            }
        }
        .debugAction("add-yubico") { enrolling = .yubico }
        .debugAction("edit-tfa") {
            Task {
                let user = try? await session.client.list("/access/tfa").first { !$0.objects("entries").isEmpty }
                if let entry = user?.objects("entries").first {
                    var json = entry
                    json["userid"] = user?.string("userid")
                    changing = Change(row: Row(id: "debug", json: json), remove: false)
                }
            }
        }
        .sheet(item: $changing) { change in
            let owner = TFAOwner(session: session)
            let password = owner.needsPassword ? [FormField(key: "password", label: "Your password", kind: .secure,
                                                            help: "Proxmox asks for it to change two-factor settings", required: true)] : []
            if change.remove {
                FormSheet(title: "Remove this \(change.row["type"] ?? "") factor?", message: "\(change.row["userid"] ?? "") can't use it to sign in afterwards.",
                          fields: password, submitTitle: "Remove", destructive: true) { result in
                    await session.run("Remove the second factor", .delete, Self.path(change.row), ["password": result["password"]])
                }
            } else {
                FormSheet(title: "Edit second factor", fields: [
                    FormField(key: "description", label: "Description"),
                    FormField(key: "enable", label: "Enabled", kind: .toggle),
                ] + password, initial: ["description": change.row["description"] ?? "", "enable": Self.enabled(change.row) ? "1" : "0"], isEdit: true) { result in
                    var params = ["description": result["description"], "enable": result["enable"] == "1" ? "1" : "0"]
                    if owner.needsPassword { params["password"] = result["password"] }
                    return await session.run("Change the second factor", .put, Self.path(change.row), params)
                }
            }
        }
        .sheet(item: $enrolling) { enrollment in
            switch enrollment {
            case .totp: TOTPEnrollSheet()
            case .yubico: YubicoEnrollSheet()
            case .recovery: RecoveryEnrollSheet { recovery = $0 }
            }
        }
        .sheet(item: Binding(get: { recovery.map { Keys(keys: $0) } }, set: { if $0 == nil { recovery = nil } })) { keys in
            SecretSheet(title: "Recovery keys", message: "Each key works once. Store them somewhere safe; they're not shown again.",
                        rows: keys.keys.enumerated().map { ("Key \($0.offset + 1)", $0.element) })
        }
    }

    private static func path(_ row: Row) -> String { "/access/tfa/\((row["userid"] ?? "").enc)/\((row["id"] ?? "").enc)" }
    private static func enabled(_ row: Row) -> Bool { row.json["enable"] == nil || row.json.bool("enable") }

    /// Security keys need WebAuthn, which macOS opens to apps only for domains they're linked to; browsers can use it anywhere.
    private func explainSecurityKeys() {
        let url = session.server.baseURL
        session.confirmation = Confirmation(
            title: "Add security keys in the web interface",
            message: "macOS only lets web browsers use security keys with a self-hosted server like this one. Add the key under Datacenter → Permissions → Two Factor → Add → WebAuthn. It shows up here afterwards, where you can remove it.",
            actionTitle: "Open Web Interface", destructive: false) {
                NSWorkspace.shared.open(url)
            }
    }

    private struct Keys: Identifiable {
        let keys: [String]
        var id: String { keys.joined() }
    }
}

/// Who gets the new factor, and the password Proxmox asks for when anyone but root@pam changes two-factor settings.
private struct TFAOwner {
    let session: Session
    var signedIn: String { session.userid.components(separatedBy: "!").first ?? session.userid }
    var needsPassword: Bool { signedIn != "root@pam" }

    func users() async -> [FormField.Choice] {
        let ids = ((try? await session.client.list("/access/users")) ?? []).compactMap { $0.text("userid") }
        return (ids.contains(signedIn) ? ids : [signedIn] + ids).map { FormField.Choice($0) }
    }

    func fields(_ users: [FormField.Choice]) -> [FormField] {
        [FormField(key: "userid", label: "User", kind: .choice(users), required: true)]
            + (needsPassword ? [FormField(key: "password", label: "Your password", kind: .secure, help: "Proxmox asks for it to change two-factor settings", required: true)] : [])
    }
}

private struct YubicoEnrollSheet: View {
    @Environment(Session.self) private var session

    var body: some View {
        let owner = TFAOwner(session: session)
        Prepared(load: { await owner.users() }) { users in
            FormSheet(title: "Add a YubiKey", message: "Click the code field, then touch the key: it types a one-time code. The realm needs Yubico OTP set up in its two-factor settings.",
                      fields: owner.fields(users) + [
                FormField(key: "description", label: "Description", prompt: "YubiKey 5 NFC", required: true),
                FormField(key: "value", label: "One-time code", prompt: "Touch the key", required: true),
            ], initial: ["userid": owner.signedIn], submitTitle: "Add") { result in
                var params = ["type": "yubico", "value": result["value"], "description": result["description"]]
                if owner.needsPassword { params["password"] = result["password"] }
                return await session.run("Add the YubiKey", .post, "/access/tfa/\(result["userid"].enc)", params)
            }
        }
    }
}

private struct RecoveryEnrollSheet: View {
    @Environment(Session.self) private var session
    let created: ([String]) -> Void

    var body: some View {
        let owner = TFAOwner(session: session)
        Prepared(load: { await owner.users() }) { users in
            FormSheet(title: "Create recovery keys", message: "Ten one-time keys for when the usual second factor isn't at hand. Creating new ones replaces any old set.",
                      fields: owner.fields(users), initial: ["userid": owner.signedIn], submitTitle: "Create") { result in
                var params = ["type": "recovery"]
                if owner.needsPassword { params["password"] = result["password"] }
                guard let data = await session.call("Create recovery keys", .post, "/access/tfa/\(result["userid"].enc)", params) else { return false }
                created((data as? JSONObject)?.strings("recovery") ?? [])
                return true
            }
        }
    }
}

/// Generates a TOTP secret, shows it as a QR code, and confirms with a code from the app.
private struct TOTPEnrollSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var secret = TOTPEnrollSheet.randomSecret()
    @State private var code = ""
    @State private var label = "Authenticator on my phone"
    @State private var user = ""
    @State private var users: [FormField.Choice] = []
    @State private var password = ""
    @State private var busy = false

    private var owner: TFAOwner { TFAOwner(session: session) }
    private var uri: String {
        let issuer = "Proxmox VE \(session.clusterName ?? session.server.host)"
        return "otpauth://totp/\(issuer.enc):\(user.enc)?secret=\(secret)&issuer=\(issuer.enc)&algorithm=SHA1&digits=6&period=30"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Add an authenticator app", systemImage: "qrcode").font(.title2.bold())
            HStack(alignment: .top, spacing: 20) {
                if let image = Self.qrImage(uri) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                        .padding(10).background(.white, in: .rect(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Scan the code with an authenticator app, then type the six-digit code it shows.").fixedSize(horizontal: false, vertical: true)
                    Text("Secret").font(.caption).foregroundStyle(.secondary)
                    Text(secret).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    if users.count > 1 {
                        Picker("User", selection: $user) { ForEach(users, id: \.self) { Text($0.label).tag($0.value) } }
                    }
                    TextField("Description", text: $label).textFieldStyle(.roundedBorder)
                    TextField("123456", text: $code).textFieldStyle(.roundedBorder).font(.system(.title3, design: .monospaced))
                    if owner.needsPassword {
                        SecureField("Your password", text: $password).textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    Task {
                        busy = true
                        var params = ["type": "totp", "totp": uri, "value": code, "description": label]
                        if owner.needsPassword { params["password"] = password }
                        if await session.run("Add the authenticator", .post, "/access/tfa/\(user.enc)", params) { dismiss() }
                        busy = false
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(code.count < 6 || busy || (owner.needsPassword && password.isEmpty))
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 560)
        .task {
            user = owner.signedIn
            users = await owner.users()
        }
    }

    static func randomSecret() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var generator = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: Groups, pools, roles, realms

private struct GroupsList: View {
    @Environment(Session.self) private var session
    @State private var editing: Row??

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add Group", systemImage: "plus") { editing = .some(nil) }
                Spacer()
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            ResourceList(path: "/access/groups", id: { $0.string("groupid") ?? "" },
                         columns: [APIColumn("Group", key: "groupid", width: 160), APIColumn("Members", key: "users", width: 260),
                                   APIColumn("Comment", key: "comment", width: 260)],
                         emptyTitle: "No groups", emptySymbol: "person.3", open: { editing = .some($0) }) { row in
                Button("Edit…") { editing = .some(row) }
            } delete: { row in
                Deletion { session.confirmDelete("Delete group \(row.id)?", path: "/access/groups/\(row.id.enc)") }
            }
        }
        .sheet(item: Binding(get: { editing.map { SimpleEdit(row: $0) } }, set: { editing = $0.map(\.row) })) { edit in
            FormSheet(title: edit.row == nil ? "Add group" : "Edit \(edit.row!.id)",
                      fields: [FormField(key: "groupid", label: "Name", required: true, lockedOnEdit: true), FormField(key: "comment", label: "Comment")],
                      initial: ["groupid": edit.row?.id ?? "", "comment": edit.row?["comment"] ?? ""], isEdit: edit.row != nil) { result in
                if let row = edit.row { return await session.run("Save group \(row.id)", .put, "/access/groups/\(row.id.enc)", ["comment": result["comment"]]) }
                return await session.run("Add group \(result["groupid"])", .post, "/access/groups", result.changed)
            }
        }
    }
}

struct SimpleEdit: Identifiable {
    let row: Row?
    var id: String { row?.id ?? "new" }
}

struct PoolsList: View {
    @Environment(Session.self) private var session
    @State private var editing: Row??

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add Pool", systemImage: "plus") { editing = .some(nil) }
                Spacer()
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            ResourceList(path: "/pools", id: { $0.string("poolid") ?? "" },
                         columns: [APIColumn("Pool", key: "poolid", width: 180), APIColumn("Comment", key: "comment", width: 360)],
                         emptyTitle: "No pools", emptySymbol: "tray.2", emptyMessage: "Pools group guests and storage, for example to give a team permissions on all of them.",
                         open: { session.selection = .pool($0.id) }) { row in
                Button("Open") { session.selection = .pool(row.id) }
                Button("Edit…") { editing = .some(row) }
            } delete: { row in
                Deletion { session.confirmDelete("Delete pool \(row.id)?", message: "Only empty pools can be deleted.", path: "/pools/\(row.id.enc)") }
            }
        }
        .sheet(item: Binding(get: { editing.map { SimpleEdit(row: $0) } }, set: { editing = $0.map(\.row) })) { edit in
            FormSheet(title: edit.row == nil ? "Add pool" : "Edit \(edit.row!.id)",
                      fields: [FormField(key: "poolid", label: "Name", required: true, lockedOnEdit: true), FormField(key: "comment", label: "Comment")],
                      initial: ["poolid": edit.row?.id ?? "", "comment": edit.row?["comment"] ?? ""], isEdit: edit.row != nil) { result in
                if let row = edit.row { return await session.run("Save pool \(row.id)", .put, "/pools/\(row.id.enc)", ["comment": result["comment"]]) }
                return await session.run("Add pool \(result["poolid"])", .post, "/pools", result.changed)
            }
        }
    }
}

private struct RolesList: View {
    @Environment(Session.self) private var session
    @State private var editing: Row??
    @State private var allPrivileges: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add Role", systemImage: "plus") { editing = .some(nil) }
                Spacer()
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            ResourceList(path: "/access/roles", id: { $0.string("roleid") ?? "" },
                         columns: [APIColumn("Role", key: "roleid", width: 170), APIColumn("Built-in", width: 70) { $0.bool("special") ? "Yes" : "" },
                                   APIColumn("Privileges", width: 600) { ($0.string("privs") ?? "").replacingOccurrences(of: ",", with: ", ") }],
                         emptyTitle: "No roles", emptySymbol: "theatermasks",
                         transform: { list in
                             allPrivileges = Array(Set(list.flatMap { $0.strings("privs") })).sorted()
                             return list.sorted { ($0.bool("special") ? 0 : 1, $0.string("roleid") ?? "") < ($1.bool("special") ? 0 : 1, $1.string("roleid") ?? "") }
                         },
                         open: { if !$0.json.bool("special") { editing = .some($0) } }) { row in
                if !row.json.bool("special") {
                    Button("Edit…") { editing = .some(row) }
                } else {
                    Text("Built-in roles can't be changed")
                }
            } delete: { row in
                row.json.bool("special") ? nil : Deletion { session.confirmDelete("Delete role \(row.id)?", path: "/access/roles/\(row.id.enc)") }
            }
        }
        .sheet(item: Binding(get: { editing.map { SimpleEdit(row: $0) } }, set: { editing = $0.map(\.row) })) { edit in
            FormSheet(title: edit.row == nil ? "Add role" : "Edit \(edit.row!.id)", fields: [
                FormField(key: "roleid", label: "Name", required: true, lockedOnEdit: true),
                FormField(key: "privs", label: "Privileges", kind: .multiChoice(allPrivileges.map { FormField.Choice($0) })),
            ], initial: ["roleid": edit.row?.id ?? "", "privs": edit.row?["privs"] ?? ""], isEdit: edit.row != nil) { result in
                if let row = edit.row { return await session.run("Save role \(row.id)", .put, "/access/roles/\(row.id.enc)", ["privs": result["privs"]]) }
                return await session.run("Add role \(result["roleid"])", .post, "/access/roles", result.changed)
            }
        }
    }
}

private struct RealmsList: View {
    @Environment(Session.self) private var session
    @State private var adding: String?
    @State private var editing: Row?
    @State private var syncing: Row?
    @State private var editingJob: Row??

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu("Add Realm", systemImage: "plus") {
                    Button("LDAP Server…") { adding = "ldap" }
                    Button("Active Directory…") { adding = "ad" }
                    Button("OpenID Connect…") { adding = "openid" }
                }
                .fixedSize()
                Spacer()
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            ResourceList(path: "/access/domains", id: { $0.string("realm") ?? "" },
                         columns: [APIColumn("Realm", key: "realm", width: 140), APIColumn("Type", width: 100) { ($0.string("type") ?? "").uppercased() },
                                   APIColumn("Default", width: 70) { $0.bool("default") ? "Yes" : "" },
                                   APIColumn("Two-factor", key: "tfa", width: 120), APIColumn("Comment", key: "comment", width: 300)],
                         emptyTitle: "No realms", emptySymbol: "building.columns", open: { editing = $0 }) { row in
                Button("Edit…") { editing = row }
                if ["ldap", "ad"].contains(row["type"] ?? "") {
                    Button("Sync…") { syncing = row }
                }
            } delete: { row in
                ["pam", "pve"].contains(row.id) ? nil : Deletion { session.confirmDelete("Delete realm \(row.id)?", message: "Users from this realm can't sign in anymore.", path: "/access/domains/\(row.id.enc)") }
            }
            HStack {
                Text("Scheduled Syncs").font(.headline)
                Spacer()
                Button("Add Sync Job", systemImage: "plus") { editingJob = .some(nil) }.buttonStyle(.glass)
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 6)
            ResourceList(path: "/cluster/jobs/realm-sync", id: { $0.string("id") ?? "" },
                         columns: [APIColumn("Job", key: "id", width: 140), APIColumn("Realm", key: "realm", width: 110),
                                   APIColumn("Schedule", key: "schedule", width: 120, monospaced: true),
                                   APIColumn("Syncs", width: 110) { ["users": "Users", "groups": "Groups", "both": "Users & groups"][$0.string("scope") ?? ""] ?? "Realm default" },
                                   APIColumn("On", width: 44) { $0["enabled"] == nil || $0.bool("enabled") ? "Yes" : "No" },
                                   APIColumn("Next run", width: 150) { Format.epoch($0.int("next-run")).map(Format.dateTime) ?? "–" },
                                   APIColumn("Comment", key: "comment", width: 200)],
                         emptyTitle: "No scheduled syncs", emptySymbol: "calendar.badge.clock",
                         emptyMessage: "Keep LDAP and Active Directory users and groups in step automatically.",
                         open: { editingJob = .some($0) }) { row in
                Button("Edit…") { editingJob = .some(row) }
                Button(row.json["enabled"] == nil || row.json.bool("enabled") ? "Disable" : "Enable") {
                    let enabled = row.json["enabled"] == nil || row.json.bool("enabled")
                    Task { await session.run(enabled ? "Disable the sync job" : "Enable the sync job", .put, "/cluster/jobs/realm-sync/\(row.id.enc)",
                                             ["enabled": enabled ? "0" : "1", "schedule": row["schedule"] ?? ""]) }
                }
            } delete: { row in
                Deletion { session.confirmDelete("Delete sync job \(row.id)?", path: "/cluster/jobs/realm-sync/\(row.id.enc)") }
            }
        }
        .sheet(item: $editing) { RealmEditor(row: $0) }
        .sheet(item: $syncing) { RealmSyncSheet(realm: $0.id) }
        .sheet(item: Binding(get: { editingJob.map { SimpleEdit(row: $0) } }, set: { editingJob = $0.map(\.row) })) { RealmSyncJobEditor(job: $0.row) }
        .debugAction("edit-realm") { editing = Row(id: "company", json: ["realm": "company", "type": "ldap"]) }
        .debugAction("sync-realm") { syncing = Row(id: "company", json: ["realm": "company", "type": "ldap"]) }
        .debugAction("add-sync-job") { editingJob = .some(nil) }
        .sheet(item: Binding(get: { adding.map { RealmType(type: $0) } }, set: { adding = $0?.type })) { realm in
            FormSheet(title: realm.title, fields: realm.fields, submitTitle: "Add") { result in
                var params = result.changed
                params["type"] = realm.type
                if params["default"] == "0" { params["default"] = nil }
                return await session.run("Add realm \(result["realm"])", .post, "/access/domains", params)
            }
        }
    }

    /// The settings a realm of this type has.
    static func fields(for type: String) -> [FormField] { RealmType(type: type).fields }

    private struct RealmType: Identifiable {
        let type: String
        var id: String { type }
        var title: String { ["ldap": "Add LDAP realm", "ad": "Add Active Directory realm", "openid": "Add OpenID Connect realm"][type] ?? "Add realm" }
        var fields: [FormField] {
            var fields = [FormField(key: "realm", label: "Realm ID", prompt: "company", required: true, lockedOnEdit: true)]
            switch type {
            case "ldap":
                fields += [FormField(key: "server1", label: "Server", prompt: "ldap.example.com", required: true),
                           FormField(key: "server2", label: "Fallback server"),
                           FormField(key: "base_dn", label: "Base DN", prompt: "ou=people,dc=example,dc=com", required: true),
                           FormField(key: "user_attr", label: "User attribute", prompt: "uid", required: true),
                           FormField(key: "port", label: "Port", kind: .number, prompt: "389"),
                           FormField(key: "mode", label: "Mode", kind: .choice([.init("ldap", "LDAP"), .init("ldaps", "LDAPS"), .init("ldap+starttls", "LDAP + STARTTLS")])),
                           FormField(key: "verify", label: "Verify the server's certificate", kind: .toggle),
                           FormField(key: "bind_dn", label: "Bind user", prompt: "cn=reader,dc=example,dc=com", help: "Needed for syncing unless the directory allows anonymous reads"),
                           FormField(key: "password", label: "Bind password", kind: .secure, prompt: "Unchanged")]
            case "ad":
                fields += [FormField(key: "domain", label: "Domain", prompt: "example.com", required: true),
                           FormField(key: "server1", label: "Server", prompt: "dc1.example.com", required: true),
                           FormField(key: "server2", label: "Fallback server"),
                           FormField(key: "port", label: "Port", kind: .number, prompt: "389"),
                           FormField(key: "mode", label: "Mode", kind: .choice([.init("ldap", "LDAP"), .init("ldaps", "LDAPS"), .init("ldap+starttls", "LDAP + STARTTLS")])),
                           FormField(key: "verify", label: "Verify the server's certificate", kind: .toggle),
                           FormField(key: "bind_dn", label: "Bind user", prompt: "reader@example.com"),
                           FormField(key: "password", label: "Bind password", kind: .secure, prompt: "Unchanged")]
            case "pam", "pve":
                break
            default:
                fields += [FormField(key: "issuer-url", label: "Issuer URL", prompt: "https://login.example.com", required: true),
                           FormField(key: "client-id", label: "Client ID", required: true),
                           FormField(key: "client-key", label: "Client key", kind: .secure),
                           FormField(key: "username-claim", label: "Username claim", prompt: "subject"),
                           FormField(key: "autocreate", label: "Create users automatically", kind: .toggle)]
            }
            fields += [FormField(key: "default", label: "Default realm", kind: .toggle), FormField(key: "comment", label: "Comment")]
            return fields
        }
    }
}

/// A realm's settings, as when it was added; the ID and type stay.
private struct RealmEditor: View {
    @Environment(Session.self) private var session
    let row: Row

    var body: some View {
        Prepared(load: { (try? await session.client.object("/access/domains/\(row.id.enc)")) ?? row.json }) { config in
            let type = config.string("type") ?? row["type"] ?? ""
            let fields = RealmsList.fields(for: type)
            FormSheet(title: "Edit realm \(row.id)", fields: fields,
                      initial: Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.key == "password" ? "" : config.string($0.key) ?? "") }),
                      isEdit: true) { result in
                var params = result.params
                params["realm"] = nil
                // An empty bind password means "keep the current one", not "remove it".
                if params["password"] == nil { params["delete"] = params["delete"]?.split(separator: ",").filter { $0 != "password" }.joined(separator: ",") }
                if params["delete"]?.isEmpty == true { params["delete"] = nil }
                return await session.run("Save realm \(row.id)", .put, "/access/domains/\(row.id.enc)", params)
            }
        }
    }
}

/// Pulls users and groups from the directory now, with the web UI's options; a preview changes nothing.
private struct RealmSyncSheet: View {
    @Environment(Session.self) private var session
    let realm: String

    var body: some View {
        FormSheet(title: "Sync \(realm)", message: "Copies users and groups from the directory. Groups arrive as NAME-\(realm).", fields: [
            FormField(key: "scope", label: "Sync", kind: .choice([.init("users", "Users"), .init("groups", "Groups"), .init("both", "Users and groups")]), prompt: "Realm default"),
            FormField(key: "enable-new", label: "Enable new users", kind: .toggle),
            FormField(key: "remove-vanished", label: "When something vanishes from the directory, remove",
                      kind: .multiChoice([.init("acl", "Its permissions"), .init("entry", "The user or group"), .init("properties", "Its properties")])),
            FormField(key: "dry-run", label: "Preview only", kind: .toggle, help: "Writes what would change to the task log and changes nothing"),
        ], initial: ["enable-new": "1", "dry-run": "1"], submitTitle: "Sync") { result in
            var params: [String: String] = [:]
            if !result["scope"].isEmpty { params["scope"] = result["scope"] }
            params["enable-new"] = result["enable-new"] == "1" ? "1" : "0"
            if !result["remove-vanished"].isEmpty { params["remove-vanished"] = result["remove-vanished"].replacingOccurrences(of: ",", with: ";") }
            if result["dry-run"] == "1" { params["dry-run"] = "1" }
            return await session.run(result["dry-run"] == "1" ? "Preview the sync of \(realm)" : "Sync \(realm)", .post, "/access/domains/\(realm.enc)/sync", params)
        }
    }
}

/// A scheduled realm sync (PVE 8+).
private struct RealmSyncJobEditor: View {
    @Environment(Session.self) private var session
    let job: Row?

    var body: some View {
        Prepared(load: { ((try? await session.client.list("/access/domains")) ?? []).filter { ["ldap", "ad"].contains($0.string("type") ?? "") }.compactMap { $0.text("realm") } }) { realms in
            let json = job?.json ?? [:]
            FormSheet(title: job == nil ? "Add sync job" : "Edit sync job \(job!.id)", message: realms.isEmpty ? "Add an LDAP or Active Directory realm first." : nil, fields: [
                FormField(key: "id", label: "Job ID", prompt: "nightly-ldap", required: true, lockedOnEdit: true),
                FormField(key: "realm", label: "Realm", kind: .choice(realms.map { FormField.Choice($0) }), required: true, lockedOnEdit: true),
                FormField(key: "schedule", label: "Schedule", kind: .suggested(Choices.schedules), prompt: "daily, or e.g. *-*-* 02:00", required: true),
                FormField(key: "scope", label: "Sync", kind: .choice([.init("users", "Users"), .init("groups", "Groups"), .init("both", "Users and groups")]), prompt: "Realm default"),
                FormField(key: "enable-new", label: "Enable new users", kind: .toggle),
                FormField(key: "remove-vanished", label: "When something vanishes, remove",
                          kind: .multiChoice([.init("acl", "Its permissions"), .init("entry", "The user or group"), .init("properties", "Its properties")])),
                FormField(key: "enabled", label: "Enabled", kind: .toggle),
                FormField(key: "comment", label: "Comment"),
            ], initial: ["id": job?.id ?? "", "realm": json.string("realm") ?? realms.first ?? "", "schedule": json.string("schedule") ?? "daily",
                         "scope": json.string("scope") ?? "", "enable-new": json["enable-new"] == nil || json.bool("enable-new") ? "1" : "0",
                         "remove-vanished": (json.string("remove-vanished") ?? "").replacingOccurrences(of: ";", with: ","),
                         "enabled": json["enabled"] == nil || json.bool("enabled") ? "1" : "0", "comment": json.string("comment") ?? ""],
                      isEdit: job != nil, submitTitle: job == nil ? "Add" : "Save") { result in
                var params = job == nil ? result.changed : result.params
                params["id"] = nil
                if let vanished = params["remove-vanished"] { params["remove-vanished"] = vanished.replacingOccurrences(of: ",", with: ";") }
                params["schedule"] = result["schedule"]
                if let job {
                    params["realm"] = nil
                    return await session.run("Save sync job \(job.id)", .put, "/cluster/jobs/realm-sync/\(job.id.enc)", params)
                }
                params["realm"] = result["realm"]
                params["enabled"] = result["enabled"] == "1" ? "1" : "0"
                return await session.run("Add sync job \(result["id"])", .post, "/cluster/jobs/realm-sync/\(result["id"].enc)", params)
            }
        }
    }
}
