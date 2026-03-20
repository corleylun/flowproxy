import SwiftUI

struct TimingTabView: View {
    let session: ProxySession

    private var timing: TimingInfo? { session.timing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Total duration header
                totalDurationView

                Divider()

                // Timeline chart
                if let timing = timing {
                    timelineChart(timing: timing)
                } else if let duration = session.duration {
                    simpleDurationView(duration: duration)
                } else {
                    noTimingView
                }

                Divider()

                // Raw timing values
                if let timing = timing {
                    rawTimingTable(timing: timing)
                }
            }
            .padding(16)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: - Total Duration

    private var totalDurationView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total Duration")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text(session.formattedDuration)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
            }

            Spacer()

            if let code = session.responseStatusCode {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Status")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Text("\(code)")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(session.statusColor)
                }
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text("Size")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text(session.formattedSize)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
            }
        }
    }

    // MARK: - Timeline Chart

    private struct TimingSegment {
        let label: String
        let duration: TimeInterval
        let color: Color
        let icon: String
    }

    private func timelineChart(timing: TimingInfo) -> some View {
        let segments = buildSegments(timing: timing)
        let total = session.duration ?? segments.map(\.duration).reduce(0, +)

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Timeline")

            if total > 0 {
                // Bar chart
                VStack(spacing: 8) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.duration > 0 {
                            timelineRow(segment: segment, total: total)
                        }
                    }
                }
            }
        }
    }

    private func timelineRow(segment: TimingSegment, total: TimeInterval) -> some View {
        HStack(spacing: 8) {
            // Label
            HStack(spacing: 5) {
                Image(systemName: segment.icon)
                    .font(.system(size: 10))
                    .foregroundColor(segment.color)
                    .frame(width: 14)
                Text(segment.label)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 120, alignment: .leading)
            }

            // Bar
            GeometryReader { geo in
                let fraction = CGFloat(segment.duration / total)
                let width = max(2, geo.size.width * fraction)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: 16)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(segment.color)
                        .frame(width: width, height: 16)
                }
            }
            .frame(height: 16)

            // Duration
            Text(formatDuration(segment.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }

    private func buildSegments(timing: TimingInfo) -> [TimingSegment] {
        var segments: [TimingSegment] = []

        if let d = timing.dnsDuration, d > 0 {
            segments.append(.init(label: "DNS Lookup", duration: d, color: .purple, icon: "globe"))
        }
        if let d = timing.connectDuration, d > 0 {
            segments.append(.init(label: "TCP Connect", duration: d, color: .blue, icon: "network"))
        }
        if let d = timing.tlsDuration, d > 0 {
            segments.append(.init(label: "TLS Handshake", duration: d, color: .green, icon: "lock"))
        }
        if let d = timing.ttfb, d > 0 {
            segments.append(.init(label: "Waiting (TTFB)", duration: d, color: .orange, icon: "hourglass"))
        }
        if let d = timing.downloadDuration, d > 0 {
            segments.append(.init(label: "Download", duration: d, color: .teal, icon: "arrow.down"))
        }

        // If no timing breakdowns but we have total
        if segments.isEmpty, let total = session.duration, total > 0 {
            segments.append(.init(label: "Total", duration: total, color: .accentColor, icon: "clock"))
        }

        return segments
    }

    // MARK: - Simple Duration View

    private func simpleDurationView(duration: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Timeline")
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .foregroundColor(.accentColor)
                Text("Total Request Duration")
                    .font(.system(size: 12))
                Spacer()
                Text(formatDuration(duration))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            Text("Detailed timing breakdown not available")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Raw Timing Table

    private func rawTimingTable(timing: TimingInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Timing Details")

            VStack(spacing: 0) {
                timingRow("Request Start", date: timing.connectStart)
                timingRow("DNS Start", date: timing.dnsStart)
                timingRow("DNS End", date: timing.dnsEnd)
                timingRow("TCP Connect", date: timing.connectStart)
                timingRow("TCP Connected", date: timing.connectEnd)
                timingRow("TLS Start", date: timing.tlsStart)
                timingRow("TLS Complete", date: timing.tlsEnd)
                timingRow("Request Sent", date: timing.requestSent)
                timingRow("First Byte", date: timing.firstByte)
                timingRow("Response End", date: timing.responseEnd)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
        }
    }

    @ViewBuilder
    private func timingRow(_ label: String, date: Date?) -> some View {
        if let date = date {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 140, alignment: .leading)
                Spacer()
                Text(formatTimestamp(date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider().padding(.leading, 10)
        }
    }

    // MARK: - No Timing

    private var noTimingView: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No Timing Data")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Timing information is not available for this session")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        if d < 0.001 { return String(format: "%.0fµs", d * 1_000_000) }
        if d < 1.0 { return String(format: "%.1fms", d * 1000) }
        return String(format: "%.3fs", d)
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
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
    session.duration = 0.456

    var timing = TimingInfo()
    timing.connectStart = Date()
    timing.dnsStart = Date()
    timing.dnsEnd = Date().addingTimeInterval(0.012)
    timing.connectStart = Date().addingTimeInterval(0.012)
    timing.connectEnd = Date().addingTimeInterval(0.045)
    timing.tlsStart = Date().addingTimeInterval(0.045)
    timing.tlsEnd = Date().addingTimeInterval(0.123)
    timing.requestSent = Date().addingTimeInterval(0.123)
    timing.firstByte = Date().addingTimeInterval(0.345)
    timing.responseEnd = Date().addingTimeInterval(0.456)
    session.timing = timing
    session.state = .complete

    return TimingTabView(session: session)
        .frame(width: 600, height: 500)
}
