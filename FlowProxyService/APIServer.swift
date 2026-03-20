import Foundation
import Darwin

// MARK: - JSON helpers (free functions, not actor-isolated)

private func encodeJSON<T: Encodable>(_ value: T) -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? enc.encode(value)) ?? Data("{}".utf8)
}

private func errorBody(code: String, message: String) -> Data {
    struct E: Encodable {
        struct Inner: Encodable { let code, message: String }
        let error: Inner
    }
    return encodeJSON(E(error: .init(code: code, message: message)))
}

private func sendJSON(_ fd: Int32, status: Int, body: Data) {
    let text: String
    switch status {
    case 200: text = "OK"
    case 400: text = "Bad Request"
    case 404: text = "Not Found"
    case 500: text = "Internal Server Error"
    default:  text = "Unknown"
    }
    let hdr = "HTTP/1.1 \(status) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    var response = hdr.data(using: .utf8)!
    response.append(body)
    fdSendData(fd, response)
}

// MARK: - DTOs

struct SessionListDTO: Encodable {
    let sessions: [SessionSummaryDTO]
    let count: Int
}

struct SessionSummaryDTO: Encodable {
    let id: String
    let timestamp: String
    let method: String
    let host: String
    let path: String
    let url: String
    let `protocol`: String
    let status: Int?
    let duration_ms: Int?
    let state: String
    let error: String?

    init(_ s: ProxySession) {
        id           = s.id.uuidString
        timestamp    = ISO8601DateFormatter().string(from: s.timestamp)
        method       = s.method
        host         = s.host
        path         = s.path
        url          = s.fullURL
        `protocol`   = s.sessionProtocol.rawValue
        status       = s.responseStatusCode
        duration_ms  = s.duration.map { Int($0 * 1000) }
        state        = s.state.rawValue
        error        = s.error
    }
}

struct SessionDetailDTO: Encodable {
    let id: String
    let timestamp: String
    let method: String
    let host: String
    let path: String
    let url: String
    let `protocol`: String
    let status: Int?
    let duration_ms: Int?
    let state: String
    let requestHeaders: [String: String]
    let responseHeaders: [String: String]
    let requestBody: String?
    let responseBody: String?
    let error: String?

    init(_ s: ProxySession) {
        id              = s.id.uuidString
        timestamp       = ISO8601DateFormatter().string(from: s.timestamp)
        method          = s.method
        host            = s.host
        path            = s.path
        url             = s.fullURL
        `protocol`      = s.sessionProtocol.rawValue
        status          = s.responseStatusCode
        duration_ms     = s.duration.map { Int($0 * 1000) }
        state           = s.state.rawValue
        requestHeaders  = s.requestHeaders
        responseHeaders = s.responseHeaders
        requestBody     = s.requestBody.flatMap  { String(data: $0, encoding: .utf8) }
        responseBody    = s.responseBody.flatMap { String(data: $0, encoding: .utf8) }
        error           = s.error
    }
}

struct RuleDTO: Encodable {
    let id: String
    let name: String
    let localPort: Int
    let upstreamURL: String
    let isEnabled: Bool

    init(_ r: ReverseProxyRule) {
        id          = r.id.uuidString
        name        = r.name
        localPort   = r.localPort
        upstreamURL = r.upstreamURL.absoluteString
        isEnabled   = r.isEnabled
    }
}

// MARK: - ProxyServer callback helper (service target only)

extension ProxyServer {
    func configureCallbacks(
        onNew: @escaping (ProxySession) -> Void,
        onUpdate: @escaping (ProxySession) -> Void
    ) {
        self.onNewSession    = onNew
        self.onUpdateSession = onUpdate
    }
}

// MARK: - APIServer

