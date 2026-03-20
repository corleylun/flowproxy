import Foundation
import Security

// MARK: - Proxy Server Error
enum ProxyServerError: Error, LocalizedError {
    case alreadyRunning
    case socketFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:       return "Proxy server is already running"
        case .socketFailed(let m):  return "Socket error: \(m)"
        }
    }
}

// MARK: - Proxy Server
actor ProxyServer {

    private(set) var isRunning = false
    private var serverFd: Int32 = -1
    private let caManager: CertificateAuthorityManager

    var onNewSession:    ((ProxySession) -> Void)?
    var onUpdateSession: ((ProxySession) -> Void)?

    private let acceptQueue = DispatchQueue(label: "com.flowproxy.accept", qos: .userInitiated)

    init(caManager: CertificateAuthorityManager) {
        self.caManager = caManager
    }

    // MARK: - Start

    func start(port: UInt16) async throws {
        guard !isRunning else { throw ProxyServerError.alreadyRunning }

        do { try await caManager.initialize() } catch {
            print("[ProxyServer] CA init failed: \(error) — HTTPS interception disabled")
        }

        // Prevent SIGPIPE from terminating the process when writing to a closed socket
        signal(SIGPIPE, SIG_IGN)

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyServerError.socketFailed("socket() errno \(Darwin.errno)") }

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw ProxyServerError.socketFailed("bind() errno \(Darwin.errno)")
        }
        guard Darwin.listen(fd, 128) == 0 else {
            Darwin.close(fd)
            throw ProxyServerError.socketFailed("listen() errno \(Darwin.errno)")
        }

        serverFd  = fd
        isRunning = true
        print("[ProxyServer] Listening on port \(port)")

        let onNew    = onNewSession
        let onUpdate = onUpdateSession
        let ca       = caManager

        acceptQueue.async {
            while true {
                let clientFd = Darwin.accept(fd, nil, nil)
                if clientFd < 0 { break }
                // Suppress SIGPIPE on this socket (browser may close while we're writing)
                var noSigPipe: Int32 = 1
                setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global(qos: .userInitiated).async {
                    ConnectionHandler(fd: clientFd,
                                      caManager: ca,
                                      onNewSession: onNew,
                                      onUpdateSession: onUpdate).handle()
                }
            }
        }
    }

    // MARK: - Stop

    func stop() {
        if serverFd >= 0 { Darwin.close(serverFd); serverFd = -1 }
        isRunning = false
        print("[ProxyServer] Stopped")
    }
}

// MARK: - Connection Handler

final class ConnectionHandler {
    private let fd: Int32
    private let caManager: CertificateAuthorityManager
    private let onNewSession:    ((ProxySession) -> Void)?
    private let onUpdateSession: ((ProxySession) -> Void)?

    init(fd: Int32,
         caManager: CertificateAuthorityManager,
         onNewSession:    ((ProxySession) -> Void)?,
         onUpdateSession: ((ProxySession) -> Void)?) {
        self.fd              = fd
        self.caManager       = caManager
        self.onNewSession    = onNewSession
        self.onUpdateSession = onUpdateSession
    }

    func handle() {
        defer { Darwin.close(fd) }

        var buf = [UInt8](repeating: 0, count: 8192)
        let n = Darwin.recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return }
        let data = Data(buf[0..<n])

        guard let (request, _) = try? HTTPParser.parseRequest(data) else {
            fdSendString(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return
        }

        if request.isConnect {
            handleCONNECT(request: request)
        } else {
            handleHTTP(request: request)
        }
    }

    // MARK: - CONNECT / HTTPS MITM

    private func handleCONNECT(request: ParsedHTTPRequest) {
        let (host, port) = HTTPParser.parseHostPort(request.path, defaultPort: 443)

        // Try to obtain a TLS identity for this host
        guard let identity = syncGetIdentity(for: host) else {
            // CA not ready — fall back to raw tunnel
            rawTunnel(host: host, port: port)
            return
        }

        guard fdSendString(fd, "HTTP/1.1 200 Connection Established\r\n\r\n") else { return }

        let caCert = syncGetCACert()
        MITMHandler(clientFd: fd, host: host, port: port, identity: identity, caCert: caCert,
                    onNewSession: onNewSession, onUpdateSession: onUpdateSession).perform()
    }

    private func syncGetIdentity(for host: String) -> SecIdentity? {
        let sem = DispatchSemaphore(value: 0)
        var result: SecIdentity?
        Task {
            result = try? await caManager.getIdentity(for: host)
            sem.signal()
        }
        sem.wait()
        return result
    }

    private func syncGetCACert() -> SecCertificate? {
        let sem = DispatchSemaphore(value: 0)
        var result: SecCertificate?
        Task {
            result = await caManager.getCACertificate()
            sem.signal()
        }
        sem.wait()
        return result
    }

    // MARK: - Raw Tunnel (CA not available)

