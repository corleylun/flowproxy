# FlowProxy CLI — AI Agent Guide

This document teaches an AI agent how to use the `flowproxy` CLI to inspect,
capture, and replay HTTP/HTTPS traffic programmatically.

---

## Core Rules

1. **Always use `--json`** — every command supports it. Never parse human-readable output.
2. **Check service state before acting** — use `proxy status` first.
3. **Full UUIDs only** — the human table shows 8-char short IDs; always get full IDs via `--json`.
4. **The service auto-starts** — running any command that needs the service will launch it automatically.
5. **Sessions are in-memory** — they reset when the service is stopped. Export if you need to persist them.

---

## Starting Up

### Check if the proxy is running

```bash
flowproxy proxy status --json
```

```json
{
  "port": 8888,
  "running": false
}
```

### Start the proxy

```bash
flowproxy proxy start --json
flowproxy proxy start --port 8080 --json
```

```json
{
  "port": 8888,
  "running": true
}
```

If already running it returns the same shape with `"running": true` and a `"message"` field — not an error.

### Stop the proxy

```bash
flowproxy proxy stop --json
```

```json
{
  "running": false
}
```

---

## Sessions

Sessions are HTTP/HTTPS requests captured by the proxy. They are created automatically
when traffic passes through the proxy.

### List sessions

```bash
flowproxy sessions list --json
```

```json
{
  "count": 2,
  "sessions": [
    {
      "duration_ms": 583,
      "error": null,
      "host": "ipchicken.com",
      "id": "B5E91BA5-1234-5678-90AB-CDEF01234567",
      "method": "GET",
      "path": "/",
      "protocol": "HTTPS",
      "state": "Complete",
      "status": 200,
      "timestamp": "2026-03-20T10:30:00Z",
      "url": "https://ipchicken.com/"
    }
  ]
}
```

**Field reference:**

| Field | Type | Description |
|-------|------|-------------|
| `id` | string (UUID) | Unique session ID — use this for `get` and `replay` |
| `method` | string | HTTP method: GET, POST, PUT, PATCH, DELETE, etc. |
| `host` | string | Hostname (no port) |
| `path` | string | URL path including query string |
| `url` | string | Full URL |
| `protocol` | string | `"HTTP"` or `"HTTPS"` |
| `status` | int or null | HTTP response status code. `null` if request failed |
| `duration_ms` | int or null | Round-trip time in milliseconds |
| `state` | string | `"Pending"`, `"Complete"`, or `"Error"` |
| `timestamp` | string | ISO 8601 UTC timestamp |
| `error` | string or null | Error message if `state` is `"Error"` |

### Filter sessions

```bash
# Last 10 sessions
flowproxy sessions list --limit 10 --json

# Only from a specific host
flowproxy sessions list --host api.example.com --json

# Only POST requests
flowproxy sessions list --method POST --json

# Only 4xx errors
flowproxy sessions list --status 404 --json

# Full-text search across host, path, method
flowproxy sessions list --search "login" --json

# Combine filters
flowproxy sessions list --host api.example.com --method POST --limit 5 --json
```

All filters can be combined. `--limit` returns the N most recent matching sessions.

### Get full session detail

```bash
flowproxy sessions get B5E91BA5-1234-5678-90AB-CDEF01234567 --json
```

```json
{
  "duration_ms": 583,
  "error": null,
  "host": "ipchicken.com",
  "id": "B5E91BA5-1234-5678-90AB-CDEF01234567",
  "method": "GET",
  "path": "/",
  "protocol": "HTTPS",
  "requestBody": null,
  "requestHeaders": {
    "Accept": "text/html",
    "Host": "ipchicken.com",
    "User-Agent": "Mozilla/5.0 ..."
  },
  "responseBody": "<!DOCTYPE html>...",
  "responseHeaders": {
    "Content-Type": "text/html; charset=utf-8"
  },
  "state": "Complete",
  "status": 200,
  "timestamp": "2026-03-20T10:30:00Z",
  "url": "https://ipchicken.com/"
}
```

**Additional fields in detail view:**

| Field | Type | Description |
|-------|------|-------------|
| `requestHeaders` | object | All request headers as key/value pairs |
| `responseHeaders` | object | All response headers as key/value pairs |
| `requestBody` | string or null | Request body as UTF-8 string |
| `responseBody` | string or null | Response body as UTF-8 string |

### Clear sessions

```bash
flowproxy sessions clear --json
```

```json
{
  "cleared": true
}
```

---

## Replay

Replay a captured session — resends the original request, optionally with modifications.
The replayed request is stored as a new session and its full detail is returned.

### Basic replay (exact repeat)

```bash
flowproxy replay B5E91BA5-1234-5678-90AB-CDEF01234567 --json
```

### Replay with overrides

