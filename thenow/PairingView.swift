import SwiftUI
import AVFoundation

// MARK: - QR payload

private struct PairingPayload: Decodable {
    let v:         Int
    let url:       String
    let pt:        String   // one-time pairing token
    let fp:        String
    let exp:       Int
    let sid:       String
    let relay_url: String?  // optional — present when broker has relay configured
}

private struct ConfirmResponse: Decodable {
    let status:     String
    let api_key:    String
    let broker_url: String
    let cert_fp:    String
}

// MARK: - PairingView

struct PairingView: View {
    var onPaired: () -> Void

    @State private var scanning    = false
    @State private var errorMsg:   String?
    @State private var confirming  = false
    @State private var setupToken  = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Pair with Mac")
                .font(.title2.bold())

            Text("Run bash install.sh on your Mac, open the private setup-token URL it prints, then scan the QR code below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("Approval method settings appear after pairing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("APPROVAL METHOD")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                disabledApprovalRow("Apple Watch", systemImage: "applewatch")
                disabledApprovalRow("Claude Code / Codex", systemImage: "terminal")
                Text("Pair with your Mac to choose a method.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)

            if confirming {
                ProgressView("Confirming…")
            } else {
                Button {
                    errorMsg = nil
                    scanning = true
                } label: {
                    Label("Scan QR Code", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
            }

            #if targetEnvironment(simulator)
            VStack(spacing: 10) {
                TextField("Setup token from install.sh", text: $setupToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                Button {
                    errorMsg = nil
                    confirming = true
                    Task { await pairSimulator() }
                } label: {
                    Label("Connect This Simulator", systemImage: "desktopcomputer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(setupToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 40)
            #endif

            Link(destination: chitNowWebsiteURL) {
                Label("Website & Setup Guide", systemImage: "safari")
                    .font(.footnote)
            }

            if let err = errorMsg {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            }
            .padding()
        }
        .sheet(isPresented: $scanning) {
            QRScannerView { result in
                scanning = false
                handleScan(result)
            }
        }
        #if targetEnvironment(simulator)
        .task { await autoPairSimulatorIfConfigured() }
        #endif
    }

    private func disabledApprovalRow(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack {
            Image(systemName: systemImage)
                .frame(width: 24)
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .foregroundStyle(.secondary)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func handleScan(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PairingPayload.self, from: data)
        else {
            errorMsg = "Invalid QR code"
            return
        }
        guard payload.v == 2 else {
            errorMsg = "Unsupported pairing version — refresh the Mac browser page"
            return
        }
        guard Int(Date().timeIntervalSince1970) < payload.exp else {
            errorMsg = "QR code expired — refresh the Mac browser page and try again"
            return
        }
        beginPairing(payload)
    }

    private func beginPairing(_ payload: PairingPayload) {
        confirming = true
        Task {
            // Register with relay Worker first (if relay URL is in QR payload)
            var relayCreds: RelayClient.Credentials? = nil
            if let relayURL = payload.relay_url, !relayURL.isEmpty {
                let deviceToken = await currentDeviceToken()
                if let token = deviceToken {
                    relayCreds = await RelayClient.registerOrUpdate(
                        deviceToken: token,
                        relayURL: relayURL,
                        rotateExisting: true
                    )
                }
            }

            let resp = await confirmWithBroker(payload: payload, relayCreds: relayCreds)
            await MainActor.run {
                confirming = false
                if let resp {
                    if let relayCreds {
                        RelayClient.commit(credentials: relayCreds)
                    }
                    KeychainHelper.save(
                        brokerURL:       resp.broker_url,
                        apiKey:          resp.api_key,
                        certFingerprint: resp.cert_fp
                    )
                    // Persist relay URL so AppDelegate can register with relay when APNs token arrives
                    if let relayURL = payload.relay_url, !relayURL.isEmpty {
                        KeychainHelper.setRelayURL(relayURL)
                    }
                    UIApplication.shared.registerForRemoteNotifications()
                    PhoneSessionManager.shared.shareCurrentContextWithWatch()
                    BrokerClient.discoverAndShareWithWatch()
                    onPaired()
                } else {
                    errorMsg = "Could not confirm with broker — check network or retry"
                }
            }
        }
    }

    #if targetEnvironment(simulator)
    private func autoPairSimulatorIfConfigured() async {
        guard !confirming,
              let token = ProcessInfo.processInfo.environment["THENOW_SETUP_TOKEN"],
              !token.isEmpty else { return }
        setupToken = token
        confirming = true
        await pairSimulator()
    }

    private func pairSimulator() async {
        let token = setupToken.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://localhost:8000/pair/bootstrap")
        components?.queryItems = [URLQueryItem(name: "setup_token", value: token)]
        guard let url = components?.url else {
            await simulatorPairingFailed("Invalid setup token")
            return
        }
        let delegate = SimulatorLocalhostDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try? JSONDecoder().decode(PairingPayload.self, from: data) else {
                await simulatorPairingFailed("Setup token was rejected by the local broker")
                return
            }
            await MainActor.run { beginPairing(payload) }
        } catch {
            await simulatorPairingFailed("Could not reach the local broker")
        }
    }

    @MainActor
    private func simulatorPairingFailed(_ message: String) {
        confirming = false
        errorMsg = message
    }
    #endif

    private func confirmWithBroker(payload: PairingPayload,
                                   relayCreds: RelayClient.Credentials?) async -> ConfirmResponse? {
        guard let url = URL(string: "\(payload.url)/pair/\(payload.sid)/confirm") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(payload.pt, forHTTPHeaderField: "X-Pairing-Token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        // Send relay credentials to broker so it can send push notifications via relay.
        var body: [String: String] = [:]
        if let creds = relayCreds {
            body["relay_url"]        = creds.relayURL
            body["installation_id"]  = creds.installationId
            body["relay_secret"]     = creds.relaySecret
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let delegate = PinnedSessionDelegate(fingerprint: payload.fp)
        let session  = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200,
              let result = try? JSONDecoder().decode(ConfirmResponse.self, from: data)
        else { return nil }
        return result
    }

    /// Returns the cached APNs device token if already registered (set by AppDelegate on registration).
    private func currentDeviceToken() async -> String? {
        (UIApplication.shared.delegate as? AppDelegate).flatMap { _ in AppDelegate.deviceToken }
    }
}

#if targetEnvironment(simulator)
private final class SimulatorLocalhostDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.host == "localhost",
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
#endif

// MARK: - QRScannerView

struct QRScannerView: UIViewControllerRepresentable {
    var onResult: (String) -> Void

    func makeUIViewController(context: Context) -> _ScannerVC {
        let vc = _ScannerVC()
        vc.onResult = onResult
        return vc
    }
    func updateUIViewController(_ vc: _ScannerVC, context: Context) {}
}

final class _ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onResult: ((String) -> Void)?
    private var session: AVCaptureSession?
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let s = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input  = try? AVCaptureDeviceInput(device: device),
              s.canAddInput(input) else {
            showError("Camera unavailable")
            return
        }
        s.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard s.canAddOutput(output) else { showError("Scanner unavailable"); return }
        s.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let prev = AVCaptureVideoPreviewLayer(session: s)
        prev.frame = view.bounds
        prev.videoGravity = .resizeAspectFill
        view.layer.addSublayer(prev)
        preview = prev

        session = s
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }

        // Close button
        let btn = UIButton(type: .close)
        btn.tintColor = .white
        btn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            btn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        btn.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let obj = objects.first as? AVMetadataMachineReadableCodeObject,
              let str = obj.stringValue else { return }
        session?.stopRunning()
        dismiss(animated: true) { [weak self] in
            self?.onResult?(str)
        }
    }

    private func showError(_ msg: String) {
        let lbl = UILabel()
        lbl.text = msg
        lbl.textColor = .white
        lbl.textAlignment = .center
        lbl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
