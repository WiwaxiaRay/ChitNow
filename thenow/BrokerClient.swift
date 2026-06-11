import Foundation
import CryptoKit
import WatchConnectivity

extension Notification.Name {
    static let certMismatch = Notification.Name("thenow.certMismatch")
}

enum ApprovalRoutingSettings {
    private static let key = "watchApprovalsEnabled"

    static var watchApprovalsEnabled: Bool {
        if UserDefaults.standard.object(forKey: key) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setWatchApprovalsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}

// MARK: - Pinned URLSession

final class PinnedSessionDelegate: NSObject, URLSessionDelegate {
    private let expectedFingerprint: String

    init(fingerprint: String) {
        self.expectedFingerprint = fingerprint.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let certData = SecCertificateCopyData(leaf) as Data
        let fp = SHA256.hash(data: certData).map { String(format: "%02x", $0) }.joined()
        if fp == expectedFingerprint {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            print("[thenow] cert pin mismatch: got \(fp)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .certMismatch, object: nil)
            }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - BrokerClient

enum BrokerClient {
    private struct ApprovalRouting: Codable {
        let watch_approvals_enabled: Bool
    }

    static var brokerURL: String {
        KeychainHelper.brokerURL ?? ""
    }
    static var apiKey: String {
        KeychainHelper.apiKey ?? ""
    }
    static var certFingerprint: String? {
        KeychainHelper.certFingerprint
    }
    static var isPaired: Bool {
        KeychainHelper.brokerURL != nil && KeychainHelper.apiKey != nil
    }

    // brokerIPURL is used by PhoneSessionManager to call /broker-ip
    static var brokerIPURL: String { brokerURL }
    static var sharedApiKey: String { apiKey }

    private static func makeSession() -> URLSession {
        if let fp = certFingerprint, !fp.isEmpty {
            let delegate = PinnedSessionDelegate(fingerprint: fp)
            return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        }
        // No fingerprint yet (pre-pairing) — trust all for local dev
        return URLSession.shared
    }

    static func checkHealth() async -> (reachable: Bool, latencyMs: Int) {
        guard let url = URL(string: "\(brokerURL)/health") else { return (false, 0) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let start = Date()
        guard let (_, resp) = try? await makeSession().data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return (false, 0) }
        return (true, Int(Date().timeIntervalSince(start) * 1000))
    }

    static func fetchPendingRequestIDs() async -> [String] {
        guard isPaired, let url = URL(string: "\(brokerURL)/pending-requests") else { return [] }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 5
        guard let (data, resp) = try? await makeSession().data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return items.compactMap { $0["id"] as? String }
    }

    static func sendRelayCredentials(installationId: String, secret: String) async -> Bool {
        await postForStatus(path: "/relay-credentials",
                            body: ["installation_id": installationId, "relay_secret": secret])
    }

    static func fetchWatchApprovalsEnabled() async -> Bool? {
        guard isPaired, let url = URL(string: "\(brokerURL)/approval-routing") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 5
        guard let (data, resp) = try? await makeSession().data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200,
              let routing = try? JSONDecoder().decode(ApprovalRouting.self, from: data)
        else { return nil }
        ApprovalRoutingSettings.setWatchApprovalsEnabled(routing.watch_approvals_enabled)
        return routing.watch_approvals_enabled
    }

    static func setWatchApprovalsEnabled(_ enabled: Bool) async -> Bool {
        guard isPaired, let url = URL(string: "\(brokerURL)/approval-routing") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.httpBody = try? JSONEncoder().encode(["watch_approvals_enabled": enabled])
        req.timeoutInterval = 10
        guard let (data, resp) = try? await makeSession().data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200,
              let routing = try? JSONDecoder().decode(ApprovalRouting.self, from: data),
              routing.watch_approvals_enabled == enabled
        else { return false }
        ApprovalRoutingSettings.setWatchApprovalsEnabled(enabled)
        PhoneSessionManager.shared.shareCurrentContextWithWatch()
        return true
    }

    static func deleteRelayCredentials() async {
        guard isPaired, let url = URL(string: "\(brokerURL)/relay-credentials") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 10
        _ = try? await makeSession().data(for: req)
    }

    static func postDecision(requestId: String, decision: String) async {
        await post(path: "/decision/\(requestId)", body: ["status": decision])
    }

    static func discoverAndShareWithWatch() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        Task {
            guard let url = URL(string: "\(brokerURL)/broker-ip") else { return }
            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            guard let (data, _) = try? await makeSession().data(for: req),
                  let obj = try? JSONDecoder().decode([String: String].self, from: data),
                  let newURL = obj["url"] else { return }
            PhoneSessionManager.shared.shareCurrentContextWithWatch(brokerURL: newURL)
            print("[thenow] Watch context updated: \(newURL)")
        }
    }

    private static func post(path: String, body: [String: String]) async {
        _ = await postForStatus(path: path, body: body)
    }

    private static func postForStatus(path: String, body: [String: String]) async -> Bool {
        guard let url = URL(string: "\(brokerURL)\(path)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.httpBody = try? JSONEncoder().encode(body)
        guard let (_, resp) = try? await makeSession().data(for: req),
              let http = resp as? HTTPURLResponse
        else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
