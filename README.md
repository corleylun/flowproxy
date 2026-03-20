# FlowProxy

A macOS HTTP/HTTPS debugging proxy — capture, inspect, and replay network traffic from any app or browser.

FlowProxy is a developer tool in the spirit of Charles Proxy and mitmproxy, built entirely in Swift for macOS. It ships as three components: a **native SwiftUI app**, a **headless background service**, and a **CLI** with full JSON output for scripting and AI agent workflows.

---

## Features

- **Capture HTTP & HTTPS traffic** — acts as a man-in-the-middle proxy; all requests and responses are recorded
- **Inspect sessions** — view full headers, request/response bodies, cookies, timing breakdown (DNS, TLS, connect, transfer)
- **Replay requests** — resend any captured request, optionally overriding method, headers, or body
- **Reverse proxy rules** — forward a local port to any upstream URL with optional request/response rewriting
- **HTTPS interception** — generates certificates on the fly via a built-in CA; install the CA once to decrypt all TLS traffic
- **Filter & search** — filter sessions by host, method, status code, protocol, or free-text search
- **CLI + JSON output** — every command supports `--json` for use in scripts, CI, and AI agent workflows
- **Service architecture** — the background service persists across CLI invocations; sessions survive when you close the GUI

---

## Components

```
FlowProxy (GUI app)          — SwiftUI macOS app, full visual inspector
FlowProxyService (service)   — headless background process, REST API on :7878
flowproxycli (CLI)           — command-line interface, talks to the service
```

The three components are independent. The CLI and GUI can run simultaneously against the same service.

---

## Requirements

- macOS 13 or later
- Xcode 15+ (to build from source)

---

## Building from Source

Clone the repository and open the Xcode project:

```bash
git clone https://github.com/your-username/flowproxy.git
cd flowproxy
open FlowProxy.xcodeproj
```

Build all three targets in Xcode:

- `FlowProxy` — the GUI app
- `FlowProxyService` — the background service
- `flowproxycli` — the CLI tool

To use the CLI from the terminal, place both `flowproxycli` and `FlowProxyService` in the same directory (or both in `/usr/local/bin/`). The CLI auto-launches the service if it isn't already running.

---

## Quick Start

### Using the GUI

1. Open **FlowProxy.app**
2. Click **Start Proxy** (default port: 8888)
3. Configure your browser or app to use HTTP proxy `127.0.0.1:8888`
4. Browse — requests appear in the session list in real time
5. Click any session to inspect headers, body, cookies, and timing

### Using the CLI

```bash
# Start the proxy
flowproxy proxy start

# Configure your app/browser to use 127.0.0.1:8888

# List captured sessions
flowproxy sessions list

# Inspect a session in full
flowproxy sessions get <uuid>

# Replay it (optionally with a new auth header)
flowproxy replay <uuid> --header "Authorization: Bearer newtoken"

# Stop the proxy
flowproxy proxy stop
```

---

## HTTPS Interception

To decrypt HTTPS traffic, FlowProxy uses a local Certificate Authority (CA).

1. Open the **FlowProxy GUI app**
2. Go to **Settings → Certificate Authority**
3. Click **Install CA Certificate** — this adds the FlowProxy CA to your macOS Keychain and marks it as trusted
4. Start the proxy and enable HTTPS interception:

```bash
flowproxy proxy start --https-intercept
```

With the CA trusted, all HTTPS sessions are fully decrypted and visible in both the GUI and CLI.

> **Note:** The CA private key never leaves your machine. It is stored in your macOS Keychain.

---

## CLI Reference

```
flowproxy <resource> <action> [options]
```

Add `--json` to any command for machine-readable output.

### Proxy

```bash
flowproxy proxy start [--port N] [--https-intercept]
flowproxy proxy stop
flowproxy proxy status
```

### Sessions

```bash
flowproxy sessions list
flowproxy sessions list --limit 20 --host api.example.com --method POST --status 404 --search "login"
flowproxy sessions get <uuid>
flowproxy sessions clear
```

### Replay

```bash
flowproxy replay <uuid>
flowproxy replay <uuid> --method POST --header "Content-Type: application/json" --body '{"key":"value"}'
```

### Reverse Proxy

```bash
flowproxy reverse-proxy list
flowproxy reverse-proxy add --name "My API" --local-port 9001 --upstream https://api.example.com
flowproxy reverse-proxy remove <uuid>
```

Full CLI documentation: [`flowproxy_cli_usage.md`](flowproxy_cli_usage.md)

---

## JSON Output

Every command supports `--json` for stable, structured output:

```bash
flowproxy sessions list --json
```

```json
{
  "count": 1,
  "sessions": [
    {
      "id": "B5E91BA5-1234-5678-90AB-CDEF01234567",
      "method": "GET",
      "host": "api.example.com",
      "path": "/v1/users",
      "url": "https://api.example.com/v1/users",
      "protocol": "HTTPS",
      "status": 200,
      "duration_ms": 120,
      "state": "Complete",
      "timestamp": "2026-03-20T10:30:00Z",
      "error": null
    }
  ]
}
```

Errors also return structured JSON with a stable `code` field, making them easy to handle in scripts.

---

## AI Agent Integration

FlowProxy is designed to work with AI coding agents. The `--json` flag and the service REST API make it straightforward for an agent to:

- Start/stop the proxy programmatically
- Observe traffic from a running app
- Find failing requests by status code or host
- Replay requests with modified headers or bodies to test fixes

See [`flowproxy_ai_agent_guide.md`](flowproxy_ai_agent_guide.md) for a complete guide with example workflows.

---

## File Locations

| Path | Purpose |
|------|---------|
| `~/.flowproxy/service.port` | Port the background service is listening on |
| `~/.flowproxy/reverse_proxy_rules.json` | Persisted reverse proxy rules |

Sessions are held in memory and are cleared when the service stops.

---

## Architecture

```
Browser / App
     │
     ▼  (HTTP proxy: 127.0.0.1:8888)
ProxyServer  ──── HTTPSInterceptor ──── CertificateAuthorityManager
     │
     ▼
 SessionStore  (in-memory)
     │
     ▼
 APIServer  (REST API: 127.0.0.1:7878)
     │              │
     ▼              ▼
flowproxy CLI    FlowProxy GUI
```

Key implementation details:

- **Swift actors** for thread-safe proxy server, session store, and CA manager
- **BSD sockets** for low-level proxy control
- **Network framework** (`NWListener`) for reverse proxy rules
- **Security framework** for TLS interception and Keychain-backed CA
- **SwiftUI + Combine** for the reactive GUI

---

## License

MIT License — see [LICENSE](LICENSE) for details.
