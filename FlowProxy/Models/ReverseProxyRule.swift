import Foundation

// MARK: - Rewrite Action
enum RewriteAction: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case addRequestHeader = "Add Request Header"
    case removeRequestHeader = "Remove Request Header"
    case addResponseHeader = "Add Response Header"
    case rewritePath = "Rewrite Path"

    var id: String { rawValue }
}

// MARK: - Rewrite Rule
struct RewriteEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var action: RewriteAction
    var key: String      // header name or path pattern
    var value: String    // header value or replacement
}

// MARK: - ReverseProxyRule
struct ReverseProxyRule: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var localPort: Int
    var upstreamURL: URL
    var isEnabled: Bool = true
    var rewriteEntries: [RewriteEntry] = []
    var sslVerification: Bool = true
    var notes: String = ""

    // MARK: - Computed

    var displayName: String {
        if !name.isEmpty { return name }
        return ":\(localPort) → \(upstreamURL.host ?? upstreamURL.absoluteString)"
    }

    var upstreamHost: String {
        upstreamURL.host ?? ""
    }

    var upstreamPort: Int {
        if upstreamURL.port != nil {
            return upstreamURL.port!
        }
        return upstreamURL.scheme?.lowercased() == "https" ? 443 : 80
    }

    var isHTTPS: Bool {
        upstreamURL.scheme?.lowercased() == "https"
    }

    // Apply request header rewrites
    func applyRequestRewrites(to headers: inout [String: String], path: inout String) {
        for entry in rewriteEntries where entry.action != .none {
            switch entry.action {
            case .addRequestHeader:
                headers[entry.key] = entry.value
            case .removeRequestHeader:
                headers.removeValue(forKey: entry.key)
                headers.removeValue(forKey: entry.key.lowercased())
            case .rewritePath:
                // Simple prefix replacement
                if path.hasPrefix(entry.key) {
                    path = entry.value + path.dropFirst(entry.key.count)
                }
            default:
                break
            }
        }
    }

    // Apply response header rewrites
    func applyResponseRewrites(to headers: inout [String: String]) {
        for entry in rewriteEntries where entry.action == .addResponseHeader {
            headers[entry.key] = entry.value
        }
    }
}

// MARK: - Equatable
extension ReverseProxyRule: Equatable {
    static func == (lhs: ReverseProxyRule, rhs: ReverseProxyRule) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Hashable
extension ReverseProxyRule: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