actor APIServer {

    private let store: ServiceStore
    private var proxyServer: ProxyServer?
    private var reverseProxyManager = ReverseProxyManager()
    private let caManager = CertificateAuthorityManager.shared
    private var currentProxyPort: UInt16 = 8888
    private var serverFd: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "com.flowproxy.api.accept", qos: .userInitiated)
    private(set) var listeningPort: UInt16 = 0

    init(store: ServiceStore) {
        self.store = store
    }

    // MARK: - Start

    func start() async throws {
        await store.loadRules()
        signal(SIGPIPE, SIG_IGN)
        let (fd, port) = try bindSocket()
        serverFd = fd
        listeningPort = port
        writePortFile(port)
        print("[APIServer] Listening on 127.0.0.1:\(port)")

        let capturedSelf = self
        acceptQueue.async {
            while true {
                let clientFd = Darwin.accept(fd, nil, nil)
                if clientFd < 0 { break }
                var noSigPipe: Int32 = 1
                setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                           socklen_t(MemoryLayout<Int32>.size))
                Task { await capturedSelf.handleConnection(clientFd) }
            }
        }
    }

    func shutdown() {
        if serverFd >= 0 { Darwin.close(serverFd); serverFd = -1 }
        removePortFile()
        let mgr = reverseProxyManager
        Task { await mgr.stopAll() }
        if let srv = proxyServer { Task { await srv.stop() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }

    // MARK: - Socket binding

    private func bindSocket() throws -> (Int32, UInt16) {
        for port: UInt16 in 7878..<7900 {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var opt: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family      = sa_family_t(AF_INET)
            addr.sin_port        = port.bigEndian
            addr.sin_addr.s_addr = Darwin.inet_addr("127.0.0.1")
            addr.sin_len         = UInt8(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            if bound && Darwin.listen(fd, 32) == 0 { return (fd, port) }
            Darwin.close(fd)
        }
        throw NSError(domain: "APIServer", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "No available port in range 7878–7900"])
    }

    // MARK: - Connection handling

    private func handleConnection(_ fd: Int32) async {
        defer { Darwin.close(fd) }
        guard let data = readFullRequest(fd: fd), !data.isEmpty else { return }
        guard let (req, _) = try? HTTPParser.parseRequest(data) else {
            sendJSON(fd, status: 400, body: errorBody(code: "bad_request", message: "Invalid HTTP request"))
            return
        }
        await route(req, fd: fd)
    }

    /// Reads a complete HTTP request: headers first, then body up to Content-Length.
    private func readFullRequest(fd: Int32) -> Data? {
        var data = Data()
        var buf  = [UInt8](repeating: 0, count: 4096)

        // Phase 1 — accumulate until \r\n\r\n is present
        while HTTPParser.splitHeadersAndBody(data) == nil {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            guard n > 0 else { return data.isEmpty ? nil : data }
            data.append(contentsOf: buf[0..<n])
        }

        // Phase 2 — read body bytes up to Content-Length
        guard let (headerData, bodyStart) = HTTPParser.splitHeadersAndBody(data) else { return data }
        let headerStr = String(data: headerData, encoding: .utf8) ?? ""
        var contentLength = 0
        for line in headerStr.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)) ?? 0
                break
            }
        }

        var needed = contentLength - (data.count - bodyStart)
        while needed > 0 {
            let n = Darwin.recv(fd, &buf, min(needed, buf.count), 0)
            guard n > 0 else { break }
            data.append(contentsOf: buf[0..<n])
            needed -= n
        }
        return data
    }

    // MARK: - Routing

    private func route(_ req: ParsedHTTPRequest, fd: Int32) async {
        let fullPath = req.path
        let path     = fullPath.components(separatedBy: "?").first ?? fullPath
        let method   = req.method.uppercased()

        switch (method, path) {

        // Proxy
        case ("GET",  "/proxy/status"): await routeProxyStatus(fd: fd)
        case ("POST", "/proxy/start"):  await routeProxyStart(req, fd: fd)
        case ("POST", "/proxy/stop"):   await routeProxyStop(fd: fd)

        // Sessions
        case ("GET",    "/sessions"):   await routeSessionsList(fullPath, fd: fd)
        case ("DELETE", "/sessions"):   await routeSessionsClear(fd: fd)
        case ("GET", _) where path.hasPrefix("/sessions/") && !path.hasSuffix("/replay"):
            await routeSessionGet(id: String(path.dropFirst("/sessions/".count)), fd: fd)
        case ("POST", _) where path.hasPrefix("/sessions/") && path.hasSuffix("/replay"):
            let mid = String(path.dropFirst("/sessions/".count).dropLast("/replay".count))
            await routeSessionReplay(id: mid, req: req, fd: fd)

        // Reverse proxy
        case ("GET",    "/reverse-proxy"):  await routeReverseProxyList(fd: fd)
        case ("POST",   "/reverse-proxy"):  await routeReverseProxyAdd(req, fd: fd)
        case ("DELETE", _) where path.hasPrefix("/reverse-proxy/"):
            await routeReverseProxyRemove(id: String(path.dropFirst("/reverse-proxy/".count)), fd: fd)

        // Shutdown
        case ("POST", "/shutdown"):
            sendJSON(fd, status: 200, body: encodeJSON(["ok": true]))
            shutdown()

        default:
            sendJSON(fd, status: 404, body: errorBody(code: "not_found",
                                                       message: "Unknown endpoint: \(method) \(path)"))
        }
    }

    // MARK: - Proxy routes

    private func routeProxyStatus(fd: Int32) async {
        struct S: Encodable { let running: Bool; let port: UInt16 }
        let running = await proxyServer?.isRunning ?? false
        sendJSON(fd, status: 200, body: encodeJSON(S(running: running, port: currentProxyPort)))
    }

    private func routeProxyStart(_ req: ParsedHTTPRequest, fd: Int32) async {
        struct Body: Decodable { var port: UInt16?; var httpsIntercept: Bool? }
        let body = req.body.isEmpty ? Body() :
            ((try? JSONDecoder().decode(Body.self, from: req.body)) ?? Body())
        let port = body.port ?? currentProxyPort

        if let server = proxyServer, await server.isRunning {
            struct S: Encodable { let running: Bool; let port: UInt16; let message: String }
            sendJSON(fd, status: 200, body: encodeJSON(
                S(running: true, port: currentProxyPort, message: "Proxy already running")))
            return
        }
        do {
            try await startProxy(port: port)
            struct S: Encodable { let running: Bool; let port: UInt16 }
            sendJSON(fd, status: 200, body: encodeJSON(S(running: true, port: port)))
        } catch {
            sendJSON(fd, status: 500,
                     body: errorBody(code: "start_failed", message: error.localizedDescription))
        }
    }

    private func routeProxyStop(fd: Int32) async {
        await stopProxy()
        struct S: Encodable { let running: Bool }
        sendJSON(fd, status: 200, body: encodeJSON(S(running: false)))
    }

    // MARK: - Session routes

    private func routeSessionsList(_ fullPath: String, fd: Int32) async {
        let params   = parseQuery(fullPath)
        let sessions = await store.filtered(
            limit:  params["limit"].flatMap(Int.init),
            host:   params["host"],
            method: params["method"],
            status: params["status"].flatMap(Int.init),
            search: params["search"]
        )
        sendJSON(fd, status: 200, body: encodeJSON(
            SessionListDTO(sessions: sessions.map(SessionSummaryDTO.init), count: sessions.count)
        ))
    }

    private func routeSessionGet(id: String, fd: Int32) async {
        guard let uuid    = UUID(uuidString: id),
              let session = await store.get(id: uuid) else {
            sendJSON(fd, status: 404,
                     body: errorBody(code: "not_found", message: "Session \(id) not found"))
            return
        }
        sendJSON(fd, status: 200, body: encodeJSON(SessionDetailDTO(session)))
    }

    private func routeSessionsClear(fd: Int32) async {
        await store.clear()
        struct R: Encodable { let cleared: Bool }
        sendJSON(fd, status: 200, body: encodeJSON(R(cleared: true)))
    }

    private func routeSessionReplay(id: String, req: ParsedHTTPRequest, fd: Int32) async {
        guard let uuid    = UUID(uuidString: id),
              let session = await store.get(id: uuid) else {
            sendJSON(fd, status: 404,
                     body: errorBody(code: "not_found", message: "Session \(id) not found"))
            return
        }

        struct ReplayBody: Decodable {
            var method: String?
            var headers: [String: String]?
            var body: String?
        }
        let overrides = req.body.isEmpty ? ReplayBody() :
            ((try? JSONDecoder().decode(ReplayBody.self, from: req.body)) ?? ReplayBody())

        guard let url = URL(string: session.fullURL) else {
            sendJSON(fd, status: 400,
                     body: errorBody(code: "invalid_url", message: "Session URL is invalid"))
            return
        }

        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = overrides.method ?? session.method
        var headers = session.requestHeaders
        overrides.headers?.forEach { headers[$0.key] = $0.value }
        headers.forEach { urlReq.setValue($1, forHTTPHeaderField: $0) }
        urlReq.httpBody = overrides.body.flatMap { $0.data(using: .utf8) } ?? session.requestBody

        let start = Date()
        let (respData, httpResp) = syncURLRequest(urlReq)
        let duration = Date().timeIntervalSince(start)

        let newSession = ProxySession(
            sessionProtocol: session.sessionProtocol,
            host:            session.host,
            path:            session.path,
            method:          urlReq.httpMethod ?? session.method,
            requestHeaders:  headers,
            requestBody:     urlReq.httpBody
        )
        newSession.responseStatusCode = httpResp?.statusCode
        newSession.responseBody       = respData
        newSession.responseHeaders    = httpResp?.allHeaderFields.reduce(into: [String: String]()) {
            if let k = $1.key as? String, let v = $1.value as? String { $0[k] = v }
        } ?? [:]
        newSession.duration = duration
        newSession.state    = httpResp != nil ? .complete : .error
        newSession.error    = httpResp == nil ? "Replay request failed" : nil

        await store.add(newSession)
        sendJSON(fd, status: 200, body: encodeJSON(SessionDetailDTO(newSession)))
    }

    // MARK: - Reverse proxy routes

    private func routeReverseProxyList(fd: Int32) async {
        let rules = await store.reverseProxyRules
        struct R: Encodable { let rules: [RuleDTO]; let count: Int }
        sendJSON(fd, status: 200, body: encodeJSON(R(rules: rules.map(RuleDTO.init), count: rules.count)))
    }

    private func routeReverseProxyAdd(_ req: ParsedHTTPRequest, fd: Int32) async {
        struct AddBody: Decodable { var name: String; var localPort: Int; var upstreamURL: String }
        guard !req.body.isEmpty,
              let body = try? JSONDecoder().decode(AddBody.self, from: req.body),
              let url  = URL(string: body.upstreamURL) else {
            sendJSON(fd, status: 400, body: errorBody(code: "invalid_body",
                message: "Required: name (string), localPort (int), upstreamURL (string)"))
            return
        }
        let rule = ReverseProxyRule(name: body.name, localPort: body.localPort, upstreamURL: url)
        await store.addRule(rule)
        if let server = proxyServer, await server.isRunning {
            try? await reverseProxyManager.startRule(rule)
        }
        sendJSON(fd, status: 200, body: encodeJSON(RuleDTO(rule)))
    }

    private func routeReverseProxyRemove(id: String, fd: Int32) async {
        guard let uuid = UUID(uuidString: id) else {
            sendJSON(fd, status: 400,
                     body: errorBody(code: "invalid_id", message: "Invalid UUID: \(id)"))
            return
        }
        let rules = await store.reverseProxyRules
        guard let rule = rules.first(where: { $0.id == uuid }) else {
            sendJSON(fd, status: 404,
                     body: errorBody(code: "not_found", message: "Rule \(id) not found"))
            return
        }
        await reverseProxyManager.stopRule(rule)
        await store.removeRule(id: uuid)
        struct R: Encodable { let removed: Bool }
        sendJSON(fd, status: 200, body: encodeJSON(R(removed: true)))
    }

    // MARK: - Internal proxy lifecycle

    private func startProxy(port: UInt16) async throws {
        let server = ProxyServer(caManager: caManager)
        proxyServer      = server
        currentProxyPort = port
        let capturedStore = store
        await server.configureCallbacks(
            onNew:    { s in Task { await capturedStore.add(s) } },
            onUpdate: { s in Task { await capturedStore.update(s) } }
        )
        try await server.start(port: port)
        let rules = await store.reverseProxyRules
        for rule in rules where rule.isEnabled {
            try? await reverseProxyManager.startRule(rule)
        }
    }

    private func stopProxy() async {
        if let server = proxyServer { await server.stop(); proxyServer = nil }
        await reverseProxyManager.stopAll()
    }

    // MARK: - Query string parsing

    private func parseQuery(_ path: String) -> [String: String] {
        guard let qIdx = path.firstIndex(of: "?") else { return [:] }
        let qs = String(path[path.index(after: qIdx)...])
        var params: [String: String] = [:]
        for pair in qs.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 { params[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        return params
    }

    // MARK: - Port file

    private func writePortFile(_ port: UInt16) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".flowproxy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(port)".write(to: dir.appendingPathComponent("service.port"),
                             atomically: true, encoding: .utf8)
    }

    private func removePortFile() {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".flowproxy/service.port")
        try? FileManager.default.removeItem(at: file)
    }
}
