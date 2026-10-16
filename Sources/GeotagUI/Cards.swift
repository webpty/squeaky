import AppKit
import ServiceManagement
import GeotagCore

/// Somewhere photos come from: a camera card, or a folder chosen by hand.
public struct PhotoSource: Identifiable, Equatable, Sendable {
    /// The card's volume id, or the folder's path.
    public var id: String
    public var name: String
    public var url: URL
    public var isCard: Bool
}

/// Notices camera cards as they come and go: any disk with a DCIM folder.
@MainActor
public final class CardWatcher {
    public var onChange: ([PhotoSource]) -> Void = { _ in }
    public var onInserted: (PhotoSource) -> Void = { _ in }
    private(set) public var cards: [PhotoSource] = []
    private var observers: [NSObjectProtocol] = []

    public init() {}

    /// A camera card at this mount point, or nil when it holds no DCIM folder.
    public nonisolated static func card(at volume: URL) -> PhotoSource? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: volume.appendingPathComponent("DCIM").path, isDirectory: &isFolder),
              isFolder.boolValue else { return nil }
        let values = try? volume.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        return PhotoSource(id: values?.volumeUUIDString ?? volume.path,
                           name: values?.volumeName ?? volume.lastPathComponent,
                           url: volume, isCard: true)
    }

    public func start() {
        cards = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .compactMap(Self.card(at:))
        onChange(cards)
        let centre = NSWorkspace.shared.notificationCenter
        observers.append(centre.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.mounted(url) }
        })
        observers.append(centre.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.unmounted(url) }
        })
    }

    private func mounted(_ url: URL) {
        guard let card = Self.card(at: url), !cards.contains(where: { $0.id == card.id }) else { return }
        cards.append(card)
        onChange(cards)
        onInserted(card)
    }

    private func unmounted(_ url: URL) {
        let before = cards.count
        cards.removeAll { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
        if cards.count != before { onChange(cards) }
    }
}

/// Geotag in the Mac's Login Items, so it can wait for cards.
public enum LoginItem {
    public static var isOn: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func set(_ on: Bool) throws {
        if on {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        }
    }

    /// True when this launch came from the Login Items rather than a person.
    @MainActor
    public static func launchedAtLogin() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

public enum Windows {
    /// Geotag to the front, opening its window again if it was closed.
    @MainActor
    public static func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Opening the app again makes it reopen its window.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
