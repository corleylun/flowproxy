import Foundation

// MARK: - Parsed HTTP Request
struct ParsedHTTPRequest {
    var method: String
    var path: String
    var version: String
    var headers: [String: String]
    var body: Data
    var rawHeaders: [(String, String)]  // preserve order

    var isConnect: Bool { method.uppercased() == "CONNECT" }

    var host: String {
        headers["Host"] ?? headers["host"] ?? ""
    }

    var contentLength: Int? {
        if let v = headers["Content-Length"] ?? headers["content-length"] {
            return Int(v)
        }
        return nil
    }

    var isChunked: Bool {
        let te = headers["Transfer-Encoding"] ?? headers["transfer-encoding"] ?? ""
        return te.lowercased().contains("chunked")
    }
}

// MARK: - Parsed HTTP Response
struct ParsedHTTPResponse {
    var version: String
    var statusCode: Int
    var statusMessage: String
    var headers: [String: String]
    var body: Data
    var rawHeaders: [(String, String)]

    var contentLength: Int? {
        if let v = headers["Content-Length"] ?? headers["content-length"] {
            return Int(v)
        }
        return nil
    }

    var isChunked: Bool {
        let te = headers["Transfer-Encoding"] ?? headers["transfer-encoding"] ?? ""
        return te.lowercased().contains("chunked")
    }

    var contentType: String {
        headers["Content-Type"] ?? headers["content-type"] ?? ""
    }
}

// MARK: - Parse Error
enum HTTPParseError: Error, LocalizedError {
    case incomplete
    case malformed(String)
    case unsupportedTransferEncoding

    var errorDescription: String? {
        switch self {
        case .incomplete: return "Incomplete HTTP data"
        case .malformed(let msg): return "Malformed HTTP: \(msg)"
        case .unsupportedTransferEncoding: return "Unsupported Transfer-Encoding"
        }
    }
}

// MARK: - HTTP Parser
struct HTTPParser {

    // MARK: - Request Parsing

    /// Parse a complete HTTP request from raw bytes.
    /// Returns (parsed request, bytes consumed).
    static func parseRequest(_ data: Data) throws -> (ParsedHTTPRequest, Int) {
        guard let (headerSection, headerEnd) = splitHeadersAndBody(data) else {
            throw HTTPParseError.incomplete
        }

        let headerString = String(data: headerSection, encoding: .utf8) ?? ""
        var lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPParseError.malformed("Empty request") }

