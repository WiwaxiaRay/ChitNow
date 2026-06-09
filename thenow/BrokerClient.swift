import Foundation
import WatchConnectivity

enum BrokerClient {
    // Set THENOW_BROKER_URL in scheme environment variables or hardcode Tailscale hostname
    static var brokerIPURL: String {
        ProcessInfo.processInfo.environment["THENOW_BROKER_URL"] ?? "http://dacidabeiwushouyehehuadeMacBook-Air.local:8000"
    }
    static var sharedApiKey: String {
        ProcessInfo.processInfo.environment["THENOW_API_KEY"] ?? "dev-key"
    }
    private static var baseURL: String { brokerIPURL }
    private static var apiKey: String { sharedApiKey }

    static func registerDevice(token: String) async {
        await post(path: "/register-device", body: ["device_token": token])
    }

    static func postDecision(requestId: String, decision: String) async {
        await post(path: "/decision/\(requestId)", body: ["status": decision])
    }

    static func discoverAndShareWithWatch() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        Task {
            guard let url = URL(string: "\(baseURL)/broker-ip") else { return }
            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONDecoder().decode([String: String].self, from: data),
                  let brokerURL = obj["url"] else { return }
            try? WCSession.default.updateApplicationContext(["brokerURL": brokerURL])
            print("[thenow] Watch broker URL updated: \(brokerURL)")
        }
    }

    private static func post(path: String, body: [String: String]) async {
        guard let url = URL(string: "\(baseURL)\(path)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.httpBody = try? JSONEncoder().encode(body)
        _ = try? await URLSession.shared.data(for: req)
    }
}
