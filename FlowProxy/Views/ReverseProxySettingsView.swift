import SwiftUI

struct ReverseProxySettingsView: View {
    @EnvironmentObject var viewModel: ProxyViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showAddSheet: Bool = false
    @State private var addName: String = ""
    @State private var addPort: String = ""
    @State private var addUpstream: String = ""
    @State private var addError: String? = nil
    @State private var selectedRule: ReverseProxyRule? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reverse Proxy Rules")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Forward local ports to upstream servers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            if viewModel.reverseProxyRules.isEmpty {
                emptyState
            } else {
                rulesList
            }

            Divider()

            // Bottom toolbar
            HStack {
                Button(action: { showAddSheet = true }) {
                    Label("Add Rule", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                if let selected = selectedRule {
                    Button(role: .destructive, action: {
                        viewModel.removeReverseProxyRule(selected)
                        selectedRule = nil
                    }) {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
        }
        .frame(width: 560, height: 420)
        .sheet(isPresented: $showAddSheet) {
            addRuleSheet
        }
    }

    // MARK: - Rules List

    private var rulesList: some View {
        List(selection: $selectedRule) {
            ForEach(viewModel.reverseProxyRules) { rule in
                ruleRow(rule: rule)
                    .tag(rule)
            }
            .onDelete { indices in
                for idx in indices {
                    viewModel.removeReverseProxyRule(viewModel.reverseProxyRules[idx])
                }
            }
        }
        .listStyle(.inset)
    }

    private func ruleRow(rule: ReverseProxyRule) -> some View {
        HStack(spacing: 10) {
            // Enable toggle
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in viewModel.toggleReverseProxyRule(rule) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .scaleEffect(0.8)

            // Port arrow
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // Local port badge
                    Text(":\(rule.localPort)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(rule.isEnabled ? Color.accentColor : Color.secondary)
                        .cornerRadius(5)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    // Upstream
                    HStack(spacing: 3) {
                        if rule.isHTTPS {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                        }
                        Text(rule.upstreamURL.absoluteString)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                    }
                }

                // Name
                if !rule.name.isEmpty {
                    Text(rule.name)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Status
            if viewModel.isRunning && rule.isEnabled {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Active")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
            }

            // Rewrite count
            if !rule.rewriteEntries.isEmpty {
                Label("\(rule.rewriteEntries.count) rewrites", systemImage: "arrow.2.squarepath")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
        .opacity(rule.isEnabled ? 1.0 : 0.5)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Reverse Proxy Rules")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Add a rule to forward traffic from a local port to an upstream server.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button(action: { showAddSheet = true }) {
                Label("Add First Rule", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Add Rule Sheet

    private var addRuleSheet: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Text("Add Reverse Proxy Rule")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section {
                    TextField("Name (optional)", text: $addName)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("Rule Name")
                }

                Section {
                    HStack {
                        Text("localhost:")
                            .foregroundColor(.secondary)
                        TextField("8080", text: $addPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                } header: {
                    Text("Local Port")
                    Text("The port FlowProxy will listen on locally")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    TextField("https://api.example.com", text: $addUpstream)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("Upstream URL")
                    Text("The target server to forward requests to")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let error = addError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 280)

            Divider()

            HStack {
                Button("Cancel") {
                    resetAddForm()
                    showAddSheet = false
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Add Rule") {
                    submitAddRule()
                }
                .buttonStyle(.borderedProminent)
                .disabled(addPort.isEmpty || addUpstream.isEmpty)
            }
            .padding()
        }
        .frame(width: 420)
    }

    // MARK: - Actions

    private func submitAddRule() {
        addError = nil

        guard let port = Int(addPort), port > 0 && port < 65536 else {
            addError = "Invalid port number (must be 1-65535)"
            return
        }

        let upstreamStr = addUpstream.trimmingCharacters(in: .whitespaces)
        guard !upstreamStr.isEmpty else {
            addError = "Upstream URL is required"
            return
        }

        // Add http:// if no scheme
        let fullUpstream = upstreamStr.contains("://") ? upstreamStr : "http://\(upstreamStr)"

        let success = viewModel.addReverseProxyRule(
            name: addName.trimmingCharacters(in: .whitespaces),
            localPort: port,
            upstreamURLString: fullUpstream
        )

        if success {
            resetAddForm()
            showAddSheet = false
        } else {
            addError = viewModel.errorMessage
            viewModel.errorMessage = nil
        }
    }

    private func resetAddForm() {
        addName = ""
        addPort = ""
        addUpstream = ""
        addError = nil
    }
}

// MARK: - Preview
#Preview {
    ReverseProxySettingsView()
        .environmentObject({
            let vm = ProxyViewModel(trafficStore: TrafficStore())
            _ = vm.addReverseProxyRule(name: "Local API", localPort: 8080, upstreamURLString: "https://api.example.com")
            _ = vm.addReverseProxyRule(name: "Dev Backend", localPort: 3000, upstreamURLString: "http://localhost:9000")
            return vm
        }())
}
