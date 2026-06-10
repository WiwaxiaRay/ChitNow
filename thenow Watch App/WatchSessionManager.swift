import WatchConnectivity

extension Notification.Name {
    static let brokerURLUpdated   = Notification.Name("brokerURLUpdated")
    static let newApprovalRequest = Notification.Name("newApprovalRequest")
}

// Shared App Group suite — widget extension reads from the same suite.
let sharedDefaults = UserDefaults(suiteName: "group.com.wangyang.thenow") ?? .standard

class WatchSessionManager: NSObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        let ctx = session.receivedApplicationContext
        if let url = ctx["brokerURL"]       as? String { sharedDefaults.set(url, forKey: "brokerURL") }
        if let fp  = ctx["certFingerprint"] as? String { sharedDefaults.set(fp,  forKey: "certFingerprint") }
        if let key = ctx["apiKey"]          as? String { sharedDefaults.set(key, forKey: "apiKey") }
        requestBrokerURLFromPhone(session)
    }

    /// 网络失败时由 WatchBrokerClient 调用，向手机要最新 IP
    func requestFreshBrokerURL() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        requestBrokerURLFromPhone(WCSession.default)
    }

    private func requestBrokerURLFromPhone(_ session: WCSession) {
        guard session.isReachable else { return }
        session.sendMessage(["request": "brokerURL"], replyHandler: { reply in
            guard let url = reply["brokerURL"] as? String else { return }
            DispatchQueue.main.async {
                sharedDefaults.set(url, forKey: "brokerURL")
                NotificationCenter.default.post(name: .brokerURLUpdated, object: nil)
                print("[watch] broker URL refreshed: \(url)")
            }
        }, errorHandler: { _ in })
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        DispatchQueue.main.async {
            if let url = context["brokerURL"]       as? String { sharedDefaults.set(url, forKey: "brokerURL") }
            if let fp  = context["certFingerprint"] as? String { sharedDefaults.set(fp,  forKey: "certFingerprint") }
            if let key = context["apiKey"]          as? String { sharedDefaults.set(key, forKey: "apiKey") }
            if context["brokerURL"] != nil {
                NotificationCenter.default.post(name: .brokerURLUpdated, object: nil)
                print("[watch] broker context updated")
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["ping"] as? String == "newRequest" {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .newApprovalRequest, object: nil)
            }
        }
    }

    // Handles transferUserInfo delivery — fires even when app was not in foreground.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if userInfo["ping"] as? String == "newRequest" {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .newApprovalRequest, object: nil)
            }
        }
    }
}
