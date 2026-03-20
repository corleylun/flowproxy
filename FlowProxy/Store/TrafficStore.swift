import Foundation
import Combine
import SwiftUI

// MARK: - Traffic Store
@MainActor
final class TrafficStore: ObservableObject {

    // MARK: - Published Properties
    @Published var sessions: [ProxySession] = []
    @Published var filteredSessions: [ProxySession] = []
    @Published var searchText: String = "" {
        didSet { applyFilters() }
    }
    @Published var filterMethod: String? = nil {
        didSet { applyFilters() }
    }
    @Published var filterStatusCode: Int? = nil {
        didSet { applyFilters() }
    }
    @Published var filterHost: String? = nil {
        didSet { applyFilters() }
    }
    @Published var filterProtocol: ProxyProtocol? = nil {
        didSet { applyFilters() }
    }
    @Published var showOnlyErrors: Bool = false {
        didSet { applyFilters() }
    }
    @Published var filterContentCategory: ContentCategory = .all {
        didSet { applyFilters() }
    }

    // MARK: - Session Management

    func addSession(_ session: ProxySession) {
        sessions.append(session)
        applyFilters()
    }

    func updateSession(_ session: ProxySession) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            session.objectWillChange.send()
            sessions[idx] = session
            applyFilters()
        } else {
            addSession(session)
        }
    }

    func clearSessions() {
        sessions.removeAll()
        filteredSessions.removeAll()
    }

    func removeSession(_ session: ProxySession) {
        sessions.removeAll { $0.id == session.id }
        applyFilters()
    }

    // MARK: - Filtering

    func applyFilters() {
        var result = sessions

        // Search text
        if !searchText.isEmpty {
            let lower = searchText.lowercased()
            result = result.filter { session in
                session.host.lowercased().contains(lower) ||
                session.path.lowercased().contains(lower) ||
                session.method.lowercased().contains(lower) ||
                (session.responseStatusCode.map { String($0).contains(lower) } ?? false)
            }
        }

        // Method filter
        if let method = filterMethod {
            result = result.filter { $0.method.uppercased() == method.uppercased() }
        }

        // Status code filter
        if let code = filterStatusCode {
            result = result.filter { $0.responseStatusCode == code }
        }

        // Host filter
        if let host = filterHost, !host.isEmpty {
            result = result.filter { $0.host.contains(host) }
        }

        // Protocol filter
        if let proto = filterProtocol {
            result = result.filter { $0.sessionProtocol == proto }
        }

        // Errors only
        if showOnlyErrors {
            result = result.filter { $0.state == .error || ($0.responseStatusCode ?? 0) >= 400 }
        }

        // Content category
        if filterContentCategory != .all {
            result = result.filter { $0.contentCategory == filterContentCategory }
        }

        filteredSessions = result
    }

    // MARK: - Import

    /// Parses a JSON file produced by exportSessions() and appends the sessions.
    /// Returns the number of sessions imported.
    @discardableResult
    func importSessions(from data: Data) throws -> Int {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ImportError.invalidFormat
        }
        let fmt = ISO8601DateFormatter()
        var count = 0
        for dict in array {
            guard let method   = dict["method"]   as? String,
                  let host     = dict["host"]      as? String,
                  let path     = dict["path"]      as? String,
                  let protoRaw = dict["protocol"]  as? String else { continue }

            let proto     = ProxyProtocol(rawValue: protoRaw) ?? .https
            let reqHdrs   = dict["requestHeaders"]  as? [String: String] ?? [:]
            let respHdrs  = dict["responseHeaders"] as? [String: String] ?? [:]
            let timestamp = (dict["timestamp"] as? String).flatMap { fmt.date(from: $0) } ?? Date()

            let session = ProxySession(
                timestamp:       timestamp,
                sessionProtocol: proto,
                host:            host,
                path:            path,
                method:          method,
                requestHeaders:  reqHdrs,
                requestBody:     (dict["requestBody"]  as? String).flatMap { $0.data(using: .utf8) }
            )
            session.responseHeaders    = respHdrs
            session.responseStatusCode = dict["statusCode"] as? Int
            session.duration           = dict["duration"]   as? TimeInterval
            session.error              = dict["error"]      as? String
            session.responseBody       = (dict["responseBody"] as? String).flatMap { $0.data(using: .utf8) }
            if let stateRaw = dict["state"] as? String {
                session.state = SessionState(rawValue: stateRaw) ?? .complete
            } else {
                session.state = .complete
            }
            sessions.append(session)
            count += 1
        }
        applyFilters()
        return count
    }

    enum ImportError: LocalizedError {
        case invalidFormat
        var errorDescription: String? { "File is not a valid FlowProxy session export." }
    }

    // MARK: - Export

    func exportSessions() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let exportData = sessions.map { session -> [String: Any] in
            var dict: [String: Any] = [
                "id": session.id.uuidString,
                "timestamp": ISO8601DateFormatter().string(from: session.timestamp),
                "protocol": session.sessionProtocol.rawValue,
                "method": session.method,
                "host": session.host,
                "path": session.path,
                "url": session.fullURL,
                "state": session.state.rawValue,
                "requestHeaders": session.requestHeaders,
                "responseHeaders": session.responseHeaders
            ]
            if let code = session.responseStatusCode { dict["statusCode"] = code }
            if let dur = session.duration { dict["duration"] = dur }
            if let err = session.error { dict["error"] = err }
            if let body = session.requestBodyString { dict["requestBody"] = body }
            if let body = session.responseBodyString { dict["responseBody"] = body }
            return dict
        }

        if let data = try? JSONSerialization.data(withJSONObject: exportData, options: [.prettyPrinted]) {
            return data
        }
        return Data()
    }

    // MARK: - Statistics

    var totalCount: Int { sessions.count }

    var successCount: Int {
        sessions.filter { ($0.responseStatusCode ?? 0) >= 200 && ($0.responseStatusCode ?? 0) < 300 }.count
    }

    var errorCount: Int {
        sessions.filter { ($0.responseStatusCode ?? 0) >= 400 || $0.state == .error }.count
    }

    var averageDuration: TimeInterval? {
        let durations = sessions.compactMap { $0.duration }
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +) / Double(durations.count)
    }

    var availableMethods: [String] {
        Array(Set(sessions.map { $0.method })).sorted()
    }

    var availableHosts: [String] {
        Array(Set(sessions.map { $0.host })).sorted()
    }
}
