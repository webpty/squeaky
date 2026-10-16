import SwiftUI

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

    private let defaults = UserDefaults.standard

    public init() {
        if let raw = defaults.string(forKey: "appearance"), let mode = Appearance(rawValue: raw) {
            appearance = mode
        }
    }

    public func setAppearance(_ mode: Appearance) {
        appearance = mode
        defaults.set(mode.rawValue, forKey: "appearance")
    }
}
