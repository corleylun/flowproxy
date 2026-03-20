import Foundation

// FlowProxyService — background service that runs the proxy and HTTP API.
// Launched by the CLI when needed; survives CLI exit.

let store     = ServiceStore()
let apiServer = APIServer(store: store)

Task {
    do {
        try await apiServer.start()
        print("[FlowProxyService] Ready")
    } catch {
        fputs("[FlowProxyService] Fatal: \(error)\n", stderr)
        exit(1)
    }
}

RunLoop.main.run()
