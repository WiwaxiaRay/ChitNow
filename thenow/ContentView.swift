import SwiftUI

let chitNowWebsiteURL = URL(string: "https://wiwaxiaray.github.io/ChitNowWeb/")!

struct ContentView: View {
    @State private var isPaired          = KeychainHelper.isConfigured
    @State private var showCertAlert     = false

    var body: some View {
        Group {
            if isPaired {
                ActiveView(onUnpair: unpair)
            } else {
                PairingView(onPaired: { isPaired = true })
            }
        }
        .alert("Certificate Changed", isPresented: $showCertAlert) {
            Button("Re-pair Now") {
                unpair()
            }
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text("The broker's TLS certificate no longer matches the stored fingerprint. This happens when the broker is reinstalled or the certificate is regenerated. Re-pair to restore the connection.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .certMismatch)) { _ in
            guard isPaired else { return }
            showCertAlert = true
        }
    }

    private func unpair() {
        let relayCredentials = RelayClient.currentCredentials()
        Task {
            if let relayCredentials {
                _ = await RelayClient.revoke(credentials: relayCredentials)
            }
            await BrokerClient.deleteRelayCredentials()
            await MainActor.run {
                KeychainHelper.clear()
                isPaired = false
            }
        }
    }
}

// MARK: - Active

struct ActiveView: View {
    var onUnpair: () -> Void
    @State private var showDiagnostics   = false
    @State private var showUnpairConfirm = false
    @State private var watchApprovalsEnabled = ApprovalRoutingSettings.watchApprovalsEnabled
    @State private var routingLoaded = false
    @State private var routingUpdating = false
    @State private var routingError: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("thenow")
                .font(.title2.bold())

            Text("Agent approval guard active")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Use Apple Watch for approvals", isOn: Binding(
                    get: { watchApprovalsEnabled },
                    set: { enabled in
                        Task { await updateApprovalRouting(enabled) }
                    }
                ))
                .disabled(!routingLoaded || routingUpdating)

                Text(watchApprovalsEnabled
                     ? "High-risk commands wait for approval on Apple Watch."
                     : "High-risk commands use the native Claude Code or Codex approval screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let routingError {
                    Text(routingError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal)

            if let url = KeychainHelper.brokerURL {
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 20) {
                Button {
                    showDiagnostics = true
                } label: {
                    Label("Diagnostics", systemImage: "network")
                        .font(.footnote)
                }

                Button("Unpair", role: .destructive) {
                    showUnpairConfirm = true
                }
                .font(.footnote)
            }
            .padding(.top, 4)

            Link(destination: chitNowWebsiteURL) {
                Label("Website & Setup Guide", systemImage: "safari")
                    .font(.footnote)
            }
        }
        .padding()
        .task { await loadApprovalRouting() }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
        }
        .confirmationDialog("Remove pairing?", isPresented: $showUnpairConfirm, titleVisibility: .visible) {
            Button("Unpair", role: .destructive, action: onUnpair)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to scan the QR code again to reconnect.")
        }
    }

    private func loadApprovalRouting() async {
        let enabled = await BrokerClient.fetchWatchApprovalsEnabled()
        await MainActor.run {
            if let enabled {
                watchApprovalsEnabled = enabled
                routingError = nil
            } else {
                routingError = "Could not load approval routing from Mac."
            }
            routingLoaded = true
        }
    }

    private func updateApprovalRouting(_ enabled: Bool) async {
        await MainActor.run {
            routingUpdating = true
            routingError = nil
        }
        let saved = await BrokerClient.setWatchApprovalsEnabled(enabled)
        await MainActor.run {
            if saved {
                watchApprovalsEnabled = enabled
            } else {
                routingError = "Could not update Mac. Approval routing was not changed."
            }
            routingUpdating = false
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsView: View {
    @State private var status: Status = .idle
    @Environment(\.dismiss) private var dismiss

    enum Status: Equatable {
        case idle
        case checking
        case ok(latencyMs: Int)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Broker") {
                    row("URL", value: KeychainHelper.brokerURL ?? "—")
                    row("API Key", value: maskedKey(KeychainHelper.apiKey))
                    row("Cert fingerprint", value: shortFP(KeychainHelper.certFingerprint))
                }

                Section("Connection") {
                    HStack {
                        Text("Status")
                        Spacer()
                        statusView
                    }
                    Button(status == .checking ? "Checking…" : "Test Connection") {
                        Task { await runCheck() }
                    }
                    .disabled(status == .checking)
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await runCheck() }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            Text("—").foregroundStyle(.secondary)
        case .checking:
            ProgressView().scaleEffect(0.8)
        case .ok(let ms):
            Label("\(ms) ms", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }

    private func runCheck() async {
        status = .checking
        let (reachable, ms) = await BrokerClient.checkHealth()
        status = reachable ? .ok(latencyMs: ms) : .failed("Unreachable")
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func maskedKey(_ key: String?) -> String {
        guard let key, key.count >= 8 else { return "—" }
        return String(key.prefix(4)) + "••••" + String(key.suffix(4))
    }

    private func shortFP(_ fp: String?) -> String {
        guard let fp, fp.count >= 12 else { return "—" }
        return "…" + String(fp.suffix(12))
    }
}

#Preview {
    ContentView()
}
