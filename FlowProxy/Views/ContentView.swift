import SwiftUI

struct ContentView: View {
    @EnvironmentObject var trafficStore: TrafficStore
    @EnvironmentObject var viewModel: ProxyViewModel

    @State private var selectedSession: ProxySession? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var portText: String = "8888"

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: session list
            SessionListView(selectedSession: $selectedSession)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 500)
                .toolbar {
                    //ToolbarItemGroup(placement: .navigation) {
                    //    filterMenu
                    //}
                }
        } detail: {
            // Detail: session info
            SessionDetailView(session: selectedSession)
        }
        .toolbar {
            // Start/Stop button
            ToolbarItem(placement: .primaryAction) {
                startStopButton
            }

            // Port field
            ToolbarItem(placement: .primaryAction) {
                portField
            }

            // Search
            ToolbarItem(placement: .primaryAction) {
                searchField
            }

            // Clear
            ToolbarItem(placement: .primaryAction) {
                Button(action: { trafficStore.clearSessions() }) {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear all sessions (⌘K)")
            }

            // CA Export
            ToolbarItem(placement: .secondaryAction) {
                Button(action: { viewModel.exportCACertificate() }) {
                    Label("Export CA", systemImage: "certificate")
                }
                .help("Export CA Certificate for HTTPS interception")
            }

            // Reverse Proxy
            // Disable this function first
            /*ToolbarItem(placement: .secondaryAction) {
                Button(action: { viewModel.isShowingReverseProxy = true }) {
                    Label("Reverse Proxy", systemImage: "arrow.triangle.swap")
                }
                .help("Manage Reverse Proxy Rules")
            }*/
        }
        .navigationTitle("FlowProxy")
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .sheet(isPresented: $viewModel.isShowingReverseProxy) {
            ReverseProxySettingsView()
                .environmentObject(viewModel)
        }
        .alert("CA Certificate", isPresented: $viewModel.isShowingCAExport) {
            Button("OK") { }
        } message: {
            Text(viewModel.caExportMessage)
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil), presenting: viewModel.errorMessage) { _ in
            Button("OK") { viewModel.errorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .onAppear {
            portText = "\(viewModel.port)"
        }
    }

    // MARK: - Toolbar Components

    private var startStopButton: some View {
        Button(action: { viewModel.toggleProxy() }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(viewModel.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(viewModel.isRunning ? "Stop" : "Start")
                    .fontWeight(.medium)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.isRunning ? .red : .green)
        .help(viewModel.isRunning ? "Stop proxy (⌘R)" : "Start proxy (⌘R)")
    }

    private var portField: some View {
        HStack(spacing: 4) {
            Text("Port:")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            TextField("Port", text: $portText)
                .frame(width: 55)
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.isRunning)
                .onChange(of: portText) { newVal in
                    if let p = Int(newVal), p > 0 && p < 65536 {
                        viewModel.port = p
                    }
                }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Filter sessions...", text: $trafficStore.searchText)
                .frame(width: 180)
                .textFieldStyle(.roundedBorder)
            if !trafficStore.searchText.isEmpty {
                Button(action: { trafficStore.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Button("All Methods") {
                trafficStore.filterMethod = nil
            }
            Divider()
            ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { method in
                Button(method) {
                    trafficStore.filterMethod = method
                }
            }
        } label: {
            Label(trafficStore.filterMethod ?? "Method", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Filter by HTTP method")
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            // Status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isRunning ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(viewModel.statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Divider()
                .frame(height: 12)

            // Session count
            Text("\(trafficStore.filteredSessions.count) of \(trafficStore.totalCount) sessions")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            if trafficStore.errorCount > 0 {
                Divider()
                    .frame(height: 12)
                Label("\(trafficStore.errorCount) errors", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            Spacer()

            // Active filters indicator
            if trafficStore.filterMethod != nil || trafficStore.filterHost != nil || !trafficStore.searchText.isEmpty {
                Button("Clear Filters") {
                    trafficStore.filterMethod = nil
                    trafficStore.filterHost = nil
                    trafficStore.searchText = ""
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

// MARK: - Preview
#Preview {
    ContentView()
        .environmentObject(TrafficStore())
        .environmentObject(ProxyViewModel(trafficStore: TrafficStore()))
        .frame(width: 900, height: 600)
}
