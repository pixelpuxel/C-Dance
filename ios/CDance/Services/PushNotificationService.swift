import UIKit
import UserNotifications

extension Notification.Name {
    static let cdanceDeviceToken = Notification.Name("CDanceDeviceToken")
    static let cdanceNotificationOpened = Notification.Name("CDanceNotificationOpened")
}

enum PushNotificationRouter {
    static let pendingGenerationKey = "pendingPushGenerationID"

    static func generationID(from userInfo: [AnyHashable: Any]) -> String? {
        guard let value = userInfo["generation_id"] as? String, UUID(uuidString: value) != nil else { return nil }
        return value
    }

    static func storePending(_ generationID: String) {
        UserDefaults.standard.set(generationID, forKey: pendingGenerationKey)
    }

    static func consumePending() -> String? {
        let value = UserDefaults.standard.string(forKey: pendingGenerationKey)
        UserDefaults.standard.removeObject(forKey: pendingGenerationKey)
        return value
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if let notification = launchOptions?[.remoteNotification] as? [AnyHashable: Any],
           let generationID = PushNotificationRouter.generationID(from: notification) {
            PushNotificationRouter.storePending(generationID)
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "apnsDeviceToken")
        NotificationCenter.default.post(name: .cdanceDeviceToken, object: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if !targetEnvironment(simulator)
        NotificationCenter.default.post(name: .cdanceDeviceToken, object: nil, userInfo: ["error": error])
        #endif
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == StandaloneBackgroundTransfer.identifier else {
            completionHandler()
            return
        }
        StandaloneBackgroundTransfer.shared.handleEvents(completionHandler: completionHandler)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let generationID = PushNotificationRouter.generationID(from: response.notification.request.content.userInfo) else { return }
        PushNotificationRouter.storePending(generationID)
        await MainActor.run {
            NotificationCenter.default.post(name: .cdanceNotificationOpened, object: generationID)
        }
    }
}

enum PushNotificationService {
    static func enable(registerRemote: Bool = true) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            guard try await center.requestAuthorization(options: [.alert, .badge, .sound]) else {
                throw PushPermissionError.denied
            }
        case .denied:
            throw PushPermissionError.denied
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            throw PushPermissionError.denied
        }
        if registerRemote { await MainActor.run { UIApplication.shared.registerForRemoteNotifications() } }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

enum PushPermissionError: LocalizedError {
    case denied
    var errorDescription: String? {
        "Mitteilungen sind für CDance deaktiviert. Du kannst sie in den Systemeinstellungen erlauben."
    }
}
