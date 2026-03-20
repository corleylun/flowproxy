import Foundation

// MARK: - CLIError

enum CLIError: LocalizedError {
    case serviceUnavailable
    case badResponse(Int, String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "FlowProxy service is not running. Use: flowproxy proxy start"
        case .badResponse(let code, let msg):
            return "Service error (\(code)): \(msg)"
        }
    }
}

// MARK: - CLIClient

final class CLIClient {
    let port: Int

    init(port: Int) { self.port = port }

    // MARK: - Port discovery

    static func loadPort() -> Int? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".flowproxy/service.port")
        guard let str  = try? String(contentsOf: file, encoding: .utf8),
              let port = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return port
    }

    // MARK: - HTTP verbs

    func get(_ path: String) throws -> Data {
        try request("GET", path, body: nil)
    }

    func post(_ path: String, body: Data? = nil) throws -> Data {
        try request("POST", path, body: body)
    }

    func delete(_ path: String) throws -> Data {
        try request("DELETE", path, body: nil)
    }

    // MARK: - Core request (synchronous)

    func request(_ method: String, _ path: String, body: Data?) throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw CLIError.serviceUnavailable
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        if let body = body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let sem = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultStatus = 0

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        URLSession(configuration: cfg).dataTask(with: req) { data, resp, _ in
            resultData   = data
            resultStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        sem.wait()

        guard let data = resultData else { throw CLIError.serviceUnavailable }

        if resultStatus >= 400 {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String {
                throw CLIError.badResponse(resultStatus, msg)
            }
            throw CLIError.badResponse(resultStatus,
                HTTPURLResponse.localizedString(forStatusCode: resultStatus))
        }
        return data
    }

    // MARK: - Connectivity check

    func isReachable() -> Bool {
        (try? get("/proxy/status")) != nil
    }
}

// MARK: - Service launcher

func launchServiceIfNeeded() -> CLIClient? {
    // Already running?
    if let port = CLIClient.loadPort() {
        let client = CLIClient(port: port)
        if client.isReachable() { return client }
    }

    // Find and launch the service binary
    let servicePath = resolveServicePath()
    guard FileManager.default.isExecutableFile(atPath: servicePath) else {
        fputs("Error: FlowProxyService binary not found at \(servicePath)\n", stderr)
        return nil
    }

    let process = Process()
    process.executableURL  = URL(fileURLWithPath: servicePath)
    process.standardOutput = FileHandle.nullDevice
    process.standardError  = FileHandle.nullDevice
    do { try process.run() } catch {
        fputs("Error: Failed to launch FlowProxyService: \(error)\n", stderr)
        return nil
    }

    // Wait up to 3 s for service to become available
    for _ in 0..<30 {
        Thread.sleep(forTimeInterval: 0.1)
        if let port = CLIClient.loadPort() {
            let client = CLIClient(port: port)
            if client.isReachable() { return client }
        }
    }

    fputs("Error: FlowProxy service did not start in time\n", stderr)
    return nil
}

private func resolveServicePath() -> String {
    let exe = CommandLine.arguments[0]
    let dir = URL(fileURLWithPath: exe).deletingLastPathComponent().path
    let candidate = URL(fileURLWithPath: dir).appendingPathComponent("FlowProxyService").path
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    return "/usr/local/bin/FlowProxyService"
}
