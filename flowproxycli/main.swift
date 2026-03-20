import Foundation

// MARK: - Argument helpers

func parseFlags(_ args: [String]) -> (flags: [String: String], positional: [String]) {
    var flags:      [String: String] = [:]
    var positional: [String]         = []
    var i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                flags[key] = args[i + 1]; i += 2
            } else {
                flags[key] = "true";      i += 1
            }
        } else {
            positional.append(a); i += 1
        }
    }
    return (flags, positional)
}

func jsonBody(_ dict: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
}

func usageExit(_ message: String? = nil) -> Never {
    if let msg = message { fputs("Error: \(msg)\n\n", stderr) }
    let usage = """
    Usage: flowproxy <resource> <action> [options]

    proxy start              [--port N] [--https-intercept]
    proxy stop
    proxy status

    sessions list            [--limit N] [--host H] [--method M] [--status S] [--search Q]
    sessions get <id>
    sessions clear

    replay <session_id>      [--method M] [--header K:V] [--body B]

    reverse-proxy list
    reverse-proxy add        --name N --local-port N --upstream URL
    reverse-proxy remove     <id>

    Global: --json           Output JSON instead of human-readable text
    """
    fputs(usage + "\n", stderr)
    exit(1)
}

// MARK: - Main

let rawArgs = Array(CommandLine.arguments.dropFirst())
guard !rawArgs.isEmpty else { usageExit() }

let (flags, positional) = parseFlags(rawArgs)
let useJSON  = flags["json"] == "true"
let resource = positional.first ?? ""

func getClient() -> CLIClient {
    guard let client = launchServiceIfNeeded() else { exit(1) }
    return client
}

// MARK: - Dispatch

switch resource {

// ── proxy ──────────────────────────────────────────────────────────────────

case "proxy":
    let action = positional.dropFirst().first ?? ""
    switch action {

    case "start":
        let client = getClient()
        var body: [String: Any] = [:]
        if let p = flags["port"], let n = Int(p) { body["port"] = n }
        if flags["https-intercept"] == "true" { body["httpsIntercept"] = true }
        do {
            let data = try client.post("/proxy/start", body: body.isEmpty ? nil : jsonBody(body))
            OutputFormatter.proxyStatus(data, json: useJSON)
        } catch { OutputFormatter.printError(error); exit(1) }

    case "stop":
        guard let port = CLIClient.loadPort() else {
            print(useJSON ? #"{"running":false}"# : "Proxy: already stopped (service not running)")
            exit(0)
        }
        let client = CLIClient(port: port)
        do {
            let data = try client.post("/proxy/stop")
            OutputFormatter.proxyStatus(data, json: useJSON)
        } catch { OutputFormatter.printError(error); exit(1) }

    case "status":
        guard let port = CLIClient.loadPort() else {
            print(useJSON ? #"{"running":false,"port":0}"# : "Proxy: stopped (service not running)")
            exit(0)
        }
        let client = CLIClient(port: port)
        do {
            let data = try client.get("/proxy/status")
            OutputFormatter.proxyStatus(data, json: useJSON)
        } catch { OutputFormatter.printError(error); exit(1) }

    default: usageExit("Unknown proxy action: '\(action)'")
    }

// ── sessions ───────────────────────────────────────────────────────────────

case "sessions":
    let action = positional.dropFirst().first ?? ""
    switch action {

    case "list":
        let client = getClient()
        var params: [String] = []
        if let v = flags["limit"]  { params.append("limit=\(v)") }
        if let v = flags["host"]   { params.append("host=\(v)") }
        if let v = flags["method"] { params.append("method=\(v)") }
        if let v = flags["status"] { params.append("status=\(v)") }
        if let v = flags["search"] {
            let enc = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            params.append("search=\(enc)")
        }
        let path = params.isEmpty ? "/sessions" : "/sessions?" + params.joined(separator: "&")
        do {
            let data = try client.get(path)
            OutputFormatter.sessionsList(data, json: useJSON)
        } catch { OutputFormatter.printError(error); exit(1) }

    case "get":
        guard let id = positional.dropFirst(2).first else {
            usageExit("Usage: flowproxy sessions get <id>")
        }
        let client = getClient()
        do {
            let data = try client.get("/sessions/\(id)")
            OutputFormatter.sessionDetail(data, json: useJSON)
        } catch { OutputFormatter.printError(error); exit(1) }

    case "clear":
        let client = getClient()
        do {
            let data = try client.delete("/sessions")
            OutputFormatter.success(data, json: useJSON, message: "Sessions cleared.")
        } catch { OutputFormatter.printError(error); exit(1) }

    default: usageExit("Unknown sessions action: '\(action)'")
    }

// ── replay ─────────────────────────────────────────────────────────────────

case "replay":
    guard let sessionId = positional.dropFirst().first else {
        usageExit("Usage: flowproxy replay <session_id>")
    }
    let client = getClient()
    var body: [String: Any] = [:]
    if let m = flags["method"] { body["method"] = m }
    if let b = flags["body"]   { body["body"]   = b }
    if let h = flags["header"] {
        let parts = h.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
            body["headers"] = [
                String(parts[0]).trimmingCharacters(in: .whitespaces):
                String(parts[1]).trimmingCharacters(in: .whitespaces)
            ]
        }
    }
    do {
        let data = try client.post("/sessions/\(sessionId)/replay",
                                   body: body.isEmpty ? nil : jsonBody(body))
        OutputFormatter.sessionDetail(data, json: useJSON)
    } catch { OutputFormatter.printError(error); exit(1) }

// ── reverse-proxy ──────────────────────────────────────────────────────────

case "reverse-proxy":
    let action = positional.dropFirst().first ?? ""
    switch action {

    case "list":
        let client = getClient()
        do {
            let data = try client.get("/reverse-proxy")
            OutputFormatter.reverseProxyList(data, json: useJSON)
        } catch { OutputFormatter.printError(error); exit(1) }

    case "add":
        guard let name    = flags["name"],
              let portStr = flags["local-port"], let localPort = Int(portStr),
              let upstream = flags["upstream"] else {
            usageExit("Usage: flowproxy reverse-proxy add --name N --local-port N --upstream URL")
        }
        let client = getClient()
        let body   = jsonBody(["name": name, "localPort": localPort, "upstreamURL": upstream])
        do {
            let data = try client.post("/reverse-proxy", body: body)
            if useJSON {
                OutputFormatter.success(data, json: true)
            } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let id = (obj["id"] as? String).map { String($0.prefix(8)) } ?? "?"
                print("Added rule \(id): \(name)  :\(localPort) → \(upstream)")
            }
        } catch { OutputFormatter.printError(error); exit(1) }

    case "remove":
        guard let id = positional.dropFirst(2).first else {
            usageExit("Usage: flowproxy reverse-proxy remove <id>")
        }
        let client = getClient()
        do {
            let data = try client.delete("/reverse-proxy/\(id)")
            OutputFormatter.success(data, json: useJSON, message: "Rule \(id) removed.")
        } catch { OutputFormatter.printError(error); exit(1) }

    default: usageExit("Unknown reverse-proxy action: '\(action)'")
    }

default:
    usageExit("Unknown resource: '\(resource)'")
}
