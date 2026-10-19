import AppKit
import SwiftUI
import GeotagUI

/// Started from the Login Items, Geotag waits for a card with no window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var quitWatch: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch ends, so a click on a notification that opened Geotag counts.
        MacNotifier.listen()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Command-Q always quits, even with a window or a file chooser open
        // inside Geotag: they are closed first, then Geotag quits.
        quitWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            guard keys == .command, event.charactersIgnoringModifiers?.lowercased() == "q" else { return event }
            Quitting.now()
            return nil
        }
        Quitting.takeQuitEvents()
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
                .task {
                    // The icon in the menu bar while Geotag works.
                    MenuBarIcon.watch(model.work)
                    await model.start()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // The menu's Quit goes the way Command-Q does.
            CommandGroup(replacing: .appTermination) {
                Button("Quit Geotag") { Quitting.now() }
                    .keyboardShortcut("q", modifiers: .command)
            }
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
            CommandMenu("Download") {
                DownloadMenu(model: model)
            }
            CommandMenu("Set time and date in camera") {
                CameraClockMenu(model: model)
            }
        }

        Window("Set time and date in camera", id: "camera-clock") {
            CameraClockWindow()
                .environmentObject(model)
        }

        Window("Tracks", id: "tracks") {
            TracksWindow()
                .environmentObject(model)
        }
    }
}
