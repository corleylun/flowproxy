import SwiftUI

struct CookiesTabView: View {
    let session: ProxySession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let reqCookies = session.requestCookies
                let resCookies = session.responseCookies

                // Request cookies
                cookieSection(
                    title: "Request Cookies (\(reqCookies.count))",
                    cookies: reqCookies,
                    isRequest: true
                )

                if !reqCookies.isEmpty && !resCookies.isEmpty {
                    Divider().padding(.vertical, 8)
                }

                // Response cookies
                cookieSection(
                    title: "Response Cookies / Set-Cookie (\(resCookies.count))",
                    cookies: resCookies,
                    isRequest: false
                )

                if reqCookies.isEmpty && resCookies.isEmpty {
                    emptyCookiesView
                }
            }
            .padding(12)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: - Cookie Section

    @ViewBuilder
    private func cookieSection(title: String, cookies: [HTTPCookie], isRequest: Bool) -> some View {
        if !cookies.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(title)

                ForEach(Array(cookies.enumerated()), id: \.offset) { _, cookie in
                    cookieCard(cookie: cookie, isRequest: isRequest)
                }
            }
        }
    }

    private func cookieCard(cookie: HTTPCookie, isRequest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cookie name + value
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cookie.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.blue)
                    Text(cookie.value)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                Spacer()

                // Security badges
                HStack(spacing: 4) {
                    if cookie.isSecure {
                        cookieBadge("Secure", color: .green)
                    }
                    if cookie.isHTTPOnly {
                        cookieBadge("HttpOnly", color: .orange)
                    }
                    if cookie.isSessionOnly {
                        cookieBadge("Session", color: .secondary)
                    }
                }
            }
            .padding(.bottom, 6)

            Divider()

            // Attributes grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 4) {
                if !cookie.domain.isEmpty {
                    cookieAttr(label: "Domain", value: cookie.domain)
                }
                if !cookie.path.isEmpty {
                    cookieAttr(label: "Path", value: cookie.path)
                }
                if let expires = cookie.expiresDate {
                    cookieAttr(label: "Expires", value: formatDate(expires))
                }
                if let maxAge = cookie.properties?[.maximumAge] as? String {
                    cookieAttr(label: "Max-Age", value: maxAge)
                }
                if let sameSite = cookie.properties?[.sameSitePolicy] as? String {
                    cookieAttr(label: "SameSite", value: sameSite)
                }
            }
            .padding(.top, 6)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .contextMenu {
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cookie.name, forType: .string)
            }
            Button("Copy Value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cookie.value, forType: .string)
            }
            Button("Copy as JSON") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cookieJSON(cookie), forType: .string)
            }
        }
    }

    private func cookieBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(color.opacity(0.3), lineWidth: 1)
            )
    }

    private func cookieAttr(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

    // MARK: - Empty State

    private var emptyCookiesView: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No Cookies")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("This request/response contains no cookies")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.bottom, 4)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func cookieJSON(_ cookie: HTTPCookie) -> String {
        var dict: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "httpOnly": cookie.isHTTPOnly,
            "session": cookie.isSessionOnly
        ]
        if let expires = cookie.expiresDate {
            dict["expires"] = ISO8601DateFormatter().string(from: expires)
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return ""
    }
}

// MARK: - Preview
#Preview {
    let session = ProxySession(
        sessionProtocol: .https,
        host: "example.com",
        path: "/",
        method: "GET",
        requestHeaders: ["Cookie": "session_id=abc123; user_prefs=dark_mode"]
    )
    session.responseHeaders = [
        "Set-Cookie": "auth_token=xyz789; Path=/; Secure; HttpOnly; Max-Age=3600"
    ]

    return CookiesTabView(session: session)
        .frame(width: 600, height: 500)
}
