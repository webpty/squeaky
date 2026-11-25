import Foundation
import SqueakyCore

/// Somewhere photos come from: a camera card, or a folder chosen by hand.
public struct PhotoSource: Identifiable, Equatable, Sendable {
    /// The card's volume id, or the folder's path.
    public var id: String
    public var name: String
    public var url: URL
    public var isCard: Bool
    /// The card's disk, as the Mac names it ("disk6s1"), for ejecting it.
    public var bsd: String?

    public init(id: String, name: String, url: URL, isCard: Bool, bsd: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.isCard = isCard
        self.bsd = bsd
    }
}


public enum Windows {

    /// Squeaky to the front, opening its window again if it was closed.
    @MainActor
    public static func bringForward() {
    }
}
