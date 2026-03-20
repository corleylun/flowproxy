import SwiftUI

struct SessionRowView: View {
    @ObservedObject var session: ProxySession

    var body: some View {
        HStack(spacing: 8) {
            // Method badge
            methodBadge

            // Main content
            VStack(alignment: .leading, spacing: 2) {
                // Host + Lock icon
                HStack(spacing: 4) {
                    if session.sessionProtocol == .https {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.green)
                    }
                    Text(session.host)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }

                // Path
                Text(session.path)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Right side
            VStack(alignment: .trailing, spacing: 2) {
                // Status code
                statusBadge

                // Duration + size
                HStack(spacing: 4) {
                    Text(session.formattedDuration)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)

                    if session.formattedSize != "-" {
                        Text(session.formattedSize)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                // Timestamp
                Text(formattedTime)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    // MARK: - Formatters

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private var formattedTime: String {
        Self.timeFormatter.string(from: session.timestamp)
    }

    // MARK: - Method Badge

    private var methodBadge: some View {
        Text(shortMethod)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(session.methodColor)
            .cornerRadius(4)
            .frame(minWidth: 36)
    }

    private var shortMethod: String {
        switch session.method.uppercased() {
        case "DELETE": return "DEL"
        case "OPTIONS": return "OPT"
        case "PATCH": return "PAT"
        default: return session.method.uppercased()
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var statusBadge: some View {
        switch session.state {
        case .pending:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 30, height: 14)
        case .error:
            if let code = session.responseStatusCode {
                Text("\(code)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(session.statusColor)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
        case .complete:
            if let code = session.responseStatusCode {
                Text("\(code)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(session.statusColor)
            }
        }
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 0) {
        let sessions: [(ProxyProtocol, String, String, String, Int?, TimeInterval?)] = [
            (.https, "api.github.com", "/repos/apple/swift", "GET", 200, 0.124),
            (.https, "api.example.com", "/v1/users", "POST", 201, 0.456),
            (.http, "cdn.example.com", "/assets/app.js", "GET", 304, 0.045),
            (.https, "auth.service.com", "/oauth/token", "POST", 401, 0.234),
            (.https, "api.broken.com", "/data", "GET", 500, 1.234),
        ]

        ForEach(Array(sessions.enumerated()), id: \.offset) { _, info in
            let s = ProxySession(sessionProtocol: info.0, host: info.1, path: info.2, method: info.3)
            let _ = { s.responseStatusCode = info.4; s.duration = info.5; s.state = .complete }()
            SessionRowView(session: s)
                .padding(.horizontal, 8)
            Divider()
        }
    }
    .frame(width: 320)
}
