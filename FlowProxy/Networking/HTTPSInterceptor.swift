import Foundation
import Security

// MARK: - SSLContext I/O Callbacks
// Must be top-level (non-private) C-compatible functions — no captures allowed.
// SSLConnection is an UnsafeMutablePointer<Int32> storing the client socket fd.

func sslReadCB(_ connection: SSLConnectionRef,
               _ data: UnsafeMutableRawPointer,
               _ dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = connection.assumingMemoryBound(to: Int32.self).pointee
    let n  = Darwin.recv(fd, data, dataLength.pointee, 0)
    if n > 0  { dataLength.pointee = n; return errSecSuccess }
    if n == 0 { dataLength.pointee = 0; return errSSLClosedGraceful }
    dataLength.pointee = 0
    return Darwin.errno == EAGAIN ? errSSLWouldBlock : errSecIO
}

func sslWriteCB(_ connection: SSLConnectionRef,
                _ data: UnsafeRawPointer,
                _ dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = connection.assumingMemoryBound(to: Int32.self).pointee
    let n  = Darwin.send(fd, data, dataLength.pointee, 0)
    if n >= 0 { dataLength.pointee = n; return errSecSuccess }
    dataLength.pointee = 0
    return Darwin.errno == EAGAIN ? errSSLWouldBlock : errSecIO
}

// MARK: - MITM Handler

final class MITMHandler {
    private let clientFd: Int32
    private let host:     String
    private let port:     Int
    private let identity: SecIdentity
    private let caCert:   SecCertificate?
    private let onNewSession:    ((ProxySession) -> Void)?
    private let onUpdateSession: ((ProxySession) -> Void)?

    init(clientFd: Int32, host: String, port: Int, identity: SecIdentity, caCert: SecCertificate?,
         onNewSession:    ((ProxySession) -> Void)?,
         onUpdateSession: ((ProxySession) -> Void)?) {
        self.clientFd        = clientFd
        self.host            = host
        self.port            = port
        self.identity        = identity
        self.caCert          = caCert
        self.onNewSession    = onNewSession
        self.onUpdateSession = onUpdateSession
    }

    // MARK: - Perform MITM

