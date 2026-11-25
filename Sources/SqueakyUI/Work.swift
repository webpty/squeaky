import Foundation
import Combine

/// What Squeaky is busy with, for the icon in the menu bar: one line for each
/// thing going on, and how far the first of them has got (David, 18 October
/// 2026). Nothing going on, no icon.
@MainActor
public final class WorkStatus: ObservableObject {
    /// "Saving 340 of 3,630", "Sending to the NAS: 12 of 200".
    @Published public private(set) var lines: [String] = []
    /// 0 to 1, in fortieths so the icon is not drawn again for every photo;
    /// nil when it cannot be said.
    @Published public private(set) var fraction: Double?

    public var shown: Bool { !lines.isEmpty }

    public init() {}

    func set(lines: [String], fraction: Double?) {
        let steps = fraction.map { (min(max($0, 0), 1) * 40).rounded(.down) / 40 }
        if self.lines != lines { self.lines = lines }
        if self.fraction != steps { self.fraction = steps }
    }
}

