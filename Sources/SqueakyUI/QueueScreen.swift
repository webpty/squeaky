import Foundation
import SwiftUI
import SqueakyCore

/// Whether the NAS answers, and at which address: asked as Squeaky opens,
/// whenever the Queue page is shown, and with every photo sent.
public enum NASReach: Equatable {
    /// The first answer is not in yet.
    case checking
    case through(String)
    case unreachable
    /// No NAS address in Settings, or nobody with a NAS folder.
    case notSetUp
}

/// The photos going up to the NAS now and how far each has got, kept apart
/// from the model so that their progress redraws only what shows it.
@MainActor
public final class SendMeter: ObservableObject {
    public struct Going: Equatable {
        public var name: String
        public var step: SendStep
        public var weights = StepWeights.guess

        /// How far the whole photo has got.
        public var fraction: Double { step.whole(weights) }
        public var percent: String { "\(Int((fraction * 100).rounded(.down)))%" }
        /// "Sending 42%", the share of the whole photo.
        public var text: String { "\(step.word) \(percent)" }
    }

    @Published public private(set) var going: [UUID: Going] = [:]
    /// Oldest first, as they began.
    public private(set) var order: [UUID] = []

    public var count: Int { going.count }

    /// How far the photos going up have got between them, as photos: two
    /// halfway is 1.
    public var done: Double { going.values.map(\.fraction).reduce(0, +) }

    /// The one photo going up, when only one is.
    public var only: Going? { going.count == 1 ? going.values.first : nil }

    func begin(_ id: UUID, name: String, weights: StepWeights = .guess) {
        going[id] = Going(name: name, step: .looking, weights: weights)
        order.append(id)
    }

    func show(_ step: SendStep, for id: UUID) {
        if let now = going[id], now.step != step { going[id]?.step = step }
    }

    func end(_ id: UUID) {
        going[id] = nil
        order.removeAll { $0 == id }
    }
}

