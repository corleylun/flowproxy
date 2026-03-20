import Foundation

enum OutputFormatter {

    // MARK: - Proxy status

    static func proxyStatus(_ data: Data, json: Bool) {
        if json { printRaw(data); return }
        guard let obj     = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let running = obj["running"] as? Bool ?? false
        let port    = obj["port"]    as? Int  ?? 0
        print(running ? "Proxy: running (port \(port))" : "Proxy: stopped")
    }

    // MARK: - Sessions list

    static func sessionsList(_ data: Data, json: Bool) {
        if json { printRaw(data); return }
        guard let obj      = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [[String: Any]] else { return }

        if sessions.isEmpty { print("No sessions."); return }

        let idW = 10; let methodW = 8; let hostW = 30; let statusW = 7; let timeW = 8
        let total = idW + methodW + hostW + statusW + timeW
        print(col("ID", idW) + col("METHOD", methodW) + col("HOST", hostW)
            + col("STATUS", statusW) + col("TIME", timeW))
        print(String(repeating: "─", count: total))

        for s in sessions {
            let id     = String((s["id"]     as? String ?? "").prefix(8))
            let method = s["method"] as? String ?? ""
            let host   = trunc(s["host"] as? String ?? "", hostW - 2)
            let status = s["status"].map { "\($0)" } ?? "─"
            let time   = fmtMs(s["duration_ms"] as? Int)
            print(col(id, idW) + col(method, methodW) + col(host, hostW)
                + col(status, statusW) + col(time, timeW))
        }
        print("\n\(obj["count"] as? Int ?? sessions.count) session(s)")
    }

    // MARK: - Session detail

    static func sessionDetail(_ data: Data, json: Bool) {
        if json { printRaw(data); return }
        guard let s = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        field("ID",       s["id"]       as? String ?? "")
        field("Method",   s["method"]   as? String ?? "")
        field("Host",     s["host"]     as? String ?? "")
        field("Path",     s["path"]     as? String ?? "")
        field("Protocol", s["protocol"] as? String ?? "")
        field("Status",   s["status"].map { "\($0)" } ?? "─")
        field("Duration", fmtMs(s["duration_ms"] as? Int))
        field("State",    s["state"]    as? String ?? "")
        if let err = s["error"] as? String { field("Error", err) }

        if let hdrs = s["requestHeaders"] as? [String: String], !hdrs.isEmpty {
            print("\nRequest Headers:")
            hdrs.sorted { $0.key < $1.key }.forEach { print("  \($0.key): \($0.value)") }
        }
        if let hdrs = s["responseHeaders"] as? [String: String], !hdrs.isEmpty {
            print("\nResponse Headers:")
            hdrs.sorted { $0.key < $1.key }.forEach { print("  \($0.key): \($0.value)") }
        }
        if let body = s["requestBody"]  as? String, !body.isEmpty { print("\nRequest Body:\n\(body.prefix(500))") }
        if let body = s["responseBody"] as? String, !body.isEmpty { print("\nResponse Body:\n\(body.prefix(500))") }
    }

    // MARK: - Reverse proxy list

    static func reverseProxyList(_ data: Data, json: Bool) {
        if json { printRaw(data); return }
        guard let obj   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = obj["rules"] as? [[String: Any]] else { return }

        if rules.isEmpty { print("No reverse proxy rules."); return }

        let idW = 10; let nameW = 20; let portW = 12; let upW = 40
        print(col("ID", idW) + col("NAME", nameW) + col("PORT", portW) + col("UPSTREAM", upW))
        print(String(repeating: "─", count: idW + nameW + portW + upW))
        for r in rules {
            let id       = String((r["id"]   as? String ?? "").prefix(8))
            let name     = trunc(r["name"]        as? String ?? "", nameW - 2)
            let port     = r["localPort"].map { "\($0)" } ?? "─"
            let upstream = trunc(r["upstreamURL"] as? String ?? "", upW - 2)
            let disabled = (r["isEnabled"] as? Bool ?? true) ? "" : " (disabled)"
            print(col(id, idW) + col(name, nameW) + col(port, portW) + upstream + disabled)
        }
    }

    // MARK: - Generic

    static func success(_ data: Data, json: Bool, message: String? = nil) {
        if json { printRaw(data); return }
        print(message ?? "OK")
    }

    static func printError(_ error: Error) {
        fputs("Error: \(error.localizedDescription)\n", stderr)
    }

    // MARK: - Helpers

    private static func printRaw(_ data: Data) {
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    private static func col(_ s: String, _ w: Int) -> String {
        s.count >= w ? s + " " : s + String(repeating: " ", count: w - s.count)
    }

    private static func trunc(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }

    private static func fmtMs(_ ms: Int?) -> String {
        guard let ms else { return "─" }
        return ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000)
    }

    private static func field(_ label: String, _ value: String) {
        let pad = (label + ":").padding(toLength: 12, withPad: " ", startingAt: 0)
        print("\(pad) \(value)")
    }
}
