import AppKit
import SwiftUI
import GeotagCore

public enum Screen: String, CaseIterable, Identifiable {
    case tracks
    case photos
    case queue
    case history
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tracks: return "Tracks"
        case .photos: return "Photos"
        case .queue: return "Queue"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .tracks: return "map"
        case .photos: return "photo.on.rectangle"
        case .queue: return "arrow.up.circle"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public var appearance = Appearance.system
    @Published public var screen = Screen.tracks

    // Track service, as set in Settings.
    @Published public var serviceAddress = ""
    @Published public var serviceKey = ""
    @Published public private(set) var role: KeyRole?
    @Published public private(set) var serviceStatus: ServiceStatus?
    @Published public var settingsLine = ""
    @Published public private(set) var settingsBusy = false

    // Tracks.
    @Published public private(set) var tracks: [Track] = []
    @Published public var tracksLine = ""
    @Published public private(set) var tracksBusy = false

    public let library: TrackLibrary
    public let thumbnails = MapThumbnails()
    private let secrets: SecretStorePort
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var awaitingStrava = false

    static let keyAccount = "track-service-key"

    public init(library: TrackLibrary = TrackLibrary(store: TrackStoreFolder.standard()),
                secrets: SecretStorePort = Keychain()) {
        self.library = library
        self.secrets = secrets
        if let raw = defaults.string(forKey: "appearance"), let mode = Appearance(rawValue: raw) {
            appearance = mode
        }
        serviceAddress = defaults.string(forKey: "trackServiceAddress") ?? ""
        role = defaults.string(forKey: "trackServiceRole").flatMap(KeyRole.init(rawValue:))
        serviceKey = secrets.read(Self.keyAccount) ?? ""

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cameBack() }
        }
    }

    public func setAppearance(_ mode: Appearance) {
        appearance = mode
        defaults.set(mode.rawValue, forKey: "appearance")
    }

    /// At launch: show what this Mac has, then ask the service, and again every ten minutes.
    public func start() async {
        tracks = await library.listed()
        await refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    var service: TrackServicePort? {
        TrackServiceHTTP(address: serviceAddress, key: serviceKey)
    }

    // MARK: Settings

    public func saveService() async {
        defaults.set(serviceAddress.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "trackServiceAddress")
        do {
            try secrets.write(Self.keyAccount, serviceKey.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            settingsLine = error.localizedDescription
            return
        }
        await testService()
        if role != nil { await refresh() }
    }

    public func testService() async {
        guard let service else {
            settingsLine = ServiceError.notSetUp.localizedDescription
            return
        }
        settingsBusy = true
        defer { settingsBusy = false }
        do {
            let status = try await service.status()
            serviceStatus = status
            role = status.role
            defaults.set(status.role.rawValue, forKey: "trackServiceRole")
            let who = status.role == .owner ? "Owner key" : "Reading key"
            settingsLine = "\(who). \(status.tracks) \(status.tracks == 1 ? "track" : "tracks") on the service."
        } catch {
            settingsLine = error.localizedDescription
        }
    }

    public func connectStrava() async {
        guard let service else { return }
        settingsBusy = true
        defer { settingsBusy = false }
        do {
            let url = try await service.connectLink()
            awaitingStrava = true
            NSWorkspace.shared.open(url)
            settingsLine = "Approve on Strava in the browser."
        } catch {
            settingsLine = error.localizedDescription
        }
    }

    public func disconnectStrava() async {
        guard let service else { return }
        settingsBusy = true
        defer { settingsBusy = false }
        do {
            settingsLine = try await service.disconnect()
            serviceStatus = try? await service.status()
        } catch {
            settingsLine = error.localizedDescription
        }
    }

    /// Back from the browser after approving on Strava: show the news.
    private func cameBack() {
        guard awaitingStrava else { return }
        Task {
            await testService()
            if serviceStatus?.strava.connected == true {
                awaitingStrava = false
                settingsLine = "Strava connected."
                await refresh()
            }
        }
    }

    // MARK: Tracks

    public func refresh() async {
        guard !tracksBusy else { return }
        guard let service else {
            tracks = await library.listed()
            tracksLine = ServiceError.notSetUp.localizedDescription
            return
        }
        tracksBusy = true
        defer { tracksBusy = false }
        if role == nil { await testService() }
        guard let role else {
            tracks = await library.listed()
            tracksLine = settingsLine
            return
        }
        let report = await library.refresh(service: service, role: role)
        tracks = await library.listed()
        tracksLine = report.line
    }

    public func importFiles(_ urls: [URL]) async {
        var added = 0
        var lines: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                switch try await library.importFile(url, role: role) {
                case .added: added += 1
                case .alreadyHere(let existing): lines.append("\(url.lastPathComponent) is already here as \(existing.name).")
                }
            } catch {
                lines.append(error.localizedDescription)
            }
        }
        tracks = await library.listed()
        if added > 0 {
            lines.insert(added == 1 ? "1 track imported." : "\(added) tracks imported.", at: 0)
        }
        if added > 0, role == .owner {
            await refresh()
            let waiting = await library.waitingCount
            if waiting > 0 { lines.append(tracksLine) }
        }
        tracksLine = lines.joined(separator: " ")
    }

    public func points(_ id: String) async -> TrackPoints? {
        await library.points(id)
    }
}
