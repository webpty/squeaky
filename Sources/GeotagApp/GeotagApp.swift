import AppKit
import SwiftUI
import GeotagUI

/// Started from the Login Items, Geotag waits for a card with no window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var quitWatch: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Command-Q always quits, even with a window or a file chooser open
        // inside Geotag: they are closed first, then Geotag quits.
        quitWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            guard keys == .command, event.charactersIgnoringModifiers?.lowercased() == "q" else { return event }
            AppDelegate.quitNow()
            return nil
        }
        guard LoginItem.launchedAtLogin() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.windows.filter(\.canBecomeMain).forEach { $0.close() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    static func quitNow() {
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

@main
struct GeotagApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 620)
                .task { await model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Command-comma opens Settings, in Geotag's own window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.screen = .settings
                    Windows.bringForward()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Tracks") {
                TracksMenu(model: model)
            }
        }

        Window("Tracks", id: "tracks") {
            TracksWindow()
                .environmentObject(model)
        }
    }
}
