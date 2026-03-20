# FlowProxy CLI — Usage Guide

## Overview

The FlowProxy CLI is a command-line interface to the FlowProxy HTTP/HTTPS proxy tool.
It communicates with a background service (`FlowProxyService`) that runs independently
of the GUI app. The CLI auto-starts the service if it isn't already running.

---

## How It Works

```
flowproxy (CLI)  ──HTTP──▶  FlowProxyService (background)  ──▶  Proxy engine
```

- The service runs on `127.0.0.1` (port 7878 by default) and persists after the CLI exits.
- The service port is stored at `~/.flowproxy/service.port`.
- The CLI finds the service via that file, or launches it automatically if needed.

---

## Command Format

```
flowproxy <resource> <action> [options]
```

Global option available on every command:

| Flag     | Description                          |
|----------|--------------------------------------|
| `--json` | Output machine-readable JSON instead of human-readable text |

---

## Proxy

### Start the proxy

```bash
flowproxy proxy start
flowproxy proxy start --port 8080
flowproxy proxy start --port 8080 --https-intercept
```

Starts the HTTP/HTTPS proxy. If the service isn't running, it is launched automatically.
Defaults to port `8888` if `--port` is not specified.

**Output:**
```
Proxy: running (port 8080)
```

### Stop the proxy

```bash
flowproxy proxy stop
```

Stops the proxy but leaves the service running (sessions are preserved).

**Output:**
```
Proxy: stopped
```

### Check proxy status

```bash
flowproxy proxy status
flowproxy proxy status --json
```

**Human output:**
```
Proxy: running (port 8888)
```

**JSON output:**
```json
{
  "running": true,
  "port": 8888
}
```

---

## Sessions

Sessions are HTTP/HTTPS requests captured by the proxy.

### List sessions

```bash
flowproxy sessions list
```

With filters:

```bash
flowproxy sessions list --limit 20
flowproxy sessions list --host api.example.com
flowproxy sessions list --method POST
flowproxy sessions list --status 404
flowproxy sessions list --search "login"
flowproxy sessions list --host api.example.com --method GET --limit 10
```

| Option      | Description                              |
|-------------|------------------------------------------|
| `--limit N` | Show last N sessions                     |
| `--host H`  | Filter by host (partial match)           |
| `--method M`| Filter by HTTP method (GET, POST, etc.)  |
| `--status S`| Filter by HTTP status code               |
| `--search Q`| Search across host, path, and method     |

**Human output:**
```
ID        METHOD  HOST                          STATUS  TIME
────────────────────────────────────────────────────────────
3a4b5c6d  GET     api.example.com               200     120ms
9f1e2d3c  POST    api.example.com               201     340ms

2 session(s)
```

**JSON output (`--json`):**
```json
{
  "count": 2,
  "sessions": [
    {
      "duration_ms": 120,
      "host": "api.example.com",
      "id": "3a4b5c6d-...",
      "method": "GET",
      "path": "/v1/users",
      "protocol": "HTTPS",
      "state": "Complete",
      "status": 200,
      "timestamp": "2026-03-20T10:30:00Z",
      "url": "https://api.example.com/v1/users"
    }
  ]
}
```

### Inspect a session

```bash
flowproxy sessions get 3a4b5c6d-1234-5678-90ab-cdef01234567
flowproxy sessions get 3a4b5c6d-1234-5678-90ab-cdef01234567 --json
```

Use the full UUID from `sessions list`. The `--json` form returns full request/response
headers and bodies.

**Human output:**
```
ID:          3a4b5c6d-...
Method:      GET
Host:        api.example.com
Path:        /v1/users
Protocol:    HTTPS
Status:      200
Duration:    120ms
State:       Complete

Request Headers:
  Authorization: Bearer abc123
  ...

Response Headers:
  Content-Type: application/json
  ...

Response Body:
{"users": [...]}
```

### Clear all sessions

```bash
flowproxy sessions clear
```

Removes all captured sessions from memory.

---

## Replay

Replay a captured session, optionally overriding parts of the request.

```bash
flowproxy replay 3a4b5c6d-1234-5678-90ab-cdef01234567
```

With overrides:

