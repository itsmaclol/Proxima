import SwiftUI

/// The QEMU human monitor of a running VM: type a command, read the reply.
struct MonitorView: View {
    @Environment(Session.self) private var session
    let guest: Resource
    @State private var command = ""
    @State private var transcript: [(command: String, reply: String)] = []
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if transcript.isEmpty {
                            Text("Type a monitor command such as info status, info block or help. Commands run directly in QEMU, so be careful with anything that changes state.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(transcript.enumerated()), id: \.offset) { index, entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("qm> \(entry.command)").foregroundStyle(.tint)
                                Text(entry.reply.isEmpty ? "(no output)" : entry.reply).foregroundStyle(entry.reply.isEmpty ? .secondary : .primary)
                            }
                            .id(index)
                        }
                    }
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .onChange(of: transcript.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            }
            Divider()
            HStack {
                TextField("Monitor command", text: $command, prompt: Text("info status"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(run)
                if busy { ProgressView().controlSize(.small) }
                Button("Run", action: run).disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            .padding(14)
        }
    }

    private func run() {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        command = ""
        busy = true
        Task {
            defer { busy = false }
            do {
                let reply = try await session.client.post("/nodes/\(guest.node.enc)/qemu/\(guest.vmid)/monitor", ["command": text]) as? String ?? ""
                transcript.append((text, reply.trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch {
                transcript.append((text, error.localizedDescription))
            }
        }
    }
}
