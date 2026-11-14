#if os(macOS)
#if os(macOS)
import AppKit
#endif

/// Command-Q always quits, whatever is open (David, 16 October 2026).
public enum Quitting {
    /// What would be cut off by quitting now, said before Command-Q or the
    /// menu's Quit goes ahead; nil when nothing is going on. Set by the app model.
    @MainActor public static var cutOff: (() -> String?)?
    /// Records still to write, written as Geotag quits. Set by the app model.
    @MainActor public static var beforeQuit: (() -> Void)?

    /// Command-Q and the menu's Quit: asks first while photos are being saved
    /// or are on their way to the NAS (David, 1 November 2026: a Command-Q
    /// meant for another app stopped a save). Nothing going on, it quits.
    @MainActor
    public static func asked() {
        if let text = cutOff?() {
            let alert = NSAlert()
            alert.messageText = "Are you sure?"
            alert.informativeText = text
            // Return keeps Geotag open.
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Yes, Quit anyway")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        now()
    }

    /// The Mac will not quit while a sheet is open, and SwiftUI shows a sheet
    /// again straight after it is closed from outside, so every sheet is
    /// closed and Geotag quits in the same moment, before one can come back
    /// (18 October 2026). A file chooser running on its own is stopped first.
    /// Should anything still refuse, Geotag stops a second later all the
    /// same: its records are written as they change, so nothing is lost.
    @MainActor
    public static func now() {
        if NSApp.modalWindow != nil {
            NSApp.abortModal()
            DispatchQueue.main.async { now() }
            return
        }
        endSheets()
        beforeQuit?()
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            UserDefaults.standard.synchronize()
            exit(0)
        }
    }

    /// Every open sheet closed, the innermost first.
    @MainActor
    static func endSheets() {
        for _ in 0..<10 {
            let open = NSApp.windows.filter { $0.attachedSheet != nil }
            guard !open.isEmpty else { return }
            for window in open {
                if let sheet = window.attachedSheet, sheet.attachedSheet == nil { window.endSheet(sheet) }
            }
        }
    }

    /// Quit from the Dock, a log-out or another app goes the same way.
    @MainActor
    public static func takeQuitEvents() {
        NSAppleEventManager.shared().setEventHandler(QuitEvents.shared, andSelector: #selector(QuitEvents.quit(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
    }
}

final class QuitEvents: NSObject {
    static let shared = QuitEvents()

    @objc func quit(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated { Quitting.now() }
    }
}

#endif
