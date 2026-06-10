import SwiftUI
import UserNotifications
import WatchConnectivity

@main
struct thenowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        NotificationDelegate.shared.registerCategories()
        PhoneSessionManager.shared.activate()

        Task {
            let granted = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            guard granted == true else { return }
            await MainActor.run {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        PhoneSessionManager.shared.startPolling()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        PhoneSessionManager.shared.stopPolling()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[thenow] device token: \(token)")
        Task { await BrokerClient.registerDevice(token: token) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[thenow] APNs registration failed: \(error)")
    }

    // Broker 重启时发来的静默推送（content-available:1）
    // 系统在后台唤醒 App，App 把新 broker IP 推给手表，无需用户手动开 App
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if let brokerURL = userInfo["broker_url"] as? String {
            print("[thenow] silent push: broker URL = \(brokerURL)")
            // Update Keychain so iPhone's own requests use the new URL too.
            // Without this, iPhone's /broker-ip call in didReceiveMessage would
            // still use the stale URL and fail to answer Watch URL queries.
            if let fp  = KeychainHelper.certFingerprint,
               let key = KeychainHelper.apiKey {
                KeychainHelper.save(brokerURL: brokerURL, apiKey: key, certFingerprint: fp)
            }
            if WCSession.isSupported() {
                var ctx: [String: Any] = ["brokerURL": brokerURL]
                if let fp = KeychainHelper.certFingerprint { ctx["certFingerprint"] = fp }
                if let key = KeychainHelper.apiKey          { ctx["apiKey"] = key }
                try? WCSession.default.updateApplicationContext(ctx)
            }
            completionHandler(.newData)
            return
        }
        if userInfo["type"] as? String == "approval_request" {
            PhoneSessionManager.shared.pingWatchNewRequest()
            completionHandler(.newData)
            return
        }
        completionHandler(.noData)
    }
}

// 负责激活 WCSession 并在连通后把 broker IP 推给手表
class PhoneSessionManager: NSObject, WCSessionDelegate {
    static let shared = PhoneSessionManager()

    private var pollTimer: Timer?
    private var seenRequestIDs: Set<String> = []

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // Called when app enters foreground — polls broker and relays new requests to Watch.
    // This makes Watch aware of new requests even without APNs configured.
    func startPolling() {
        guard pollTimer == nil else { return }
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard BrokerClient.isPaired else { return }
        Task {
            let ids = await BrokerClient.fetchPendingRequestIDs()
            let idSet = Set(ids)
            let newIDs = idSet.subtracting(seenRequestIDs)
            if !newIDs.isEmpty {
                seenRequestIDs.formUnion(newIDs)
                pingWatchNewRequest()
            }
            seenRequestIDs = seenRequestIDs.intersection(idSet)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        BrokerClient.discoverAndShareWithWatch()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable { BrokerClient.discoverAndShareWithWatch() }
    }

    func pingWatchNewRequest() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        // Immediate delivery when Watch app is in foreground.
        if session.isReachable {
            session.sendMessage(["ping": "newRequest"], replyHandler: nil, errorHandler: nil)
        }
        // Queued delivery — fires when Watch app next becomes active (works from watch face).
        session.transferUserInfo(["ping": "newRequest"])
    }

    // 手表主动来问时，后台自动回复当前 IP，不需要用户手动开 App
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["request"] as? String == "brokerURL" else { return }
        Task {
            guard let url = URL(string: "\(BrokerClient.brokerIPURL)/broker-ip") else { return }
            var req = URLRequest(url: url)
            req.setValue(BrokerClient.sharedApiKey, forHTTPHeaderField: "X-API-Key")
            let pinnedSession: URLSession
            if let fp = KeychainHelper.certFingerprint, !fp.isEmpty {
                pinnedSession = URLSession(configuration: .default,
                                          delegate: PinnedSessionDelegate(fingerprint: fp),
                                          delegateQueue: nil)
            } else {
                pinnedSession = URLSession.shared
            }
            guard let (data, _) = try? await pinnedSession.data(for: req),
                  let obj = try? JSONDecoder().decode([String: String].self, from: data),
                  let brokerURL = obj["url"] else {
                replyHandler([:])
                return
            }
            var ctx: [String: Any] = ["brokerURL": brokerURL]
            if let fp  = KeychainHelper.certFingerprint { ctx["certFingerprint"] = fp }
            if let key = KeychainHelper.apiKey          { ctx["apiKey"] = key }
            try? session.updateApplicationContext(ctx)
            replyHandler(["brokerURL": brokerURL])
        }
    }

    // iOS 必须实现这两个
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
