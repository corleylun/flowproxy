import Foundation
import SwiftUI

// MARK: - Protocol Enum
enum ProxyProtocol: String, Codable, CaseIterable {
    case http = "HTTP"
    case https = "HTTPS"
}

// MARK: - Content Category
enum ContentCategory: String, CaseIterable {
    case all   = "All"
    case xhr   = "XHR"
    case html  = "HTML"
    case js    = "JS"
    case css   = "CSS"
    case image = "Image"
    case font  = "Font"
    case media = "Media"
    case other = "Other"
}

// MARK: - Session State
enum SessionState: String, Codable {
    case pending = "Pending"
    case complete = "Complete"
    case error = "Error"
}

// MARK: - TLS Metadata
struct TLSMetadata: Codable {
    var version: String
    var cipherSuite: String
    var serverCertificate: Data?
    var serverCertSubject: String?
}

// MARK: - Timing Info
struct TimingInfo: Codable {
    var dnsStart: Date?
    var dnsEnd: Date?
    var connectStart: Date?
    var connectEnd: Date?
    var tlsStart: Date?
    var tlsEnd: Date?
    var requestSent: Date?
    var firstByte: Date?
    var responseEnd: Date?

    var dnsDuration: TimeInterval? {
        guard let s = dnsStart, let e = dnsEnd else { return nil }
        return e.timeIntervalSince(s)
    }

    var connectDuration: TimeInterval? {
        guard let s = connectStart, let e = connectEnd else { return nil }
        return e.timeIntervalSince(s)
    }

    var tlsDuration: TimeInterval? {
        guard let s = tlsStart, let e = tlsEnd else { return nil }
        return e.timeIntervalSince(s)
    }

    var ttfb: TimeInterval? {
        guard let s = requestSent, let e = firstByte else { return nil }
        return e.timeIntervalSince(s)
    }

    var downloadDuration: TimeInterval? {
        guard let s = firstByte, let e = responseEnd else { return nil }
        return e.timeIntervalSince(s)
    }
}

