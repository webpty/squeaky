import Foundation
import UserNotifications

/// How Squeaky tells you something while you are elsewhere.
public protocol NotifierPort: Sendable {
    func post(_ text: String)
    /// A notification of its own kind: one of each kind shows at a time.
    func post(_ text: String, kind: String)
}

public extension NotifierPort {
    func post(_ text: String, kind: String) { post(text) }
}

/// Mac notifications. The Mac asks, the first time, whether Squeaky may send
/// them. Clicking one opens Squeaky on the Queue page.
public final class MacNotifier: NSObject, NotifierPort, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = MacNotifier()

    /// What a click does, set by the app model once it runs. A click that
    /// launched Squeaky waits for it.
    @MainActor public static var onOpen: (() -> Void)? {
        didSet {
            if pending, let onOpen {
                pending = false
                onOpen()
            }
        }
    }

    @MainActor private static var pending = false

    /// Called as Squeaky starts, so that a click which launched it is not missed.
    @MainActor public static func listen() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = shared
    }

    public func post(_ text: String) {
        post(text, kind: "nas")
    }

    /// Kinds: "nas" for a finished batch, "card" when a card can come out,
    /// "power" to connect to power, "nas-away" when the NAS does not answer.
    public func post(_ text: String, kind: String) {
        // Only from the app itself: a test program has no app to notify from.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.body = text
            // One at a time: a newer one takes the place of the last.
            center.add(UNNotificationRequest(identifier: "squeaky-\(kind)", content: content, trigger: nil))
        }
    }

    /// Shown even while Squeaky is in front.
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
