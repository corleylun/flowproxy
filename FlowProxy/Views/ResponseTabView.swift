import SwiftUI

struct ResponseTabView: View {
    let session: ProxySession
    @State private var showRaw: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Status line
                statusLine

                Divider().padding(.vertical, 8)

                // Body
                bodySection
            }
            .padding(12)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: - Status Line

    private var statusLine: some View {
        HStack(spacing: 10) {
            if let code = session.responseStatusCode {
                // Status code badge
                Text("\(code)")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(session.statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(session.statusColor.opacity(0.12))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(session.statusColor.opacity(0.4), lineWidth: 1)
                    )

                // Status message
                Text(statusMessage(for: code))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(session.statusColor)
            } else if session.state == .pending {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Waiting for response...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else if session.state == .error {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                Text(session.error ?? "Request failed")
                    .font(.system(size: 13))
                    .foregroundColor(.red)
            }

            Spacer()

            // Meta info
            VStack(alignment: .trailing, spacing: 2) {
                if let dur = session.duration {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption)
                        Text(session.formattedDuration)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                }
                if session.formattedSize != "-" {
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                            .font(.caption)
                        Text(session.formattedSize)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Body Section

    @ViewBuilder
    private var bodySection: some View {
        if let body = session.responseBody, !body.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    sectionHeader("Response Body")
                    Spacer()
                    contentTypeLabel
                    Toggle("Raw", isOn: $showRaw)
                        .toggleStyle(.button)
                        .font(.caption)
                    copyButton
                    saveButton(body: body)
                }

                let ct = session.responseHeaders["Content-Type"] ?? session.responseHeaders["content-type"] ?? ""
                BodyContentView(
                    data: body,
                    contentType: ct,
                    showRaw: showRaw
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                sectionHeader("Response Body")
                Text("No response body")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 4)
            }
        }
    }

    private var contentTypeLabel: some View {
        let ct = session.responseHeaders["Content-Type"] ?? session.responseHeaders["content-type"] ?? ""
        let shortCT = ct.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ct
        return Text(shortCT)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(4)
    }

    private var copyButton: some View {
        Button(action: {
            let text = session.responseBodyString ?? ""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .help("Copy response body")
    }

    private func saveButton(body: Data) -> some View {
        Button(action: { saveBody(body) }) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .help("Save response body to file")
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func statusMessage(for code: Int) -> String {
        switch code {
        case 100: return "Continue"
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return HTTPURLResponse.localizedString(forStatusCode: code).capitalized
        }
    }

    private func saveBody(_ body: Data) {
        let panel = NSSavePanel()
        let ct = session.responseHeaders["Content-Type"] ?? session.responseHeaders["content-type"] ?? ""

        if ct.contains("json") {
            panel.nameFieldStringValue = "response.json"
        } else if ct.contains("html") {
            panel.nameFieldStringValue = "response.html"
        } else if ct.contains("xml") {
            panel.nameFieldStringValue = "response.xml"
        } else if ct.hasPrefix("image/jpeg") {
            panel.nameFieldStringValue = "response.jpg"
        } else if ct.hasPrefix("image/png") {
            panel.nameFieldStringValue = "response.png"
        } else {
            panel.nameFieldStringValue = "response.bin"
        }

        panel.title = "Save Response Body"
        if panel.runModal() == .OK, let url = panel.url {
            try? body.write(to: url)
        }
    }
}

// MARK: - Preview
#Preview {
    let session = ProxySession(
        sessionProtocol: .https,
        host: "api.example.com",
        path: "/data",
        method: "GET"
    )
    session.responseStatusCode = 200
    session.responseHeaders = ["Content-Type": "application/json"]
    session.responseBody = """
    {"status":"ok","data":[1,2,3],"meta":{"page":1,"total":100}}
    """.data(using: .utf8)
    session.duration = 0.345
    session.state = .complete

    return ResponseTabView(session: session)
        .frame(width: 600, height: 400)
}
