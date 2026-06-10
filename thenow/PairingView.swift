import SwiftUI
import AVFoundation

// MARK: - QR payload

private struct PairingPayload: Decodable {
    let v:   Int
    let url: String
    let key: String
    let fp:  String
    let exp: Int
    let sid: String
}

// MARK: - PairingView

struct PairingView: View {
    var onPaired: () -> Void

    @State private var scanning    = false
    @State private var errorMsg:   String?
    @State private var confirming  = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Pair with Mac")
                .font(.title2.bold())

            Text("On your Mac, open a browser and visit:\nhttps://localhost:8000/pair\nThen tap the button below to scan the QR code.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

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

            if let err = errorMsg {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
        .sheet(isPresented: $scanning) {
            QRScannerView { result in
                scanning = false
                handleScan(result)
            }
        }
    }

    private func handleScan(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PairingPayload.self, from: data)
        else {
            errorMsg = "Invalid QR code"
            return
        }
        guard payload.v == 1 else {
            errorMsg = "Unsupported pairing version"
            return
        }
        guard Int(Date().timeIntervalSince1970) < payload.exp else {
            errorMsg = "QR code expired — refresh the Mac browser page and try again"
            return
        }
        confirming = true
        Task {
            let ok = await confirmWithBroker(payload: payload)
            await MainActor.run {
                confirming = false
                if ok {
                    KeychainHelper.save(
                        brokerURL:       payload.url,
                        apiKey:          payload.key,
                        certFingerprint: payload.fp
                    )
                    // Propagate to Watch
                    BrokerClient.discoverAndShareWithWatch()
                    onPaired()
                } else {
                    errorMsg = "Could not confirm with broker — check network or retry"
                }
            }
        }
    }

    private func confirmWithBroker(payload: PairingPayload) async -> Bool {
        guard let url = URL(string: "\(payload.url)/pair/\(payload.sid)/confirm") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(payload.key, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 10
        let delegate = PinnedSessionDelegate(fingerprint: payload.fp)
        let session  = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}

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
