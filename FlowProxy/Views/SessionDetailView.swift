import SwiftUI

struct SessionDetailView: View {
    let session: ProxySession?
    @State private var selectedTab: DetailTab = .request

    enum DetailTab: String, CaseIterable, Identifiable {
        case request = "Request"
        case response = "Response"
        case headers = "Headers"
        case cookies = "Cookies"
        case timing = "Timing"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .request: return "arrow.up.circle"
            case .response: return "arrow.down.circle"
            case .headers: return "list.bullet.rectangle"
            case .cookies: return "doc.badge.gearshape"
            case .timing: return "clock"
            }
        }
    }

    var body: some View {
        if let session = session {
            VStack(spacing: 0) {
                // URL bar
                urlBar(session: session)

                Divider()

                // Tab picker
                tabBar

                Divider()

                // Tab content
                tabContent(session: session)
            }
        } else {
            emptyState
        }
    }

    // MARK: - URL Bar

    private func urlBar(session: ProxySession) -> some View {
        HStack(spacing: 8) {
            // Method + Status
            HStack(spacing: 6) {
                Text(session.method)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(session.methodColor)
                    .cornerRadius(5)

                if let code = session.responseStatusCode {
                    Text("\(code)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(session.statusColor)
                }
            }

            Divider().frame(height: 20)

            // URL
            HStack(spacing: 4) {
                if session.sessionProtocol == .https {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 11))
                }
                Text(session.fullURL)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Duration + size
            if let dur = session.duration {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(session.formattedDuration)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    if session.formattedSize != "-" {
                        Text(session.formattedSize)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Copy URL button
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.fullURL, forType: .string)
            }) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy URL")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases) { tab in
                Button(action: { selectedTab = tab }) {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11))
                        Text(tab.rawValue)
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)

                if tab != DetailTab.allCases.last {
                    Divider()
                        .frame(height: 20)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func tabContent(session: ProxySession) -> some View {
        switch selectedTab {
        case .request:
            RequestTabView(session: session)
        case .response:
            ResponseTabView(session: session)
        case .headers:
            HeadersTabView(session: session)
        case .cookies:
            CookiesTabView(session: session)
        case .timing:
            TimingTabView(session: session)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            Text("Select a Session")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Click on a session in the list to view its details")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Preview
#Preview {
    let session = ProxySession(
        sessionProtocol: .https,
        host: "api.example.com",
        path: "/v1/users",
        method: "GET",
        requestHeaders: ["Accept": "application/json", "Authorization": "Bearer tok123"]
    )
    session.responseStatusCode = 200
    session.responseHeaders = ["Content-Type": "application/json", "X-Rate-Limit": "100"]
    session.responseBody = """
    {
      "users": [
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
      ],
      "total": 2
    }
    """.data(using: .utf8)
    session.duration = 0.234
    session.state = .complete

    return SessionDetailView(session: session)
        .frame(width: 600, height: 500)
}
