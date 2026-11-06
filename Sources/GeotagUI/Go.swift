import AppKit
import SwiftUI

/// What used to be menus in the Mac's menu bar, now in the sidebar under
/// the pages (David, 6 November 2026: "the top is getting really crowded").
public enum Tool: String, CaseIterable, Identifiable {
    case tracks, clockDrift, cameraClocks, download

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tracks: return "Tracks"
        case .clockDrift: return "Clock drift"
        case .cameraClocks: return "Camera clocks"
        case .download: return "Download"
        }
    }

    public var symbol: String {
        switch self {
        case .tracks: return "map"
        case .clockDrift: return "clock.badge.exclamationmark"
        case .cameraClocks: return "camera"
        case .download: return "arrow.down.circle"
        }
    }

    /// The window each opens; Download opens none.
    public var window: String? {
        switch self {
        case .tracks: return "tracks"
        case .clockDrift: return "clock-drift"
        case .cameraClocks: return "camera-clock"
        case .download: return nil
        }
    }

    @MainActor
    public func run(_ model: AppModel, _ openWindow: OpenWindowAction) {
        switch self {
        case .cameraClocks:
            model.cameraGuide = CameraGuide.all.first?.id ?? model.cameraGuide
        case .download:
            Task { await model.saveDownload() }
        default:
            break
        }
        if let window { openWindow(id: window) }
    }
}

/// Command and a number for each sidebar item in order, Settings keeping
/// its Command-comma: Photos 1, Queue 2, History 3, then the tools.
public enum Shortcuts {
    public static let pages: [Screen] = Screen.sidebar.filter { $0 != .settings }

    public static func key(_ screen: Screen) -> KeyEquivalent? {
        pages.firstIndex(of: screen).map { KeyEquivalent(Character("\($0 + 1)")) }
    }

    public static func key(_ tool: Tool) -> KeyEquivalent? {
        Tool.allCases.firstIndex(of: tool).map { KeyEquivalent(Character("\(pages.count + $0 + 1)")) }
    }
}

/// The shortcuts, listed in the Mac's View menu.
public struct GoMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ForEach(Shortcuts.pages) { screen in
            Button(screen.title) {
                model.screen = screen
                Windows.bringMainForward()
            }
            .keyboardShortcut(Shortcuts.key(screen)!, modifiers: .command)
        }
        Divider()
        ForEach(Tool.allCases) { tool in
            Button(tool.title) { tool.run(model, openWindow) }
                .keyboardShortcut(Shortcuts.key(tool)!, modifiers: .command)
                .disabled(tool == .download && model.makingDownload)
        }
        Divider()
    }
}

/// Escape closes the windows that open over the main one (David, 6 November
/// 2026). Their sheets and panels close on Escape by themselves.
public enum EscapeCloses {
    nonisolated(unsafe) private static var watch: Any?

    @MainActor
    public static func start(_ model: AppModel) {
        guard watch == nil else { return }
        let ids = Tool.allCases.compactMap(\.window)
        watch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            guard event.keyCode == 53, keys.isEmpty, let window = NSApp.keyWindow, window.attachedSheet == nil,
                  let id = window.identifier?.rawValue, ids.contains(where: { id == $0 || id.hasPrefix($0 + "-") }) else { return event }
            // The track viewer over the Tracks window closes first, on its own.
            if id.hasPrefix("tracks"), model?.viewing != nil { return event }
            window.close()
            return nil
        }
    }
}
