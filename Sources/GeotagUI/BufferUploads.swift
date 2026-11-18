import Foundation
import GeotagCore

/// Photos going up to the buffer server. On the iPhone they go through the
/// phone's own background transfers, which carry on while Geotag is closed or
/// the phone locked, with no notification (0.30.0); on the Mac through an
/// ordinary connection. Each transfer carries its queue entry's id.
public final class BufferUploads: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public static let identifier = (Bundle.main.bundleIdentifier ?? "com.webpty.geotag") + ".buffer"

    /// How far a photo has got, 0 to 1.
    var onProgress: (@MainActor (UUID, Double) -> Void)?
    /// A photo done: nil when it is safely there, else why not, and whether to try again later.
    var onDone: (@MainActor (UUID, (why: String, again: Bool)?, TimeInterval?) -> Void)?
    /// The phone's call to say all background transfers have been handed back.
    public var finishEvents: (() -> Void)?

    private let lock = NSLock()
    /// Bytes gone up, all photos together, with when: the pace of the whole batch (0.30.3).
    private var sentLog: [(at: Date, bytes: Int64)] = []
    private var started: [Int: Date] = [:]
    private var answers: [Int: Data] = [:]
    private lazy var session: URLSession = {
        #if os(iOS)
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        #else
        let config = URLSessionConfiguration.default
        #endif
        config.httpMaximumConnectionsPerHost = 2
        // A photo may stall up to ten minutes before it is started again (0.31.5).
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Bytes a second over the last three minutes, every photo going up
    /// counted together: many share one connection, so one photo's own time
    /// says little (David, 17 November 2026: "36h left"). Nil until 20 s of it.
    public func pace() -> Double? {
        lock.withLock {
            guard let first = sentLog.first, let last = sentLog.last else { return nil }
            let span = last.at.timeIntervalSince(first.at)
            guard span >= 20 else { return nil }
            return Double(sentLog.reduce(0) { $0 + $1.bytes }) / span
        }
    }

    /// Reconnects to transfers begun before Geotag was closed.
    public func wake() { _ = session }

    /// The queue entries whose photos are on their way now.
    func inFlight() async -> Set<UUID> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }
            .compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
    }

    func send(_ entry: UUID, file: URL, request: URLRequest) {
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = entry.uuidString
        task.resume()
    }

    /// Paused: every photo on its way stops and waits again.
    func cancelAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                           totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        // The clock starts when the photo really starts going up, not when it was
        // handed over to wait its turn (0.30.2, David: "2 min 18 s per photo").
        lock.withLock {
            if started[task.taskIdentifier] == nil { started[task.taskIdentifier] = Date().addingTimeInterval(-0.5) }
            let now = Date()
            sentLog.append((now, bytesSent))
            sentLog.removeAll { now.timeIntervalSince($0.at) > 180 }
        }
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)), totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor [weak self] in self?.onProgress?(id, fraction) }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { answers[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let (began, answer) = lock.withLock { (started.removeValue(forKey: task.taskIdentifier), answers.removeValue(forKey: task.taskIdentifier)) }
        let seconds = began.map { Date().timeIntervalSince($0) }
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        var outcome: (why: String, again: Bool)?
        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            outcome = (cancelled ? Words.t("Paused.") : error.localizedDescription, true)
        } else if code != 201 {
            let said = answer.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["error"]
            switch code {
            case 404, 403: outcome = (Words.t("The buffer server doesn't know this key."), true)
            case 422: outcome = (Words.t("It arrived at the buffer server different from the copy here."), true)
            case 400, 411: outcome = (said ?? Words.t("The buffer server refused it."), false)
            default: outcome = (said ?? Words.t("The buffer server answered {0}.", code), true)
            }
        }
        Task { @MainActor [weak self] in self?.onDone?(id, outcome, outcome == nil ? seconds : nil) }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.finishEvents?()
            self?.finishEvents = nil
        }
    }
}
