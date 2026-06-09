import UserNotifications

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func registerCategories() {
        let approve = UNNotificationAction(
            identifier: "APPROVE",
            title: "Approve",
            options: []
        )
        let deny = UNNotificationAction(
            identifier: "DENY",
            title: "Deny",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: "AGENT_APPROVAL",
            actions: [approve, deny],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard
            let requestId = response.notification.request.content
                .userInfo["request_id"] as? String
        else { return }

        let decision: String
        switch response.actionIdentifier {
        case "APPROVE": decision = "approved"
        case "DENY":    decision = "denied"
        default:        return
        }

        await BrokerClient.postDecision(requestId: requestId, decision: decision)
    }

    // Show banner even when app is foregrounded
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
