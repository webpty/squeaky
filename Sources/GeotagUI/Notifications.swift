import AppKit
import UserNotifications

/// How Geotag tells you something while you are elsewhere.
public protocol NotifierPort: Sendable {
    func post(_ text: String)
}

/// Mac notifications. The Mac asks, the first time, whether Geotag may send
/// them. Clicking one opens Geotag on the Queue page.
public final class MacNotifier: NSObject, NotifierPort, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = MacNotifier()

    /// What a click does, set by the app model once it runs. A click that
    /// launched Geotag waits for it.
    @MainActor public static var onOpen: (() -> Void)? {
        didSet {
            if pending, let onOpen {
                pending = false
                onOpen()
            }
        }
    }

    @MainActor private static var pending = false

    /// Called as Geotag starts, so that a click which launched it is not missed.
    @MainActor public static func listen() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = shared
    }

    public func post(_ text: String) {
        // Only from the app itself: a test program has no app to notify from.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.body = text
            // One at a time: a newer one takes the place of the last.
            center.add(UNNotificationRequest(identifier: "geotag-nas", content: content, trigger: nil))
        }
    }

    /// Shown even while Geotag is in front.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            if let open = MacNotifier.onOpen { open() } else { MacNotifier.pending = true }
        }
        completionHandler()
    }
}
