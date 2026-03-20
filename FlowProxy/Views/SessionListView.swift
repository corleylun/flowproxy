import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var trafficStore: TrafficStore
    @Binding var selectedSession: ProxySession?

    var body: some View {
        listContent
    }

    private var categoryFilterBar: some View {
        HStack(spacing: 5) {
            ForEach(ContentCategory.allCases, id: \.self) { cat in
                categoryChip(cat)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func categoryChip(_ cat: ContentCategory) -> some View {
        let active = trafficStore.filterContentCategory == cat
        return Text(cat.rawValue)
            .font(.system(size: 11, weight: active ? .semibold : .regular))
            .foregroundColor(active ? .white : .primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(active ? Color.accentColor : Color(NSColor.controlBackgroundColor))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(active ? Color.clear : Color(NSColor.separatorColor), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture { trafficStore.filterContentCategory = cat }
    }

    private var listContent: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedSession) {
                Color.clear.frame(height: 0)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .id("top")
                if trafficStore.filteredSessions.isEmpty {
                    emptyState
                } else {
                    ForEach(trafficStore.filteredSessions) { session in
                        SessionRowView(session: session)
                            .tag(session)
                            .contextMenu {
                                contextMenuItems(for: session)
                            }
                    }
                }
                Color.clear.frame(height: 32)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    categoryFilterBar
                    Divider()
                }
            }
            .onChange(of: trafficStore.filterContentCategory) { _ in
                proxy.scrollTo("top", anchor: .top)
            }
            .onChange(of: trafficStore.filteredSessions) { newSessions in
                if let selected = selectedSession,
                   !newSessions.contains(where: { $0.id == selected.id }) {
                    selectedSession = nil
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
                .padding(.top, 40)
            Text("No Sessions")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Start the proxy and configure your browser\nor app to use it as an HTTP proxy.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for session: ProxySession) -> some View {
        Button("Copy URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.fullURL, forType: .string)
        }

        Button("Copy as cURL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(curlCommand(for: session), forType: .string)
        }

        Divider()

        Button("Filter by Host") {
            trafficStore.filterHost = session.host
        }

        Button("Filter by Method") {
            trafficStore.filterMethod = session.method
        }

        Divider()

        Button("Remove Session", role: .destructive) {
            trafficStore.removeSession(session)
            if selectedSession?.id == session.id {
                selectedSession = nil
            }
        }
    }

    // MARK: - cURL Generation

    private func curlCommand(for session: ProxySession) -> String {
        var parts = ["curl -v"]

        if session.method != "GET" {
            parts.append("-X \(session.method)")
        }

        for (key, value) in session.requestHeaders.sorted(by: { $0.key < $1.key }) {
            let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
            parts.append("-H '\(key): \(escaped)'")
        }

        if let body = session.requestBodyString {
            let escaped = body.replacingOccurrences(of: "'", with: "'\"'\"'")
            parts.append("--data '\(escaped)'")
        }

        parts.append("'\(session.fullURL)'")
        return parts.joined(separator: " \\\n  ")
    }
}

// MARK: - Preview
#Preview {
    let store = TrafficStore()
    let session = ProxySession(
        sessionProtocol: .https,
        host: "api.example.com",
        path: "/v1/users?page=1",
        method: "GET",
        requestHeaders: ["User-Agent": "TestApp/1.0"]
    )
    session.responseStatusCode = 200
    session.duration = 0.245
    store.addSession(session)

    return SessionListView(selectedSession: .constant(nil))
        .environmentObject(store)
        .frame(width: 300, height: 400)
}
