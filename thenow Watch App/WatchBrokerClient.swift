import Foundation
import CryptoKit

enum WatchBrokerClient {
    static var baseURL: String {
        #if targetEnvironment(simulator)
        return "https://localhost:8000"
        #else
        return sharedDefaults.string(forKey: "brokerURL") ?? ""
        #endif
    }
    static var apiKey: String {
        sharedDefaults.string(forKey: "apiKey") ?? ""
    }
    static var isPaired: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return sharedDefaults.string(forKey: "brokerURL") != nil
            && sharedDefaults.string(forKey: "apiKey") != nil
        #endif
    }
    private static var certFingerprint: String? {
        sharedDefaults.string(forKey: "certFingerprint")
    }

    private static func makeSession() -> URLSession {
        if let fp = certFingerprint, !fp.isEmpty {
            let delegate = WatchPinnedDelegate(fingerprint: fp)
            return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        }
        return URLSession.shared
    }

    private static func makeRequest(_ path: String) -> URLRequest? {
        guard isPaired else { return nil }
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 15
        return req
    }

    static func fetchUsage() async -> (UsageResponse?, String?) {
        guard let req = makeRequest("/usage") else { return (nil, "bad URL") }
        do {
            let (data, _) = try await makeSession().data(for: req)
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            if let d = try? JSONEncoder().encode(decoded) {
                sharedDefaults.set(d, forKey: "cachedUsage")
            }
            return (decoded, nil)
        } catch {
            WatchSessionManager.shared.requestFreshBrokerURL()
            if let d = sharedDefaults.data(forKey: "cachedUsage"),
               let cached = try? JSONDecoder().decode(UsageResponse.self, from: d) {
                return (cached, nil)
            }
            return (nil, error.localizedDescription)
        }
    }

    static func loadCachedUsage() -> UsageResponse? {
        guard let d = sharedDefaults.data(forKey: "cachedUsage") else { return nil }
        return try? JSONDecoder().decode(UsageResponse.self, from: d)
    }

    static func fetchPending() async -> [ApprovalRequest] {
        guard let req = makeRequest("/pending-requests") else { return [] }
        guard let (data, _) = try? await makeSession().data(for: req) else {
            WatchSessionManager.shared.requestFreshBrokerURL()
            return []
        }
        return (try? JSONDecoder().decode([ApprovalRequest].self, from: data)) ?? []
    }

    static func decide(_ requestId: String, approved: Bool) async -> Bool {
        guard var req = makeRequest("/decision/\(requestId)") else { return false }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["status": approved ? "approved" : "denied"])
        guard let (_, resp) = try? await makeSession().data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}

// MARK: - Cert pinning delegate

private final class WatchPinnedDelegate: NSObject, URLSessionDelegate {
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
              let serverTrust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf  = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let certData = SecCertificateCopyData(leaf) as Data
        let fp = SHA256.hash(data: certData).map { String(format: "%02x", $0) }.joined()
        if fp == expectedFingerprint {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