    private func rawTunnel(host: String, port: Int) {
        guard let upFd = posixConnect(host: host, port: port) else {
            fdSendString(fd, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
            return
        }
        defer { Darwin.close(upFd) }
        fdSendString(fd, "HTTP/1.1 200 Connection Established\r\n\r\n")

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            posixRelay(from: self.fd, to: upFd)
            group.leave()
        }
        posixRelay(from: upFd, to: fd)
        group.wait()
    }

    // MARK: - Plain HTTP via URLSession

    private func handleHTTP(request: ParsedHTTPRequest) {
        let startTime = Date()
        let session = ProxySession(
            sessionProtocol: .http,
            host:            request.host,
            path:            request.path,
            method:          request.method,
            requestHeaders:  request.headers,
            requestBody:     request.body.isEmpty ? nil : request.body
        )
        session.timing = TimingInfo()
        session.timing?.connectStart = startTime
        onNewSession?(session)

        var host = request.host
        var port = 80
        var path = request.path

        if path.hasPrefix("http://"), let url = URL(string: path) {
            host = url.host ?? host
            port = url.port ?? 80
            path = url.path.isEmpty ? "/" : url.path
            if let q = url.query { path += "?\(q)" }
            session.host = host
            session.path = path
        } else {
            let hp = HTTPParser.parseHostPort(host, defaultPort: 80)
            host = hp.0; port = hp.1
        }

        let urlString = "http://\(host):\(port)\(path)"
        guard let url = URL(string: urlString) else {
            session.state = .error; session.error = "Invalid URL"
            onUpdateSession?(session); return
        }

        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = request.method
        let skipHeaders: Set<String> = ["Host", "host",
                                        "Proxy-Connection", "proxy-connection",
                                        "Proxy-Authorization", "proxy-authorization",
                                        "Connection", "connection",
                                        "Keep-Alive", "keep-alive",
                                        "Transfer-Encoding", "transfer-encoding",
                                        "TE", "te", "Upgrade", "upgrade", "Trailers", "trailers",
                                        "Accept-Encoding", "accept-encoding"]
        for (k, v) in request.headers where !skipHeaders.contains(k) {
            urlReq.setValue(v, forHTTPHeaderField: k)
        }
        if !request.body.isEmpty { urlReq.httpBody = request.body }

        session.timing?.requestSent = Date()
        let (respData, httpResp) = syncURLRequest(urlReq)
        session.timing?.firstByte   = Date()
        session.timing?.responseEnd = Date()

        if let resp = httpResp {
            session.responseStatusCode = resp.statusCode
            session.responseBody       = respData
            session.responseHeaders    = resp.allHeaderFields.reduce(into: [:]) { d, p in
                if let k = p.key as? String, let v = p.value as? String { d[k] = v }
            }
            session.state = .complete

            let body = respData ?? Data()
            var text = "HTTP/1.1 \(resp.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: resp.statusCode))\r\n"
            for (k, v) in resp.allHeaderFields {
                let key = (k as? String ?? "\(k)").lowercased()
                if key == "transfer-encoding" || key == "content-encoding" || key == "content-length" { continue }
                text += "\(k): \(v)\r\n"
            }
            text += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var responseBytes = text.data(using: .utf8)!
            responseBytes.append(body)
            fdSendData(fd, responseBytes)
        } else {
            session.state = .error
            session.error = "Upstream request failed"
            fdSendString(fd, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        }

        session.duration = Date().timeIntervalSince(startTime)
        onUpdateSession?(session)
    }
}

// MARK: - Sync URL helper (shared)

func syncURLRequest(_ req: URLRequest) -> (Data?, HTTPURLResponse?) {
    let sem = DispatchSemaphore(value: 0)
    var respData: Data?
    var httpResp: HTTPURLResponse?
    let cfg = URLSessionConfiguration.ephemeral
    cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    cfg.connectionProxyDictionary = [:]  // never route upstream requests back through ourself
    URLSession(configuration: cfg).dataTask(with: req) { d, r, _ in
        respData = d; httpResp = r as? HTTPURLResponse; sem.signal()
    }.resume()
    sem.wait()
    return (respData, httpResp)
}

// MARK: - POSIX utilities

func posixConnect(host: String, port: Int) -> Int32? {
    var hints = addrinfo()
    hints.ai_family   = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var info: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &info) == 0, let info = info else { return nil }
    defer { freeaddrinfo(info) }
    let upFd = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
    guard upFd >= 0 else { return nil }
    guard Darwin.connect(upFd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
        Darwin.close(upFd); return nil
    }
    return upFd
}

func posixRelay(from srcFd: Int32, to dstFd: Int32) {
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = Darwin.recv(srcFd, &buf, buf.count, 0)
        if n <= 0 { break }
        buf.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            while sent < n {
                let s = Darwin.send(dstFd, base.advanced(by: sent), n - sent, 0)
                if s <= 0 { return }
                sent += s
            }
        }
    }
}

@discardableResult
func fdSendString(_ fd: Int32, _ s: String) -> Bool {
    guard let d = s.data(using: .utf8) else { return false }
    return fdSendData(fd, d)
}

@discardableResult
func fdSendData(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { ptr -> Bool in
        guard let base = ptr.baseAddress else { return false }
        var sent = 0
        while sent < data.count {
            let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}
