import AppKit
import SwiftUI
import SqueakyUI

/// Started from the Login Items, Squeaky waits for a card with no window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var quitWatch: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch ends, so a click on a notification that opened Squeaky counts.
        MacNotifier.listen()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Command-Q always quits, even with a window or a file chooser open
        // inside Squeaky: they are closed first, then Squeaky quits.
        quitWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            guard keys == .command, event.charactersIgnoringModifiers?.lowercased() == "q" else { return event }
            Quitting.asked()
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
struct SqueakyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() {
        // Before anything is read: what Geotag kept, taken over once (0.34.0).
        FromGeotag.run()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 620)
                .task {
                    // The icon in the menu bar while Squeaky works.
                    MenuBarIcon.watch(model.work)
                    await model.start()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // The menu's Quit goes the way Command-Q does.
            CommandGroup(replacing: .appTermination) {
                Button("Quit Squeaky") { Quitting.asked() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            // Command-comma opens Settings, in Squeaky's own window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.screen = .settings
                    Windows.bringForward()
                }
                .keyboardShortcut(",", modifiers: .command)
                Button("Set Up This Mac…") {
                    model.settingUp = true
                    Windows.bringForward()
                }
            }
            // Command and a number for each sidebar item, listed in the View menu.
            CommandGroup(before: .sidebar) {
                GoMenu(model: model)
            }
        }
    }
}
