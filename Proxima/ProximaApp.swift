import SwiftUI

@main
struct ProximaApp: App {
    @State private var model = AppModel()
    @AppStorage("menuBarExtra") private var showsMenuBarExtra = true

    var body: some Scene {
        Window("Proxima", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                #if DEBUG
                // Visual checks: PROXIMA_DEBUG_APPEARANCE=light|dark overrides the system appearance for this app only.
                .onAppear {
                    switch ProcessInfo.processInfo.environment["PROXIMA_DEBUG_APPEARANCE"] {
                    case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
                    case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
                    default: break
                    }
                }
                #endif
        }
        .defaultSize(width: 1320, height: 860)
        .commands { ProximaCommands(model: model) }

        WindowGroup("Console", id: "console", for: ConsoleTarget.self) { $target in
            ConsoleWindow(target: target).environment(model)
        }
        .defaultSize(width: 1024, height: 700)

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra("Proxima", systemImage: "server.rack", isInserted: $showsMenuBarExtra) {
            MenuBarPanel().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar commands. Keyboard shortcuts act instantly, without animation.
struct ProximaCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Virtual Machine…") { model.session?.sheet = .createVM(node: nil) }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(model.session == nil)
            Button("New Container…") { model.session?.sheet = .createCT(node: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.session == nil)
        }
        CommandMenu("Server") {
            Button("Refresh") { Task { await model.session?.refresh() } }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.session == nil)
            Divider()
            Button("Overview") { model.session?.selection = .overview }
                .keyboardShortcut("1", modifiers: [.command])
            Button("Guests") { model.session?.selection = .guests }
                .keyboardShortcut("2", modifiers: [.command])
            Button("Tasks") { model.session?.selection = .tasks }
                .keyboardShortcut("3", modifiers: [.command])
            Divider()
            Button("Sign Out") { model.signOut() }
                .disabled(model.session == nil)
            Button("Sign Out and Forget Password") { model.signOut(forget: true) }
                .disabled(model.session == nil)
        }
        // Every action for what's selected in the sidebar, as in its context menu.
        CommandMenu("Guest") {
            if let session = model.session, case .guest(let vmid)? = session.selection, let guest = session.guest(vmid) {
                GuestMenuItems(actions: GuestActions(session: session, guest: guest))
            } else {
                Text("Select a guest in the sidebar")
            }
        }
        CommandMenu("Node") {
            if let session = model.session, case .node(let node)? = session.selection {
                NodeMenuItems(session: session, node: node)
            } else {
                Text("Select a node in the sidebar")
            }
        }
    }
}
