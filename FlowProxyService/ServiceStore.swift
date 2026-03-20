import Foundation

/// Thread-safe in-memory store for the FlowProxy background service.
actor ServiceStore {

    // MARK: - Sessions

    private(set) var sessions: [ProxySession] = []

    func add(_ session: ProxySession) {
        sessions.append(session)
    }

    func update(_ session: ProxySession) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
        }
    }

    func clear() {
        sessions.removeAll()
    }

    func get(id: UUID) -> ProxySession? {
        sessions.first { $0.id == id }
    }

    func filtered(
        limit: Int? = nil,
        host: String? = nil,
        method: String? = nil,
        status: Int? = nil,
        search: String? = nil
    ) -> [ProxySession] {
        var r = sessions
        if let v = host,   !v.isEmpty { r = r.filter { $0.host.lowercased().contains(v.lowercased()) } }
        if let v = method, !v.isEmpty { r = r.filter { $0.method.uppercased() == v.uppercased() } }
        if let v = status              { r = r.filter { $0.responseStatusCode == v } }
        if let v = search, !v.isEmpty {
            let low = v.lowercased()
            r = r.filter {
                $0.host.lowercased().contains(low) ||
                $0.path.lowercased().contains(low) ||
                $0.method.lowercased().contains(low)
            }
        }
        if let n = limit { r = Array(r.suffix(n)) }
        return r
    }

    // MARK: - Reverse proxy rules (persisted)

    private(set) var reverseProxyRules: [ReverseProxyRule] = []

    func addRule(_ rule: ReverseProxyRule) {
        reverseProxyRules.append(rule)
        saveRules()
    }

    func removeRule(id: UUID) {
        reverseProxyRules.removeAll { $0.id == id }
        saveRules()
    }

    func loadRules() {
        guard let data  = try? Data(contentsOf: rulesURL),
              let rules = try? JSONDecoder().decode([ReverseProxyRule].self, from: data) else { return }
        reverseProxyRules = rules
    }

    // MARK: - Persistence helpers

    private func saveRules() {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(reverseProxyRules) { try? data.write(to: rulesURL) }
    }

    private var rulesURL: URL {
        let dir = flowproxyDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reverse_proxy_rules.json")
    }

    private var flowproxyDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".flowproxy")
    }
}
