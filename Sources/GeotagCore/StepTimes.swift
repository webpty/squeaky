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

/// How fast whole photos went up to the NAS, kept for each address and
/// between launches, so the time left shows from the start and survives a
/// break (David, 5 November 2026: it "easily loses the estimation").
public struct SendSpeeds: Codable, Equatable, Sendable {
    /// Photos the time left goes by, per address: the latest, so a slow patch shows.
    public static let recent = 20
    /// Photos kept per address for slow, average and fast.
    public static let kept = 200
    /// Photos timed, all addresses together, before a speed is called slow or fast.
    public static let neededToRate = 10

    public struct Sample: Codable, Equatable, Sendable {
        public var bytes: Int64
        public var seconds: Double
        public var speed: Double { bytes > 0 && seconds > 0 ? Double(bytes) / seconds : 0 }
    }

    /// Per address, oldest first.
    public var byAddress: [String: [Sample]] = [:]

    public init() {}

    public mutating func add(bytes: Int64, seconds: Double, for address: String) {
        guard bytes > 0, seconds > 0 else { return }
        var list = byAddress[address] ?? []
        list.append(Sample(bytes: bytes, seconds: seconds))
        byAddress[address] = Array(list.suffix(Self.kept))
    }

    /// Bytes a second over the latest photos through this address; nil before the first.
    public func rate(for address: String) -> Double? {
        let list = (byAddress[address] ?? []).suffix(Self.recent)
        let bytes = list.reduce(0) { $0 + Double($1.bytes) }, seconds = list.reduce(0) { $0 + $1.seconds }
        guard bytes > 0, seconds > 0 else { return nil }
        return bytes / seconds
    }

    /// Seconds to send this many bytes through this address, at its recent pace.
    public func seconds(for bytes: Double, through address: String) -> TimeInterval? {
        rate(for: address).map { max(0, bytes) / $0 }
    }

    public enum Rating: String, Sendable {
        case slow = "Slow", average = "Average", fast = "Fast"
    }

    /// Where this speed falls among every photo timed, home and away: the
    /// slowest third slow, the fastest third fast.
    public func rating(of speed: Double) -> Rating? {
        let all = byAddress.values.flatMap { $0 }.map(\.speed).filter { $0 > 0 }
        guard all.count >= Self.neededToRate, speed > 0 else { return nil }
        let below = Double(all.filter { $0 < speed }.count) / Double(all.count)
        if below < 1.0 / 3 { return .slow }
        if below >= 2.0 / 3 { return .fast }
        return .average
    }

    /// The latest photo's speed through this address.
    public func latest(for address: String) -> Double? {
        byAddress[address]?.last?.speed
    }
}