        // Parse request line
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            throw HTTPParseError.malformed("Bad request line: \(requestLine)")
        }

        let method = parts[0]
        let path = parts.count >= 2 ? parts[1] : "/"
        let version = parts.count >= 3 ? parts[2] : "HTTP/1.1"

        // Parse headers
        var headers: [String: String] = [:]
        var rawHeaders: [(String, String)] = []

        for line in lines where !line.isEmpty {
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
                rawHeaders.append((key, value))
            }
        }

        // Parse body
        let bodyStart = headerEnd
        let body: Data

        if method.uppercased() == "CONNECT" || method.uppercased() == "GET" || method.uppercased() == "HEAD" {
            body = Data()
        } else if let cl = headers["Content-Length"] ?? headers["content-length"], let length = Int(cl) {
            if data.count >= bodyStart + length {
                body = data.subdata(in: bodyStart..<(bodyStart + length))
            } else {
                throw HTTPParseError.incomplete
            }
        } else {
            let te = headers["Transfer-Encoding"] ?? headers["transfer-encoding"] ?? ""
            if te.lowercased().contains("chunked") {
                let (decoded, _) = try decodeChunked(data.subdata(in: bodyStart..<data.count))
                body = decoded
            } else {
                // No body indicators — take remaining bytes
                body = bodyStart < data.count ? data.subdata(in: bodyStart..<data.count) : Data()
            }
        }

        let totalConsumed = bodyStart + body.count
        let request = ParsedHTTPRequest(
            method: method,
            path: path,
            version: version,
            headers: headers,
            body: body,
            rawHeaders: rawHeaders
        )
        return (request, totalConsumed)
    }

    // MARK: - Response Parsing

    /// Parse a complete HTTP response from raw bytes.
    static func parseResponse(_ data: Data) throws -> (ParsedHTTPResponse, Int) {
        guard let (headerSection, headerEnd) = splitHeadersAndBody(data) else {
            throw HTTPParseError.incomplete
        }

        let headerString = String(data: headerSection, encoding: .utf8) ?? ""
        var lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPParseError.malformed("Empty response") }

        // Status line
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            throw HTTPParseError.malformed("Bad status line: \(statusLine)")
        }

        let version = parts[0]
        let statusCode = Int(parts[1]) ?? 0
        let statusMessage = parts.count >= 3 ? parts[2] : ""

        // Parse headers
        var headers: [String: String] = [:]
        var rawHeaders: [(String, String)] = []

        for line in lines where !line.isEmpty {
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
                rawHeaders.append((key, value))
            }
        }

        // Parse body
        let bodyStart = headerEnd
        let body: Data

        // No body for certain status codes
        if statusCode == 204 || statusCode == 304 || (statusCode >= 100 && statusCode < 200) {
            body = Data()
        } else if let cl = headers["Content-Length"] ?? headers["content-length"], let length = Int(cl) {
            if data.count >= bodyStart + length {
                body = data.subdata(in: bodyStart..<(bodyStart + length))
            } else {
                // Return what we have
                body = bodyStart < data.count ? data.subdata(in: bodyStart..<data.count) : Data()
            }
        } else {
            let te = headers["Transfer-Encoding"] ?? headers["transfer-encoding"] ?? ""
            if te.lowercased().contains("chunked") {
                let (decoded, _) = try decodeChunked(data.subdata(in: bodyStart..<data.count))
                body = decoded
            } else {
                // Read to end of stream
                body = bodyStart < data.count ? data.subdata(in: bodyStart..<data.count) : Data()
            }
        }

        let totalConsumed = bodyStart + body.count
        let response = ParsedHTTPResponse(
            version: version,
            statusCode: statusCode,
            statusMessage: statusMessage,
            headers: headers,
            body: body,
            rawHeaders: rawHeaders
        )
        return (response, totalConsumed)
    }

    // MARK: - Chunked Decoding

    static func decodeChunked(_ data: Data) throws -> (Data, Int) {
        var result = Data()
        var offset = 0

        while offset < data.count {
            // Find chunk size line end
            guard let lineEnd = findCRLF(in: data, from: offset) else {
                break
            }

            let sizeLine = String(data: data.subdata(in: offset..<lineEnd), encoding: .utf8) ?? ""
            let sizeStr = sizeLine.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let chunkSize = Int(sizeStr, radix: 16) else {
                throw HTTPParseError.malformed("Bad chunk size: \(sizeLine)")
            }

            offset = lineEnd + 2 // skip CRLF

            if chunkSize == 0 {
                offset += 2 // final CRLF
                break
            }

            guard offset + chunkSize <= data.count else {
                throw HTTPParseError.incomplete
            }

            result.append(data.subdata(in: offset..<(offset + chunkSize)))
            offset += chunkSize + 2 // skip trailing CRLF
        }

        return (result, offset)
    }

    // MARK: - Helpers

    /// Find \r\n in data starting at offset
    private static func findCRLF(in data: Data, from offset: Int) -> Int? {
        let bytes = [UInt8](data)
        for i in offset..<(bytes.count - 1) {
            if bytes[i] == 0x0D && bytes[i+1] == 0x0A {
                return i
            }
        }
        return nil
    }

    /// Split header section from body. Returns (headerBytes, bodyStartIndex)
    static func splitHeadersAndBody(_ data: Data) -> (Data, Int)? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }

        for i in 0..<(bytes.count - 3) {
            if bytes[i] == separator[0] && bytes[i+1] == separator[1] &&
               bytes[i+2] == separator[2] && bytes[i+3] == separator[3] {
                let headerData = data.subdata(in: 0..<i)
                return (headerData, i + 4)
            }
        }
        return nil
    }

    // MARK: - Request Serialization

    /// Serialize a request back to bytes (for forwarding)
    static func serializeRequest(method: String, path: String, version: String,
                                  headers: [String: String], body: Data?) -> Data {
        var lines: [String] = ["\(method) \(path) \(version)"]
        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }
        lines.append("\r\n")
        var result = lines.joined(separator: "\r\n").data(using: .utf8) ?? Data()
        if let b = body, !b.isEmpty {
            result.append(b)
        }
        return result
    }

    /// Serialize response back to bytes
    static func serializeResponse(version: String, statusCode: Int, statusMessage: String,
                                   headers: [String: String], body: Data?) -> Data {
        var lines: [String] = ["\(version) \(statusCode) \(statusMessage)"]
        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }
        lines.append("\r\n")
        var result = lines.joined(separator: "\r\n").data(using: .utf8) ?? Data()
        if let b = body, !b.isEmpty {
            result.append(b)
        }
        return result
    }

    // MARK: - URL Parsing

    static func parseHostPort(_ hostPort: String, defaultPort: Int = 80) -> (String, Int) {
        if hostPort.hasPrefix("[") {
            // IPv6
            if let closeBracket = hostPort.firstIndex(of: "]") {
                let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closeBracket])
                let after = hostPort[hostPort.index(after: closeBracket)...]
                if after.hasPrefix(":"), let port = Int(after.dropFirst()) {
                    return (host, port)
                }
                return (host, defaultPort)
            }
        }
        let parts = hostPort.split(separator: ":", maxSplits: 1)
        if parts.count == 2, let port = Int(parts[1]) {
            return (String(parts[0]), port)
        }
        return (hostPort, defaultPort)
    }
}
