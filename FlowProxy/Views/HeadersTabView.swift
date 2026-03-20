import SwiftUI

struct HeadersTabView: View {
    let session: ProxySession
    @State private var searchText: String = ""
    @State private var copyToast: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("Filter headers...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Headers list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // Request headers
                    Section {
                        headersRows(session.requestHeaders.sorted(by: { $0.key < $1.key }))
                    } header: {
                        sectionHeader("Request Headers (\(filteredHeaders(session.requestHeaders).count))")
                    }

                    Divider().padding(.vertical, 4)

                    // Response headers
                    Section {
                        headersRows(session.responseHeaders.sorted(by: { $0.key < $1.key }))
                    } header: {
                        sectionHeader("Response Headers (\(filteredHeaders(session.responseHeaders).count))")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = copyToast {
                toastView(toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: copyToast)
    }

    // MARK: - Headers Rows

    @ViewBuilder
    private func headersRows(_ headers: [(key: String, value: String)]) -> some View {
        let filtered = headers.filter { header in
            guard !searchText.isEmpty else { return true }
            let q = searchText.lowercased()
            return header.key.lowercased().contains(q) || header.value.lowercased().contains(q)
        }

        if filtered.isEmpty {
            Text("No matching headers")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .italic()
                .padding(.vertical, 8)
                .padding(.leading, 4)
        } else {
            ForEach(filtered, id: \.key) { header in
                headerRow(key: header.key, value: header.value)
            }
        }
    }

    private func headerRow(key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.blue)
                .frame(minWidth: 140, maxWidth: 200, alignment: .leading)
                .lineLimit(1)
                .help(key)

            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Copy button
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                showToast("Copied \(key)")
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .opacity(0.6)
            }
            .buttonStyle(.plain)
            .help("Copy value")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.clear)
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            Button("Copy Header") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(key): \(value)", forType: .string)
            }
            Button("Copy Key") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: - Toast

    private func toastView(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.7))
            .cornerRadius(8)
            .padding(.bottom, 12)
    }

    private func showToast(_ message: String) {
        copyToast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copyToast = nil
        }
    }

    // MARK: - Helper

    private func filteredHeaders(_ headers: [String: String]) -> [(String, String)] {
        guard !searchText.isEmpty else { return headers.sorted(by: { $0.key < $1.key }) }
        let q = searchText.lowercased()
        return headers.filter { $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
            .sorted(by: { $0.key < $1.key })
    }
}

// MARK: - Preview
#Preview {
    let session = ProxySession(
        sessionProtocol: .https,
        host: "api.example.com",
        path: "/v1/data",
        method: "POST",
        requestHeaders: [
            "Content-Type": "application/json",
            "Authorization": "Bearer eyJhbGciOiJIUzI1NiJ9...",
            "Accept": "application/json",
            "User-Agent": "MyApp/1.0 (macOS 14.0)"
        ]
    )
    session.responseHeaders = [
        "Content-Type": "application/json; charset=utf-8",
        "X-Request-ID": "abc-123-def-456",
        "Cache-Control": "no-cache, no-store",
        "Strict-Transport-Security": "max-age=31536000; includeSubDomains"
    ]

    return HeadersTabView(session: session)
        .frame(width: 600, height: 500)
}