```bash
# Override method
flowproxy replay <id> --method POST --json

# Override a header
flowproxy replay <id> --header "Authorization: Bearer newtoken123" --json

# Override body
flowproxy replay <id> --body '{"key":"value"}' --json

# Combine overrides
flowproxy replay <id> --method POST --header "Content-Type: application/json" --body '{"x":1}' --json
```

**Returns:** Full session detail (same shape as `sessions get`).

---

## Reverse Proxy

### List rules

```bash
flowproxy reverse-proxy list --json
```

```json
{
  "count": 1,
  "rules": [
    {
      "id": "6CC22EB2-1234-5678-90AB-CDEF01234567",
      "isEnabled": true,
      "localPort": 9001,
      "name": "My API",
      "upstreamURL": "https://api.example.com"
    }
  ]
}
```

### Add a rule

```bash
flowproxy reverse-proxy add --name "My API" --local-port 9001 --upstream https://api.example.com --json
```

Returns the created rule object.

### Remove a rule

```bash
flowproxy reverse-proxy remove 6CC22EB2-1234-5678-90AB-CDEF01234567 --json
```

```json
{
  "removed": true
}
```

---

## Error Handling

All errors return a non-2xx HTTP status code from the service AND a structured JSON body.
Exit code is `1` on error.

```json
{
  "error": {
    "code": "not_found",
    "message": "Session abc123 not found"
  }
}
```

**Error codes:**

| Code | Meaning |
|------|---------|
| `not_found` | Session or rule ID does not exist |
| `start_failed` | Proxy failed to start (port in use, CA error, etc.) |
| `invalid_body` | Request body was missing or malformed |
| `invalid_id` | UUID format was invalid |
| `invalid_url` | Session URL could not be reconstructed for replay |
| `bad_request` | Malformed HTTP request to the service |

---

## Typical Agent Workflows

### Workflow 1 — Observe traffic from a running app

```bash
# 1. Start proxy
flowproxy proxy start --json

# 2. (Tell the user to configure their app to proxy through 127.0.0.1:8888)

# 3. Poll for new sessions
flowproxy sessions list --limit 20 --json

# 4. Inspect a specific session
flowproxy sessions get <id> --json

# 5. Stop when done
flowproxy proxy stop --json
```

### Workflow 2 — Find and replay a failing request

```bash
# Find all 5xx errors
flowproxy sessions list --status 500 --json

# Or find errors by host
flowproxy sessions list --host api.myapp.com --json
# → filter results where "status" >= 500 or "state" == "Error"

# Replay the failing request
flowproxy replay <id> --json

# Replay with a modified auth token to test a fix
flowproxy replay <id> --header "Authorization: Bearer newtoken" --json
```

### Workflow 3 — Inspect request/response for a specific endpoint

```bash
# Start proxy, make sure the app uses it

# Find POST requests to a specific path
flowproxy sessions list --method POST --host api.example.com --json
# → scan "path" field in results for the endpoint you want

# Get full headers and body
flowproxy sessions get <id> --json
# → read "requestHeaders", "requestBody", "responseHeaders", "responseBody"
```

### Workflow 4 — Set up a local reverse proxy

```bash
# Forward localhost:9001 to a remote API
flowproxy reverse-proxy add --name "staging-api" --local-port 9001 --upstream https://staging.api.example.com --json

# Verify it's running
flowproxy reverse-proxy list --json

# When done
flowproxy reverse-proxy remove <id> --json
```

---

## Quick Reference

```bash
# Proxy lifecycle
flowproxy proxy status --json
flowproxy proxy start [--port N] --json
flowproxy proxy stop --json

# Sessions
flowproxy sessions list --json
flowproxy sessions list --limit N --host H --method M --status S --search Q --json
flowproxy sessions get <uuid> --json
flowproxy sessions clear --json

# Replay
flowproxy replay <uuid> --json
flowproxy replay <uuid> [--method M] [--header K:V] [--body B] --json

# Reverse proxy
flowproxy reverse-proxy list --json
flowproxy reverse-proxy add --name N --local-port N --upstream URL --json
flowproxy reverse-proxy remove <uuid> --json
```

---

## Important Notes for Agents

- **Get the full UUID first.** The `id` field in `sessions list --json` is always the full UUID. Use it directly for `get` and `replay`.
- **`state: "Pending"` sessions** are still in-flight. If you see them, wait and re-fetch.
- **`status: null`** means the request never got a response (network error). Check the `error` field.
- **`responseBody` can be large.** For binary or media responses it may not be valid UTF-8 and will be `null`.
- **Sessions are not persisted.** If the service restarts, all sessions are lost.
- **The proxy port defaults to 8888.** Tell the user to set their system/app proxy to `127.0.0.1:8888` (or whatever port was passed to `proxy start`).