// MARK: - ProxySession
class ProxySession: ObservableObject, Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    var sessionProtocol: ProxyProtocol
    var host: String
    var path: String
    var method: String
    var requestHeaders: [String: String]
    var requestBody: Data?
    var responseStatusCode: Int?
    var responseHeaders: [String: String]
    var responseBody: Data?
    var duration: TimeInterval?
    var tlsMetadata: TLSMetadata?
    var error: String?
    var state: SessionState
    var timing: TimingInfo?
    var queryString: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionProtocol: ProxyProtocol = .http,
        host: String = "",
        path: String = "/",
        method: String = "GET",
        requestHeaders: [String: String] = [:],
        requestBody: Data? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionProtocol = sessionProtocol
        self.host = host
        self.path = path
        self.method = method
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.responseHeaders = [:]
        self.state = .pending
    }

    // MARK: - Codable
    enum CodingKeys: String, CodingKey {
        case id, timestamp, sessionProtocol, host, path, method
        case requestHeaders, requestBody
        case responseStatusCode, responseHeaders, responseBody
        case duration, tlsMetadata, error, state, timing, queryString
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        sessionProtocol = try c.decode(ProxyProtocol.self, forKey: .sessionProtocol)
        host = try c.decode(String.self, forKey: .host)
        path = try c.decode(String.self, forKey: .path)
        method = try c.decode(String.self, forKey: .method)
        requestHeaders = try c.decode([String: String].self, forKey: .requestHeaders)
        requestBody = try c.decodeIfPresent(Data.self, forKey: .requestBody)
        responseStatusCode = try c.decodeIfPresent(Int.self, forKey: .responseStatusCode)
        responseHeaders = try c.decode([String: String].self, forKey: .responseHeaders)
        responseBody = try c.decodeIfPresent(Data.self, forKey: .responseBody)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        tlsMetadata = try c.decodeIfPresent(TLSMetadata.self, forKey: .tlsMetadata)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        state = try c.decode(SessionState.self, forKey: .state)
        timing = try c.decodeIfPresent(TimingInfo.self, forKey: .timing)
        queryString = try c.decodeIfPresent(String.self, forKey: .queryString)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(sessionProtocol, forKey: .sessionProtocol)
        try c.encode(host, forKey: .host)
        try c.encode(path, forKey: .path)
        try c.encode(method, forKey: .method)
        try c.encode(requestHeaders, forKey: .requestHeaders)
        try c.encodeIfPresent(requestBody, forKey: .requestBody)
        try c.encodeIfPresent(responseStatusCode, forKey: .responseStatusCode)
        try c.encode(responseHeaders, forKey: .responseHeaders)
        try c.encodeIfPresent(responseBody, forKey: .responseBody)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(tlsMetadata, forKey: .tlsMetadata)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(timing, forKey: .timing)
        try c.encodeIfPresent(queryString, forKey: .queryString)
    }

    // MARK: - Computed Properties

    var statusColor: Color {
        guard let code = responseStatusCode else { return .secondary }
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500..<600: return .red
        default: return .secondary
        }
    }

    var methodColor: Color {
        switch method.uppercased() {
        case "GET": return .blue
        case "POST": return .green
        case "PUT": return Color.orange
        case "PATCH": return Color.yellow
        case "DELETE": return .red
        case "HEAD": return .purple
        case "OPTIONS": return .teal
        default: return .secondary
        }
    }

    var formattedDuration: String {
        guard let d = duration else { return "-" }
        if d < 1.0 {
            return String(format: "%.0fms", d * 1000)
        } else {
            return String(format: "%.2fs", d)
        }
    }

    var formattedSize: String {
        let size = responseBody?.count ?? 0
        if size == 0 { return "-" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", Double(size) / (1024 * 1024))
    }

    var requestBodyString: String? {
        guard let data = requestBody, !data.isEmpty else { return nil }
        let ct = requestHeaders["Content-Type"] ?? requestHeaders["content-type"] ?? ""
        if ct.contains("json"), let json = prettyPrintJSON(data) {
            return json
        }
        return String(data: data, encoding: .utf8)
    }

    var responseBodyString: String? {
        guard let data = responseBody, !data.isEmpty else { return nil }
        let ct = responseHeaders["Content-Type"] ?? responseHeaders["content-type"] ?? ""
        if ct.contains("json"), let json = prettyPrintJSON(data) {
            return json
        }
        return String(data: data, encoding: .utf8)
    }

    var isImage: Bool {
        let ct = responseHeaders["Content-Type"] ?? responseHeaders["content-type"] ?? ""
        return ct.hasPrefix("image/")
    }

    var contentCategory: ContentCategory {
        let ct   = (responseHeaders["Content-Type"] ?? responseHeaders["content-type"] ?? "").lowercased()
        let mode = (requestHeaders["Sec-Fetch-Mode"] ?? requestHeaders["sec-fetch-mode"] ?? "").lowercased()
        let xrw  = (requestHeaders["X-Requested-With"] ?? requestHeaders["x-requested-with"] ?? "").lowercased()

        // Explicit XHR marker
        if xrw == "xmlhttprequest" { return .xhr }

        // Derive from response Content-Type
        if ct.hasPrefix("text/html")                                       { return .html  }
        if ct.contains("javascript")                                        { return .js    }
        if ct.hasPrefix("text/css")                                        { return .css   }
        if ct.hasPrefix("image/")                                          { return .image }
        if ct.hasPrefix("font/") || ct.contains("woff") || ct.contains("font-") { return .font }
        if ct.hasPrefix("video/") || ct.hasPrefix("audio/")               { return .media }
        if ct.contains("json") || ct.contains("xml")                       { return .xhr   }

        // Fetch mode hints at XHR/fetch API usage
        if mode == "cors" || mode == "same-origin"                         { return .xhr   }

        // Fallback: path extension
        let base = (path.components(separatedBy: "?").first ?? "").lowercased()
        if base.hasSuffix(".js") || base.hasSuffix(".mjs")                 { return .js    }
        if base.hasSuffix(".css")                                          { return .css   }
        if ["png","jpg","jpeg","gif","svg","webp","ico","bmp","avif"]
            .contains(where: { base.hasSuffix(".\($0)") })                 { return .image }
        if ["woff","woff2","ttf","eot","otf"]
            .contains(where: { base.hasSuffix(".\($0)") })                 { return .font  }
        if ["mp4","mp3","webm","ogg","wav","avi"]
            .contains(where: { base.hasSuffix(".\($0)") })                 { return .media }
        if base.hasSuffix(".html") || base.hasSuffix(".htm")               { return .html  }

        return .other
    }

    var fullURL: String {
        let scheme = sessionProtocol.rawValue.lowercased()
        return "\(scheme)://\(host)\(path)"
    }

    var requestCookies: [HTTPCookie] {
        let cookieHeader = requestHeaders["Cookie"] ?? requestHeaders["cookie"] ?? ""
        guard !cookieHeader.isEmpty else { return [] }
        // Parse "name=value; name2=value2"
        return cookieHeader.components(separatedBy: "; ").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return HTTPCookie(properties: [
                .name: String(parts[0]).trimmingCharacters(in: .whitespaces),
                .value: String(parts[1]),
                .domain: host,
                .path: "/"
            ])
        }
    }

    var responseCookies: [HTTPCookie] {
        var cookies: [HTTPCookie] = []
        for (key, value) in responseHeaders {
            if key.lowercased() == "set-cookie" {
                if let cookie = parseSetCookie(value) {
                    cookies.append(cookie)
                }
            }
        }
        return cookies
    }

    // MARK: - Private Helpers

    private func prettyPrintJSON(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else { return nil }
        return str
    }

    private func parseSetCookie(_ header: String) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [:]
        let parts = header.components(separatedBy: ";")
        guard let first = parts.first else { return nil }
        let kv = first.split(separator: "=", maxSplits: 1)
        guard kv.count >= 1 else { return nil }
        props[.name] = String(kv[0]).trimmingCharacters(in: .whitespaces)
        props[.value] = kv.count == 2 ? String(kv[1]).trimmingCharacters(in: .whitespaces) : ""
        props[.domain] = host
        props[.path] = "/"

        for part in parts.dropFirst() {
            let attr = part.trimmingCharacters(in: .whitespaces).lowercased()
            if attr == "secure" { props[.secure] = "TRUE" }
            else if attr == "httponly" { props[.comment] = "HttpOnly" }
            else if attr.hasPrefix("path=") {
                props[.path] = String(attr.dropFirst(5))
            } else if attr.hasPrefix("domain=") {
                props[.domain] = String(attr.dropFirst(7))
            } else if attr.hasPrefix("max-age=") {
                props[.maximumAge] = String(attr.dropFirst(8))
            }
        }
        return HTTPCookie(properties: props)
    }
}

// MARK: - Equatable / Hashable
extension ProxySession: Equatable {
    static func == (lhs: ProxySession, rhs: ProxySession) -> Bool {
        lhs.id == rhs.id
    }
}

extension ProxySession: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
