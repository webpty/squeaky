import ConnectIQ
import Foundation
import GeotagCore
import GeotagUI

/// The Geotag app on a Garmin watch, through Garmin's iPhone kit (0.32.0).
/// Garmin Connect is needed once, to pick the watch; after that the kit talks
/// to the watch over Bluetooth by itself, with no internet.
/// Each part of a track is kept as a file and confirmed to the watch, which
/// sends the next only then: a dropped link resumes where it stopped.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    static let shared = WatchLink()

    /// The scheme Garmin Connect answers on after the watch is picked.
    static let scheme = "geotag-ciq"
    /// The watch app's id, from Watch/Geotag/manifest.xml.
    static let appId = UUID(uuidString: "14bdff03-a39e-49e5-b118-cbaac67b0534")!
    private static let devicesKey = "watchDevices"

    @Published private(set) var watchName: String?
    @Published private(set) var connected = false
    @Published var problem: String?

    private var model: AppModel?
    private var devices: [IQDevice] = []
    private var apps: [IQApp] = []
    private let inbox = WatchInbox.standard()
    private var started = false

    func start(model: AppModel) {
        self.model = model
        guard !started else { return }
        started = true
        ConnectIQ.sharedInstance().initialize(withUrlScheme: Self.scheme, uiOverrideDelegate: self)
        devices = Self.loadDevices()
        listen()
    }

    /// Opens Garmin Connect to pick the watch; it comes back through `handle(_:)`.
    func choose() {
        problem = nil
        ConnectIQ.sharedInstance().showDeviceSelection()
    }

    /// Garmin Connect's answer after the watch was picked.
    func handle(_ url: URL) -> Bool {
        guard url.scheme == Self.scheme else { return false }
        guard let picked = ConnectIQ.sharedInstance().parseDeviceSelectionResponse(from: url) as? [IQDevice] else {
            problem = Words.t("Garmin Connect did not send a watch.")
            return true
        }
        ConnectIQ.sharedInstance().unregister(forAllDeviceEvents: self)
        ConnectIQ.sharedInstance().unregister(forAllAppMessages: self)
        devices = picked
        Self.saveDevices(picked)
        listen()
        return true
    }

    private func listen() {
        apps = []
        for device in devices {
            ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self)
            let app = IQApp(uuid: Self.appId, store: Self.appId, device: device)!
            ConnectIQ.sharedInstance().register(forAppMessages: app, delegate: self)
            apps.append(app)
        }
        watchName = devices.first.map { $0.friendlyName ?? $0.modelName ?? "" }
        connected = devices.contains { ConnectIQ.sharedInstance().getDeviceStatus($0) == .connected }
    }

    private func received(_ message: Any, from app: IQApp) {
        guard let part = WatchPart(message: message), let model else { return }
        do {
            let got = try inbox.keep(part)
            model.watchReceiving = (got, part.count)
            if got == part.count, let points = inbox.whole(part.trackId, of: part.count) {
                let id = part.trackId
                let device = app.device.modelName
                Task {
                    do {
                        try await model.addWatchTrack(trackId: id, points: points, watchModel: device)
                        model.watchReceiving = nil
                        TrackShare.shared.offer()
                        self.answer(["k": "ack", "id": id, "n": part.index], to: app)
                    } catch {
                        model.watchReceiving = nil
                        self.problem = error.localizedDescription
                    }
                }
                return
            }
            answer(["k": "ack", "id": part.trackId, "n": part.index], to: app)
        } catch {
            problem = Words.t("A part from the watch could not be kept: {0}", error.localizedDescription)
        }
    }

    private func answer(_ message: [String: Any], to app: IQApp) {
        ConnectIQ.sharedInstance().sendMessage(message, to: app, progress: nil) { [weak self] result in
            guard result != .success else { return }
            // The watch sends the part again after 30 s without an answer.
            Task { @MainActor in self?.connected = false }
        }
    }

    private static func loadDevices() -> [IQDevice] {
        guard let data = UserDefaults.standard.data(forKey: devicesKey),
              let list = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: IQDevice.self, from: data) else { return [] }
        return list
    }

    private static func saveDevices(_ devices: [IQDevice]) {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: devices, requiringSecureCoding: true)
        UserDefaults.standard.set(data, forKey: devicesKey)
    }
}

extension WatchLink: IQUIOverrideDelegate, IQDeviceEventDelegate, IQAppMessageDelegate {
    nonisolated func needsToInstallConnectMobile() {
        Task { @MainActor in
            self.problem = Words.t("Garmin Connect is needed to pick the watch. Install it from the App Store, then try again.")
        }
    }

    nonisolated func deviceStatusChanged(_ device: IQDevice, status: IQDeviceStatus) {
        Task { @MainActor in
            self.connected = self.devices.contains { ConnectIQ.sharedInstance().getDeviceStatus($0) == .connected }
        }
    }

    nonisolated func receivedMessage(_ message: Any, from app: IQApp) {
        nonisolated(unsafe) let message = message
        nonisolated(unsafe) let app = app
        Task { @MainActor in self.received(message, from: app) }
    }
}
