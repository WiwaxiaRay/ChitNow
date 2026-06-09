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
        guard let brokerURL = userInfo["broker_url"] as? String else {
            completionHandler(.noData)
            return
        }
        print("[thenow] silent push: broker URL = \(brokerURL)")
        if WCSession.isSupported() {
            try? WCSession.default.updateApplicationContext(["brokerURL": brokerURL])
        }
        completionHandler(.newData)
    }
}

// 负责激活 WCSession 并在连通后把 broker IP 推给手表
class PhoneSessionManager: NSObject, WCSessionDelegate {
    static let shared = PhoneSessionManager()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        BrokerClient.discoverAndShareWithWatch()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable { BrokerClient.discoverAndShareWithWatch() }
    }

    // 手表主动来问时，后台自动回复当前 IP，不需要用户手动开 App
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["request"] as? String == "brokerURL" else { return }
        Task {
            guard let url = URL(string: "\(BrokerClient.brokerIPURL)/broker-ip") else { return }
            var req = URLRequest(url: url)
            req.setValue(BrokerClient.sharedApiKey, forHTTPHeaderField: "X-API-Key")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONDecoder().decode([String: String].self, from: data),
                  let brokerURL = obj["url"] else {
                replyHandler([:])
                return
            }
            try? session.updateApplicationContext(["brokerURL": brokerURL])
            replyHandler(["brokerURL": brokerURL])
        }
    }

    // iOS 必须实现这两个
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
