import Foundation
import Network

// MARK: - Reverse Proxy Manager
actor ReverseProxyManager {

    private var activeListeners: [UUID: NWListener] = [:]
    private let dispatchQueue = DispatchQueue(label: "com.flowproxy.reverseproxy", qos: .userInitiated, attributes: .concurrent)

    var onNewSession: ((ProxySession) -> Void)?
    var onUpdateSession: ((ProxySession) -> Void)?

    // MARK: - Start Rule

    func startRule(_ rule: ReverseProxyRule) async throws {
        guard rule.isEnabled else { return }
        guard activeListeners[rule.id] == nil else { return }

        let port = NWEndpoint.Port(rawValue: UInt16(rule.localPort))!
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: port)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            Task {
                await self.handleReverseProxyConnection(connection, rule: rule)
            }
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[ReverseProxy] Rule '\(rule.displayName)' listening on port \(rule.localPort)")
            case .failed(let err):
                print("[ReverseProxy] Rule '\(rule.displayName)' failed: \(err)")
            default:
                break
            }
        }

        listener.start(queue: dispatchQueue)
        activeListeners[rule.id] = listener
    }

    // MARK: - Stop Rule

    func stopRule(_ rule: ReverseProxyRule) {
        if let listener = activeListeners[rule.id] {
            listener.cancel()
            activeListeners.removeValue(forKey: rule.id)
        }
    }

    // MARK: - Stop All

    func stopAll() {
        for (_, listener) in activeListeners {
            listener.cancel()
        }
        activeListeners.removeAll()
    }

    // MARK: - Handle Connection

    private func handleReverseProxyConnection(_ clientConn: NWConnection, rule: ReverseProxyRule) async {
        let startTime = Date()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            clientConn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task {
                        await self.processReverseProxyRequest(clientConn, rule: rule, startTime: startTime)
                        continuation.resume()
                    }
                case .failed, .cancelled:
                    continuation.resume()
                default:
                    break
                }
            }
            clientConn.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }

    private func processReverseProxyRequest(_ clientConn: NWConnection,
                                              rule: ReverseProxyRule,
                                              startTime: Date) async {
        // Read request from client
        guard let reqData = try? await receiveData(from: clientConn, minLength: 1, maxLength: 65536),
              !reqData.isEmpty,
              let (request, _) = try? HTTPParser.parseRequest(reqData) else {
            clientConn.cancel()
            return
        }

        var headers = request.headers
        var path = request.path

        // Apply rewrites
        rule.applyRequestRewrites(to: &headers, path: &path)

        // Set Host header to upstream
        headers["Host"] = "\(rule.upstreamHost):\(rule.upstreamPort)"

        // Create session
        let session = ProxySession(
            sessionProtocol: rule.isHTTPS ? .https : .http,
            host: rule.upstreamHost,
            path: path,
            method: request.method,
            requestHeaders: headers,
            requestBody: request.body.isEmpty ? nil : request.body
        )
        session.timing = TimingInfo()
        session.timing?.connectStart = startTime

        onNewSession?(session)

        // Connect to upstream
        let upstreamParams: NWParameters = rule.isHTTPS ? NWParameters.tls : NWParameters.tcp

        if rule.isHTTPS && !rule.sslVerification {
            // Disable SSL verification for upstream
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, _, completionHandler in completionHandler(true) },
                DispatchQueue.global()
            )
        }

        let upstreamEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(rule.upstreamHost),
            port: NWEndpoint.Port(rawValue: UInt16(rule.upstreamPort)) ?? 80
        )
        let upstreamConn = NWConnection(to: upstreamEndpoint, using: upstreamParams)

        var connected = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            upstreamConn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connected = true
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume()
                default:
                    break
                }
            }
            upstreamConn.start(queue: DispatchQueue.global(qos: .userInitiated))
        }

        guard connected else {
            session.error = "Failed to connect to upstream \(rule.upstreamURL)"
            session.state = .error
            onUpdateSession?(session)
            let resp = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
            await sendData(resp.data(using: .utf8)!, to: clientConn)
            clientConn.cancel()
            return
        }

        session.timing?.connectEnd = Date()

        // Forward request
        let forwardData = HTTPParser.serializeRequest(
            method: request.method,
            path: path,
            version: request.version,
            headers: headers,
            body: request.body.isEmpty ? nil : request.body
        )

        session.timing?.requestSent = Date()
        await sendData(forwardData, to: upstreamConn)

        // Read response
        var responseBuffer = Data()
        for _ in 0..<100 {
            guard let chunk = try? await receiveData(from: upstreamConn, minLength: 1, maxLength: 65536),
                  !chunk.isEmpty else { break }
            responseBuffer.append(chunk)

            if let (resp, _) = try? HTTPParser.parseResponse(responseBuffer) {
                var respHeaders = resp.headers
                rule.applyResponseRewrites(to: &respHeaders)

                session.responseStatusCode = resp.statusCode
                session.responseHeaders = respHeaders
                session.responseBody = resp.body.isEmpty ? nil : resp.body
                session.timing?.firstByte = Date()
                session.timing?.responseEnd = Date()
                session.duration = Date().timeIntervalSince(startTime)
                session.state = .complete
                onUpdateSession?(session)

                // Serialize and send modified response
                let outData = HTTPParser.serializeResponse(
                    version: resp.version,
                    statusCode: resp.statusCode,
                    statusMessage: resp.statusMessage,
                    headers: respHeaders,
                    body: resp.body.isEmpty ? nil : resp.body
                )
                await sendData(outData, to: clientConn)
                break
            }
        }

        if session.state == .pending {
            session.state = .error
            session.error = "No response from upstream"
            session.duration = Date().timeIntervalSince(startTime)
            onUpdateSession?(session)
        }

        upstreamConn.cancel()
        clientConn.cancel()
    }

    // MARK: - Helpers

    private func receiveData(from conn: NWConnection, minLength: Int, maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            conn.receive(minimumIncompleteLength: minLength, maximumLength: maxLength) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private func sendData(_ data: Data, to conn: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}
