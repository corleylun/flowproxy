import Foundation
import SwiftUI
import Combine

// MARK: - Proxy ViewModel
@MainActor
final class ProxyViewModel: ObservableObject {

    // MARK: - Published Properties
    @Published var isRunning: Bool = false
    @Published var port: Int = 8888
    @Published var errorMessage: String? = nil
    @Published var statusMessage: String = "Stopped"
    @Published var reverseProxyRules: [ReverseProxyRule] = []
    @Published var isShowingReverseProxy: Bool = false
    @Published var isShowingCAExport: Bool = false
    @Published var caExportMessage: String = ""

    // MARK: - Dependencies
    let trafficStore: TrafficStore

    private let caManager = CertificateAuthorityManager.shared
    private var proxyServer: ProxyServer?
    private let reverseProxyManager = ReverseProxyManager()

    // MARK: - Init
    init(trafficStore: TrafficStore) {
        self.trafficStore = trafficStore
        loadSavedRules()
    }

    // MARK: - Start Proxy

    func startProxy() {
        guard !isRunning else { return }
        errorMessage = nil
        statusMessage = "Starting..."

        let server = ProxyServer(caManager: caManager)
        proxyServer = server

        Task {
            do {
                // Wire up session callbacks
                await server.setCallbacks(
                    onNew: { [weak self] session in
                        Task { @MainActor in
                            self?.trafficStore.addSession(session)
                        }
                    },
                    onUpdate: { [weak self] session in
                        Task { @MainActor in
                            self?.trafficStore.updateSession(session)
                        }
                    }
                )

                try await server.start(port: UInt16(port))
                isRunning = true
                statusMessage = "Listening on port \(port)"

                // Start reverse proxy rules
                for rule in reverseProxyRules where rule.isEnabled {
                    try? await reverseProxyManager.startRule(rule)
                }

            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Failed to start"
                proxyServer = nil
                isRunning = false
            }
        }
    }

    // MARK: - Stop Proxy

    func stopProxy() {
        guard isRunning else { return }

        Task {
            if let server = proxyServer {
                await server.stop()
            }
            await reverseProxyManager.stopAll()
            proxyServer = nil
            isRunning = false
            statusMessage = "Stopped"
        }
    }

    // MARK: - Toggle

    func toggleProxy() {
        if isRunning {
            stopProxy()
        } else {
            startProxy()
        }
    }

    // MARK: - Reverse Proxy Rules

    func addReverseProxyRule(name: String, localPort: Int, upstreamURLString: String) -> Bool {
        guard let url = URL(string: upstreamURLString) else {
            errorMessage = "Invalid upstream URL: \(upstreamURLString)"
            return false
        }

        // Check port not already used
        if reverseProxyRules.contains(where: { $0.localPort == localPort }) {
            errorMessage = "Port \(localPort) is already in use by another rule"
            return false
        }

        let rule = ReverseProxyRule(name: name, localPort: localPort, upstreamURL: url)
        reverseProxyRules.append(rule)
        saveRules()

        if isRunning {
            Task {
                try? await reverseProxyManager.startRule(rule)
            }
        }
        return true
    }

    func removeReverseProxyRule(_ rule: ReverseProxyRule) {
        Task {
            await reverseProxyManager.stopRule(rule)
        }
        reverseProxyRules.removeAll { $0.id == rule.id }
        saveRules()
    }

    func toggleReverseProxyRule(_ rule: ReverseProxyRule) {
        guard let idx = reverseProxyRules.firstIndex(of: rule) else { return }
        reverseProxyRules[idx].isEnabled.toggle()
        saveRules()

        if isRunning {
            let updatedRule = reverseProxyRules[idx]
            Task {
                if updatedRule.isEnabled {
                    try? await reverseProxyManager.startRule(updatedRule)
                } else {
                    await reverseProxyManager.stopRule(updatedRule)
                }
            }
        }
    }

    // MARK: - CA Export

    func exportCACertificate() {
        Task {
            let caReady = await caManager.isReady
            if !caReady {
                // Initialize CA first
                do {
                    try await caManager.initialize()
                } catch {
                    errorMessage = "Failed to initialize CA: \(error.localizedDescription)"
                    return
                }
            }

            guard let pem = await caManager.exportCACertificatePEM() else {
                errorMessage = "Failed to export CA certificate"
                return
            }

            // Show save panel
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "FlowProxy-CA.pem"
            panel.allowedContentTypes = [.init(filenameExtension: "pem")!]
            panel.title = "Export FlowProxy CA Certificate"
            panel.message = "Save the CA certificate to install it in your system keychain"

            let result = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow())
            if result == .OK, let url = panel.url {
                do {
                    try pem.write(to: url, atomically: true, encoding: .utf8)
                    caExportMessage = "CA certificate exported. Double-click the file and add it to your Keychain as a trusted root."
                    isShowingCAExport = true
                } catch {
                    errorMessage = "Failed to write certificate: \(error.localizedDescription)"
                }
            }
        }
    }

    func installCATrustSettings() {
        Task {
            guard await caManager.isReady else {
                errorMessage = "CA not ready. Start the proxy first."
                return
            }
            do {
                try await caManager.installCAInSystemKeychain()
                caExportMessage = "CA trust settings updated successfully."
                isShowingCAExport = true
            } catch {
                errorMessage = "Failed to install CA: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Persistence

    private var rulesURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FlowProxy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reverse_proxy_rules.json")
    }

    private func saveRules() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(reverseProxyRules) {
            try? data.write(to: rulesURL)
        }
    }

    private func loadSavedRules() {
        guard let data = try? Data(contentsOf: rulesURL),
              let rules = try? JSONDecoder().decode([ReverseProxyRule].self, from: data) else { return }
        reverseProxyRules = rules
    }
}

// MARK: - ProxyServer callback extension
extension ProxyServer {
    func setCallbacks(onNew: @escaping (ProxySession) -> Void,
                      onUpdate: @escaping (ProxySession) -> Void) async {
        self.onNewSession = onNew
        self.onUpdateSession = onUpdate
    }
}
