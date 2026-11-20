import Foundation

/// How the internet requests are going (0.31.8, David, 18 November 2026: "the
/// app should tell us when the internet is unstable/not connected"). The track
/// service, the buffer server and the map tiles report each request here: a
/// failure is one that never reached the other end (no connection, timed
/// out, the host not found); any answer at all is a request that got through.
/// Unstable: two failures within a minute, until two requests in a row get
/// through.
public final class NetHealth: @unchecked Sendable {
    public static let shared = NetHealth()

    private let lock = NSLock()
    private var failures: [Date] = []
    private var throughSince = 0

    public init() {}

    /// The codes that mean the internet itself did not carry the request.
    public static func isNetwork(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                .timedOut, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
                .secureConnectionFailed, .cannotLoadFromNetwork].contains(error.code)
    }

    /// A request that got an answer, whatever it said.
    public func through(at now: Date = Date()) {
        lock.withLock {
            throughSince += 1
            if throughSince >= 2 { failures.removeAll() }
        }
    }

    /// A request that ended with this error; anything but a network failure is ignored.
    public func failed(_ error: Error, at now: Date = Date()) {
        guard Self.isNetwork(error) else { return }
        lock.withLock {
            throughSince = 0
            failures.append(now)
            failures.removeAll { now.timeIntervalSince($0) > 60 }
        }
    }

    public func unstable(at now: Date = Date()) -> Bool {
        lock.withLock { failures.filter { now.timeIntervalSince($0) <= 60 }.count >= 2 }
    }

    /// Back to nothing known, for tests.
    public func reset() {
        lock.withLock {
            failures.removeAll()
            throughSince = 0
        }
    }
}