    func perform() {
        // Stable memory for the fd used by the SSL I/O callbacks
        let fdPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        fdPtr.initialize(to: clientFd)
        defer { fdPtr.deallocate() }

        guard let sslCtx = SSLCreateContext(nil, .serverSide, .streamType) else {
            print("[MITM] SSLCreateContext returned nil for \(host)")
            return
        }

        let ioSt   = SSLSetIOFuncs(sslCtx, sslReadCB, sslWriteCB)
        let connSt = SSLSetConnection(sslCtx, fdPtr)

        // Build certificate array: [identity, leafCert, caCert]
        // SSLSetCertificate expects: identity first, then chain certs in order.
        // Including the CA cert lets clients verify the chain without pre-importing it.
        var certSt: OSStatus = errSecParam
        var leafCert: SecCertificate?
        if SecIdentityCopyCertificate(identity, &leafCert) == errSecSuccess {
            var arr: [Any] = [identity, leafCert!]
            if let ca = caCert { arr.append(ca) }
            certSt = SSLSetCertificate(sslCtx, arr as CFArray)
        } else {
            let arr: NSArray = [identity]
            certSt = SSLSetCertificate(sslCtx, arr as CFArray)
        }

        let alpnSt = SSLSetALPNProtocols(sslCtx, ["http/1.1"] as CFArray)
        print("[MITM] Setup for \(host) — io:\(ioSt) conn:\(connSt) cert:\(certSt) alpn:\(alpnSt) fd:\(clientFd)")

        // TLS handshake with the browser
        var status: OSStatus
        repeat { status = SSLHandshake(sslCtx) } while status == errSSLWouldBlock
        guard status == errSecSuccess else {
            print("[MITM] TLS handshake failed for \(host): \(status) errno:\(Darwin.errno)")
            SSLClose(sslCtx)
            return
        }
        print("[MITM] TLS handshake succeeded for \(host)")

        // HTTP/1.1 keep-alive request loop
        var buf        = Data()
        var firstReq   = true

        while true {
            // Read a chunk of decrypted data from the browser
            var chunk     = [UInt8](repeating: 0, count: 65536)
            var processed = 0
            let readSt    = SSLRead(sslCtx, &chunk, chunk.count, &processed)

            if processed > 0 { buf.append(Data(chunk[0..<processed])) }

            let closed = readSt == errSSLClosedGraceful || readSt == errSSLClosedAbort
            let error  = readSt != errSecSuccess && readSt != errSSLWouldBlock && readSt != errSSLClosedGraceful
            if (closed || error) && processed == 0 { break }
            if buf.count > 2_097_152 { break }     // 2 MB safety limit

            // Attempt to parse a complete HTTP/1.1 request from the buffer
            guard let (request, consumed) = try? HTTPParser.parseRequest(buf) else {
                if closed { break }
                continue   // need more data
            }
            buf = consumed < buf.count ? Data(buf[consumed...]) : Data()

            // Build a ProxySession for this request
            let session = firstReq
                ? ProxySession(sessionProtocol: .https, host: host, path: request.path,
                               method: request.method, requestHeaders: request.headers,
                               requestBody: request.body.isEmpty ? nil : request.body)
                : ProxySession(sessionProtocol: .https, host: host, path: request.path,
                               method: request.method, requestHeaders: request.headers,
                               requestBody: request.body.isEmpty ? nil : request.body)
            firstReq = false
            session.timing = TimingInfo()
            session.timing?.connectStart  = Date()
            session.timing?.connectEnd    = Date()
            session.timing?.requestSent   = Date()
            onNewSession?(session)

            // Forward the request to the real server via URLSession
            let scheme    = port == 443 ? "https" : "http"
            let urlString = "\(scheme)://\(host)\(request.path)"
            guard let url = URL(string: urlString) else {
                sslSend(sslCtx, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                session.state = .error; onUpdateSession?(session); break
            }

            var urlReq = URLRequest(url: url)
            urlReq.httpMethod = request.method
            // Hop-by-hop headers must not be forwarded. Host is omitted so URLSession
            // derives it from the URL — this ensures it stays correct across redirects
            // (e.g. microsoft.com → www.microsoft.com would break with a stale Host).
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
                if let start = session.timing?.connectStart {
                    session.duration = Date().timeIntervalSince(start)
                }
                onUpdateSession?(session)

                // Send HTTP/1.1 response back through the TLS tunnel
                let body = respData ?? Data()
                var text = "HTTP/1.1 \(resp.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: resp.statusCode))\r\n"
                // Forward upstream response headers.
                // Skip transfer-encoding (we reassemble with Content-Length) and
                // content-encoding (URLSession already decoded the body, so the
                // raw bytes are uncompressed — forwarding the header would make
                // Firefox try to decompress again and fail).
                for (k, v) in resp.allHeaderFields {
                    let key = (k as? String) ?? "\(k)"
                    switch key.lowercased() {
                    case "transfer-encoding", "content-encoding", "content-length": continue
                    default: break
                    }
                    text += "\(key): \(v)\r\n"
                }
                text += "Content-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n"
                var responseBytes = text.data(using: .utf8)!
                responseBytes.append(body)
                sslSend(sslCtx, responseBytes)

                let connHeader = (request.headers["Connection"] ??
                                  request.headers["connection"] ?? "").lowercased()
                if connHeader == "close" { break }
            } else {
                sslSend(sslCtx, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                session.state = .error; onUpdateSession?(session); break
            }
        }

        SSLClose(sslCtx)
    }

    // MARK: - SSL Write helper

    @discardableResult
    private func sslSend(_ ctx: SSLContext, _ string: String) -> Bool {
        guard let d = string.data(using: .utf8) else { return false }
        return sslSend(ctx, d)
    }

    @discardableResult
    private func sslSend(_ ctx: SSLContext, _ data: Data) -> Bool {
        data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            var remaining = data.count
            var offset    = 0
            while remaining > 0 {
                var processed = remaining
                let st = SSLWrite(ctx, base.advanced(by: offset), remaining, &processed)
                if st != errSecSuccess && st != errSSLWouldBlock { return false }
                offset    += processed
                remaining -= processed
            }
            return true
        }
    }
}
