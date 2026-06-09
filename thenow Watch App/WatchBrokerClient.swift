import Foundation

enum WatchBrokerClient {
    // 优先用手机传来的 IP，没有则用硬编码兜底
    static var baseURL: String {
        #if targetEnvironment(simulator)
        return "http://localhost:8000"
        #else
        return UserDefaults.standard.string(forKey: "brokerURL") ?? "http://172.30.87.117:8000"
        #endif
    }
    static let apiKey = "dev-key"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 15
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    private static func makeRequest(_ path: String) -> URLRequest? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        return req
    }

    static func fetchUsage() async -> (UsageResponse?, String?) {
        guard let req = makeRequest("/usage") else { return (nil, "bad URL") }
        do {
            let (data, _) = try await session.data(for: req)
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            // 缓存到本地，离线时可展示最后数据
            if let d = try? JSONEncoder().encode(decoded) {
                UserDefaults.standard.set(d, forKey: "cachedUsage")
            }
            return (decoded, nil)
        } catch {
            WatchSessionManager.shared.requestFreshBrokerURL()
            if let d = UserDefaults.standard.data(forKey: "cachedUsage"),
               let cached = try? JSONDecoder().decode(UsageResponse.self, from: d) {
                return (cached, nil)
            }
            return (nil, error.localizedDescription)
        }
    }

    static func loadCachedUsage() -> UsageResponse? {
        guard let d = UserDefaults.standard.data(forKey: "cachedUsage") else { return nil }
        return try? JSONDecoder().decode(UsageResponse.self, from: d)
    }

    static func fetchPending() async -> [ApprovalRequest] {
        guard let req = makeRequest("/pending-requests") else { return [] }
        guard let (data, _) = try? await session.data(for: req) else { return [] }
        return (try? JSONDecoder().decode([ApprovalRequest].self, from: data)) ?? []
    }

    static func decide(_ requestId: String, approved: Bool) async -> Bool {
        guard var req = makeRequest("/decision/\(requestId)") else { return false }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["status": approved ? "approved" : "denied"])
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}
