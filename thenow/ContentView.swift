import SwiftUI

let chitNowWebsiteURL = URL(string: "https://wiwaxiaray.github.io/ChitNowWeb/")!

struct ContentView: View {
    @State private var isPaired          = KeychainHelper.isConfigured
    @State private var showCertAlert     = false
    @State private var showSettings      = false
    @AppStorage("appLanguage") private var language = AppLanguage.english

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isPaired {
                    ActiveView(onUnpair: unpair)
                } else {
                    PairingView(onPaired: { isPaired = true })
                }
            }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .padding(12)
                    .background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel("Settings")
            .padding(.top, 8)
            .padding(.trailing, 16)
        }
        .environment(\.locale, language.locale)
        .sheet(isPresented: $showSettings) {
            AppSettingsView(language: $language)
                .environment(\.locale, language.locale)
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
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.green)

                        Text("Approval guard active")
                            .font(.title2.bold())

                        Text("Choose where high-risk commands are approved.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("APPROVAL METHOD")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        if routingLoaded {
                            approvalModeButton(
                                title: "Apple Watch",
                                detail: "Approve or deny from your wrist.",
                                systemImage: "applewatch",
                                enabled: true
                            )

                            approvalModeButton(
                                title: "Claude Code / Codex",
                                detail: "Use the agent's native approval screen.",
                                systemImage: "terminal",
                                enabled: false
                            )
                        } else {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Loading approval settings from Mac…")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        }

                        if routingUpdating {
                            ProgressView("Updating approval method…")
                                .font(.caption)
                        }

                        if let routingError {
                            Label(routingError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("MAC CONNECTION")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 12) {
                            if let url = KeychainHelper.brokerURL {
                                Label {
                                    Text(url)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                } icon: {
                                    Image(systemName: "desktopcomputer")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            Button {
                                showDiagnostics = true
                            } label: {
                                Label("Connection Diagnostics", systemImage: "network")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Link(destination: chitNowWebsiteURL) {
                                Label("Website & Setup Guide", systemImage: "safari")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }

                    Button("Unpair This Mac", role: .destructive) {
                        showUnpairConfirm = true
                    }
                    .font(.footnote)
                }
                .padding()
            }
            .navigationTitle("ChitNow")
        }
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

    private func approvalModeButton(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        systemImage: String,
        enabled: Bool
    ) -> some View {
        Button {
            guard watchApprovalsEnabled != enabled else { return }
            Task { await updateApprovalRouting(enabled) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: watchApprovalsEnabled == enabled
                      ? "checkmark.circle.fill"
                      : "circle")
                    .font(.title2)
                    .foregroundStyle(watchApprovalsEnabled == enabled ? .green : .secondary)
            }
            .multilineTextAlignment(.leading)
            .padding()
            .background(
                watchApprovalsEnabled == enabled ? Color.green.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        watchApprovalsEnabled == enabled ? Color.green : Color.secondary.opacity(0.25),
                        lineWidth: watchApprovalsEnabled == enabled ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(routingUpdating)
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
