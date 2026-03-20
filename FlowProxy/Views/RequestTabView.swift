import SwiftUI

struct RequestTabView: View {
    let session: ProxySession
    @State private var showRaw: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Request line
                requestLine

                Divider().padding(.vertical, 8)

                // Query parameters (if any)
                if let qs = queryParams, !qs.isEmpty {
                    querySection(qs)
                    Divider().padding(.vertical, 8)
                }

                // Request body
                bodySection
            }
            .padding(12)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: - Request Line

    private var requestLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(session.method)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(session.methodColor)
                    .cornerRadius(5)

                Text(session.fullURL)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
            }

            // Protocol badge
            HStack(spacing: 6) {
                Label(session.sessionProtocol.rawValue, systemImage: session.sessionProtocol == .https ? "lock.fill" : "lock.open")
                    .font(.caption)
                    .foregroundColor(session.sessionProtocol == .https ? .green : .orange)

                if let tls = session.tlsMetadata {
                    Text(tls.version)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(tls.cipherSuite)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Query Parameters

    private var queryParams: [(String, String)]? {
        guard let qRange = session.path.range(of: "?"),
              !session.path[qRange.upperBound...].isEmpty else { return nil }
        let qs = String(session.path[qRange.upperBound...])
        let pairs = qs.components(separatedBy: "&")
        return pairs.compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let key = kv[0].removingPercentEncoding ?? kv[0]
            let value = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
            return (key, value)
        }
    }

    private func querySection(_ params: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Query Parameters")
            ForEach(params, id: \.0) { key, value in
                HStack(alignment: .top, spacing: 8) {
                    Text(key)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.blue)
                        .frame(minWidth: 120, alignment: .leading)
                    Text(value)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundColor(.primary)
                }
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: - Body Section

    @ViewBuilder
    private var bodySection: some View {
        if let body = session.requestBody, !body.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    sectionHeader("Request Body")
                    Spacer()
                    Toggle("Raw", isOn: $showRaw)
                        .toggleStyle(.button)
                        .font(.caption)
                    copyButton(text: session.requestBodyString ?? "")
                }

                let ct = session.requestHeaders["Content-Type"] ?? session.requestHeaders["content-type"] ?? ""
                BodyContentView(
                    data: body,
                    contentType: ct,
                    showRaw: showRaw
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                sectionHeader("Request Body")
                Text("No request body")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func copyButton(text: String) -> some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .help("Copy body")
    }
}

// MARK: - Body Content View
struct BodyContentView: View {
    let data: Data
    let contentType: String
    let showRaw: Bool

    @State private var displayText: String?

    private var isImage: Bool { contentType.hasPrefix("image/") }
    private var isJSON:  Bool { contentType.contains("json") }

    var body: some View {
        Group {
            if isImage {
                imageView
            } else if let text = displayText {
                if isJSON && !showRaw {
                    SyntaxHighlightedTextView(text: text, language: .json)
                } else {
                    plainView(text)
                }
            } else {
                Color(NSColor.controlBackgroundColor)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .cornerRadius(6)
                    .overlay(ProgressView().scaleEffect(0.7))
            }
        }
        .task(id: showRaw) {
            displayText = nil
            displayText = await makeDisplayText(data: data, contentType: contentType, showRaw: showRaw)
        }
    }

    private var imageView: some View {
        Group {
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 400, maxHeight: 400)
                    .cornerRadius(8)
            } else {
                Text("Could not display image").foregroundColor(.secondary)
            }
        }
    }

    private func plainView(_ text: String) -> some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}

private let displayCharLimit = 100_000   // chars shown in the text view
private let prettyPrintLimit = 200_000   // bytes — skip pretty-print above this
private let highlightLimit   =  80_000   // chars — skip syntax highlight above this

private func makeDisplayText(data: Data, contentType: String, showRaw: Bool) async -> String {
    await Task.detached(priority: .userInitiated) {
        if showRaw {
            if let str = String(data: data, encoding: .utf8) {
                return truncated(str)
            }
            // hex dump for binary
            var result = ""
            let bytes = [UInt8](data)
            let limit = min(bytes.count, 512)
            for i in stride(from: 0, to: limit, by: 16) {
                let end = min(i + 16, limit)
                let hex = bytes[i..<end].map { String(format: "%02x", $0) }.joined(separator: " ")
                let asc = String(bytes[i..<end].map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
                result += String(format: "%04x  %-48s  %@\n", i, hex, asc)
            }
            if bytes.count > 512 { result += "\n... (\(bytes.count - 512) more bytes)" }
            return result
        }
        if contentType.contains("json") {
            // Only pretty-print if the payload is small enough
            if data.count <= prettyPrintLimit,
               let obj    = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let str    = String(data: pretty, encoding: .utf8) {
                return truncated(str)
            }
            // Fallback: show raw JSON text
            if let str = String(data: data, encoding: .utf8) { return truncated(str) }
        }
        if let str = String(data: data, encoding: .utf8) { return truncated(str) }
        return "<binary: \(data.count) bytes>"
    }.value
}

private func truncated(_ s: String) -> String {
    guard s.count > displayCharLimit else { return s }
    let idx = s.index(s.startIndex, offsetBy: displayCharLimit)
    return String(s[..<idx]) + "\n\n… (\(s.count - displayCharLimit) more characters, save to file to view full response)"
}

// MARK: - Syntax Highlighted Text View
struct SyntaxHighlightedTextView: View {
    enum Language { case json, xml, html }

    let text: String
    let language: Language

    @State private var highlighted: AttributedString?

    var body: some View {
        ScrollView(.vertical) {
            Text(highlighted ?? AttributedString(text))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .task(id: text) {
            guard language == .json, text.count <= highlightLimit else {
                highlighted = AttributedString(text); return
            }
            let t = text
            let result = await Task.detached(priority: .userInitiated) { jsonHighlight(t) }.value
            if !Task.isCancelled { highlighted = result }
        }
    }
}

private func jsonHighlight(_ input: String) -> AttributedString {
    var result  = AttributedString()
    var current = ""
    var inString = false
    var escaped  = false

    func flush(_ color: Color? = nil) {
        guard !current.isEmpty else { return }
        var attr = AttributedString(current)
        if let c = color { attr.foregroundColor = c }
        result += attr
        current = ""
    }

    let structural: Set<Character> = ["{", "}", "[", "]", ":", ","]
    for ch in input {
        if escaped { current.append(ch); escaped = false; continue }
        if ch == "\\" && inString { current.append(ch); escaped = true; continue }
        if ch == "\"" {
            if inString { current.append(ch); flush(.green); inString = false }
            else        { flush(); inString = true; current.append(ch) }
            continue
        }
        if inString { current.append(ch); continue }
        if structural.contains(ch) {
            flush()
            var attr = AttributedString(String(ch)); attr.foregroundColor = .orange
            result += attr
        } else {
            current.append(ch)
        }
    }
    flush()
    return result
}