```bash
flowproxy replay <id> --method POST
flowproxy replay <id> --header "Authorization: Bearer newtoken"
flowproxy replay <id> --body '{"key":"value"}'
flowproxy replay <id> --method POST --header "Content-Type: application/json" --body '{"x":1}'
```

| Option        | Description                          |
|---------------|--------------------------------------|
| `--method M`  | Override HTTP method                 |
| `--header K:V`| Add or override a single header      |
| `--body B`    | Override request body (raw string)   |

The replayed request is stored as a new session and its full detail is shown.

---

## Reverse Proxy

Reverse proxy rules forward traffic from a local port to an upstream URL.

### List rules

```bash
flowproxy reverse-proxy list
```

**Output:**
```
ID        NAME                PORT        UPSTREAM
──────────────────────────────────────────────────────────────────
6cc22eb2  My API              9001        https://api.example.com
```

### Add a rule

```bash
flowproxy reverse-proxy add --name "My API" --local-port 9001 --upstream https://api.example.com
```

| Option           | Description                          |
|------------------|--------------------------------------|
| `--name N`       | Display name for the rule (required) |
| `--local-port N` | Local port to listen on (required)   |
| `--upstream URL` | Upstream URL to forward to (required)|

After adding, traffic to `localhost:9001` is forwarded to `https://api.example.com`.

Rules are persisted to `~/.flowproxy/reverse_proxy_rules.json` and restored when the
service restarts.

### Remove a rule

```bash
flowproxy reverse-proxy remove 6cc22eb2-1234-5678-90ab-cdef01234567
```

Use the full UUID from `reverse-proxy list`.

---

## JSON Mode

Every command supports `--json` for scripting and AI agent use.

```bash
flowproxy sessions list --json
flowproxy proxy status --json
flowproxy reverse-proxy list --json
```

Rules for JSON output:
- Output is always valid JSON — no mixed text and JSON.
- Fields are always present and stable across calls.
- Errors are also structured JSON:

```json
{
  "error": {
    "code": "not_found",
    "message": "Session abc123 not found"
  }
}
```

---

## Common Workflows

### Capture traffic from a browser or app

```bash
# 1. Start the proxy
flowproxy proxy start --port 8888

# 2. Configure your browser/app to use HTTP proxy: 127.0.0.1:8888
#    For HTTPS, install the FlowProxy CA cert (via the GUI app)

# 3. Make some requests in your browser

# 4. Inspect captured traffic
flowproxy sessions list
flowproxy sessions list --host example.com
flowproxy sessions get <id>

# 5. Stop when done
flowproxy proxy stop
```

### Test an API endpoint

```bash
# Start proxy
flowproxy proxy start

# List recent POST requests to your API
flowproxy sessions list --method POST --host api.myapp.com

# Replay a specific one with a modified header
flowproxy replay <id> --header "Authorization: Bearer newtoken"
```

### Use from a script or AI agent

```bash
# All output is stable JSON
STATUS=$(flowproxy proxy status --json)
RUNNING=$(echo $STATUS | python3 -c "import sys,json; print(json.load(sys.stdin)['running'])")

if [ "$RUNNING" = "False" ]; then
  flowproxy proxy start --json
fi

# Get sessions as JSON for processing
flowproxy sessions list --limit 50 --json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data['sessions']:
    print(s['method'], s['status'], s['url'])
"
```

---

## File Locations

| Path | Purpose |
|------|---------|
| `~/.flowproxy/service.port` | Port the background service is listening on |
| `~/.flowproxy/reverse_proxy_rules.json` | Persisted reverse proxy rules |

---

## Troubleshooting

**"FlowProxy service is not running"**
The service binary (`FlowProxyService`) was not found next to the CLI binary. Make sure
both are built and in the same directory, or install them to `/usr/local/bin/`.

**"FlowProxy service did not start in time"**
The service launched but didn't become ready within 3 seconds. Check for port conflicts
on 7878–7900 or look at service logs.

**"Proxy already running"**
The proxy is already started. Use `proxy status` to check the port.

**Sessions not appearing**
Make sure your browser or app is configured to use the proxy at `127.0.0.1:<port>`.
For HTTPS traffic, the FlowProxy CA certificate must be installed and trusted.
