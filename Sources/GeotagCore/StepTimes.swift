import Foundation

/// Each step's share of a photo's time going up to the NAS: how much of the
/// bar it fills.
public struct StepWeights: Equatable, Sendable {
    public var looking: Double
    public var sending: Double
    public var checking: Double
    public var naming: Double

    public init(looking: Double, sending: Double, checking: Double, naming: Double) {
        self.looking = looking
        self.sending = sending
        self.checking = checking
        self.naming = naming
    }

    /// Until a link has photos timed.
    public static let guess = StepWeights(looking: 0.02, sending: 0.60, checking: 0.36, naming: 0.02)
}

/// How long each step took for the last photos sent, kept for each NAS
/// address: at home and through Tailscale they differ. The bar follows them
/// (David, 2 November 2026: "reflect reality more").
public struct StepTimes: Codable, Equatable, Sendable {
    public static let kept = 20
    public static let needed = 3

    /// Per address, oldest first: seconds for looking, sending, checking, naming.
    public var byAddress: [String: [[Double]]] = [:]

    public init() {}

    public mutating func add(_ seconds: [Double], for address: String) {
        guard seconds.count == 4, seconds.allSatisfy({ $0 >= 0 }), seconds.reduce(0, +) > 0 else { return }
        var list = byAddress[address] ?? []
        list.append(seconds)
        byAddress[address] = Array(list.suffix(Self.kept))
    }

    /// Each step's share of the time these photos took between them.
    public func weights(for address: String) -> StepWeights {
        let list = byAddress[address] ?? []
        guard list.count >= Self.needed else { return .guess }
        let sums = (0..<4).map { i in list.map { $0[i] }.reduce(0, +) }
        let total = sums.reduce(0, +)
        guard total > 0 else { return .guess }
        return StepWeights(looking: sums[0] / total, sending: sums[1] / total, checking: sums[2] / total, naming: sums[3] / total)
    }
}

/// Times one photo's steps as they are reported, on whatever thread sends it.
public final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var began: [Date?] = [nil, nil, nil, nil]

    public init() {}

    public func saw(_ step: SendStep) {
        lock.withLock {
            if began[step.index] == nil { began[step.index] = Date() }
        }
    }

    /// Seconds for each step, ending now; nil unless all four were seen.
    public func seconds(endedAt end: Date = Date()) -> [Double]? {
        lock.withLock {
            let starts = began.compactMap { $0 }
            guard starts.count == 4 else { return nil }
            return (0..<4).map { i in (i == 3 ? end : starts[i + 1]).timeIntervalSince(starts[i]) }
        }
    }
}
