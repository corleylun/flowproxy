import SwiftUI

@main
struct FlowProxyApp: App {

    @StateObject private var trafficStore = TrafficStore()
    @StateObject private var viewModel: ProxyViewModel

    init() {
        let store = TrafficStore()
        let vm = ProxyViewModel(trafficStore: store)
        _trafficStore = StateObject(wrappedValue: store)
        _viewModel = StateObject(wrappedValue: vm)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(trafficStore)
                .environmentObject(viewModel)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // File menu
            CommandGroup(after: .newItem) {
                Button("Import Sessions...") {
                    importSessions()
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Export Sessions...") {
                    exportSessions()
                }
                .keyboardShortcut("e", modifiers: [.command])
            }

            // Edit menu additions
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Clear Sessions") {
                    trafficStore.clearSessions()
                }
                .keyboardShortcut("k", modifiers: [.command])
            }

            // Help menu
            CommandGroup(replacing: .help) {
                Link("FlowProxy Website", destination: URL(string: "https://flowstations.net")!)
            }

            // Proxy menu
            CommandMenu("Proxy") {
                Button(viewModel.isRunning ? "Stop Proxy" : "Start Proxy") {
                    viewModel.toggleProxy()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                Button("Export CA Certificate...") {
                    viewModel.exportCACertificate()
                }

                Button("Trust CA in System Keychain") {
                    viewModel.installCATrustSettings()
                }

                Divider()

                Button("Reverse Proxy Rules...") {
                    viewModel.isShowingReverseProxy = true
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(viewModel)
        }
    }

    private func importSessions() {
        let panel = NSOpenPanel()
        panel.title = "Import Sessions"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Select a FlowProxy session export file"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let count = try trafficStore.importSessions(from: data)
            print("[Import] Loaded \(count) sessions from \(url.lastPathComponent)")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func exportSessions() {
        let data = trafficStore.exportSessions()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "flowproxy-sessions.json"
        panel.allowedContentTypes = [.json]
        panel.title = "Export Sessions"

        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var viewModel: ProxyViewModel
    @State private var portText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Proxy section
            VStack(alignment: .leading, spacing: 8) {
                Text("Proxy")
                    .font(.headline)
                HStack {
                    Text("Listen Port")
                    TextField("Port", text: $portText)
                        .frame(width: 80)
                        .onAppear { portText = "\(viewModel.port)" }
                        .onChange(of: portText) { newVal in
                            if let p = Int(newVal), p > 0 && p < 65536 {
                                viewModel.port = p
                            }
                        }
                }
            }

            Divider()

            // Certificate Authority section
            VStack(alignment: .leading, spacing: 8) {
                Text("Certificate Authority")
                    .font(.headline)
                Text("FlowProxy uses a local CA certificate to intercept HTTPS traffic.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Button("Export CA Certificate...") {
                        viewModel.exportCACertificate()
                    }
                    Button("Trust CA in System Keychain") {
                        viewModel.installCATrustSettings()
                    }
                }
            }

            Spacer()

            Divider()

            HStack {
                Spacer()
                Link("flowstations.net", destination: URL(string: "https://flowstations.net")!)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 420, height: 260)
    }
}
