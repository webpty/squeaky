import BackgroundTasks
import Combine
import SqueakyCore
import SqueakyUI
import UIKit

/// A save, then the sending that follows, kept going while Squeaky is in the
/// background (0.29.15, David, 16 November 2026): the phone shows its
/// progress on the Lock Screen and at the top of the screen, and cancelling
/// it there is Stop. Without it, the phone pauses Squeaky half a minute after
/// it leaves the screen.
@MainActor
final class BackgroundWork {
    private let model: AppModel
    private var watching: AnyCancellable?
    private var running: AnyObject?
    /// A request handed to the phone and not finished yet: never a second one
    /// beside it, so only one notification shows (0.29.32).
    private var asked = false
    /// Set when the phone would not take the work, said on the Photos line.
    private(set) var refused: String?
    static let prefix = (Bundle.main.bundleIdentifier ?? "geotrac.squeaky") + ".work."

    init(model: AppModel) {
        self.model = model
    }

    /// Watches for a save beginning, or sending beginning without a save
    /// (0.29.29); each asks the phone to let it run on.
    func start() {
        RunLog.watchTheApp()
        // Where each photo's time goes, for finding why sending is slow (0.29.45, David).
        model.onPhotoTimed = { name, bytes, steps in
            let mb = Double(bytes) / 1_000_000
            let total = steps.reduce(0, +)
            let parts = zip(["looking", "sending", "reading back", "naming"], steps).map { String(format: "%@ %.1f s", $0, $1) }
            RunLog.add(String(format: "photo %@, %.1f MB, %.1f s: ", name, mb, total) + parts.joined(separator: ", ")
                       + String(format: ", %.2f MB/s sending", steps[1] > 0 ? mb / steps[1] : 0))
        }
        watching = model.$saving.removeDuplicates().sink { [weak self] saving in
            if saving { Task { @MainActor in self?.begin() } }
        }
        watchingSends = model.meter.$going.map { !$0.isEmpty }.removeDuplicates().sink { [weak self] sending in
            guard sending else { return }
            Task { @MainActor in
                // Asked only while Squeaky is in front: the phone takes no request from the background.
                guard UIApplication.shared.applicationState == .active else { return }
                // Through the buffer server the phone's own transfers carry on: no notification (0.30.0).
                guard self?.model.sendRoute != .buffer else { return }
                self?.begin()
            }
        }
    }

    private var watchingSends: AnyCancellable?

    /// Photos still waiting to go now, and sent since the work began.
    private func counts(since startSent: Int) -> (sent: Int, waiting: Int) {
        let entries = model.queueEntries
        let waiting = entries.filter { ($0.state == .waiting || $0.state == .sending) && !$0.held }.count
        return (entries.filter { $0.state == .sent }.count - startSent, waiting)
    }

    /// Said when Squeaky is back in front (0.29.29, David, 17 November 2026:
    /// "the phone didn't like sending while locked").
    private func noteStopped(sent: Int, total: Int, why: String?) {
        guard UIApplication.shared.applicationState != .active else { return }
        var line = Words.t("Sending stopped while the phone was locked, after {0} of {1}.", sent, total)
        if let why { line += " " + why }
        model.backgroundNote = line + " " + Words.t("Carrying on now.")
    }

    /// True while the phone has taken the work on: the screen need not stay on.
    var isRunning: Bool { running != nil }

    private func begin() {
        guard #available(iOS 26, *), running == nil, !asked else { return }
        let id = Self.prefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in self?.run(task) }
        }
        guard registered else {
            RunLog.add("not registered")
            refused = Words.t("The phone won't let Squeaky keep saving in the background; keep it open until it's done.")
            return
        }
        let request = model.saving
            ? BGContinuedProcessingTaskRequest(identifier: id, title: Words.t("Saving photos"),
                                               subtitle: Words.t("Saving {0} of {1}", model.saveDone + 1, model.saveTotal))
            : BGContinuedProcessingTaskRequest(identifier: id, title: Words.t("Sending to the NAS"), subtitle: "")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            RunLog.add("asked: \(model.saving ? "saving \(model.saveDone) of \(model.saveTotal)" : "sending, \(counts(since: 0).waiting) waiting")")
            asked = true
            refused = nil
            // Never started by the phone within ten seconds: free to ask again.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                if running == nil, asked { asked = false; RunLog.add("not started by the phone within 10 s") }
            }
        } catch {
            RunLog.add("refused: \(error.localizedDescription)")
            refused = Words.t("The phone won't let Squeaky keep saving in the background; keep it open until it's done.") + " " + error.localizedDescription
        }
    }

    @available(iOS 26, *)
    private func run(_ task: BGContinuedProcessingTask) {
        running = task
        RunLog.add("started")
        let progress = task.progress
        var stopped = false
        let startSent = model.queueEntries.filter { $0.state == .sent }.count
        task.expirationHandler = { [weak self] in
            // Cancelled on the Lock Screen, or ended by the phone: a save stops as with Stop;
            // sending is said when Squeaky is back in front, and carries on then.
            Task { @MainActor in
                guard let self else { return }
                stopped = true
                let at = self.counts(since: startSent)
                RunLog.add("ended by the iPhone: \(self.model.saving ? "saving \(self.model.saveDone) of \(self.model.saveTotal)" : "sent \(at.sent), \(at.waiting) waiting"), \(RunLog.state())")
                if self.model.saving {
                    self.model.stopSaving()
                    self.finish(task, title: Words.t("Saving stopped"),
                                detail: Words.t("{0} of {1} saved.", self.model.saveDone, self.model.saveTotal))
                    return
                }
                let now = self.counts(since: startSent)
                if now.waiting > 0 { self.noteStopped(sent: now.sent, total: now.sent + now.waiting, why: nil) }
                self.paused(task, sent: now.sent, total: now.sent + now.waiting)
            }
        }
        Task { @MainActor in
            var idle = 0
            var beat = 0
            while !stopped {
                // Every 30 s, how far it has got and how the phone stands (0.29.41).
                beat += 1
                if beat % 60 == 0 {
                    let at = counts(since: startSent)
                    RunLog.add("running: \(model.saving ? "saving \(model.saveDone) of \(model.saveTotal)" : "sent \(at.sent), \(at.waiting) waiting, \(model.meter.count) going"), \(RunLog.state())")
                }
                // A save, whenever one is going.
                if model.saving {
                    progress.totalUnitCount = Int64(max(model.saveTotal, 1))
                    progress.completedUnitCount = Int64(model.saveDone)
                    task.updateTitle(Words.t("Saving photos"), subtitle: Words.t("Saving {0} of {1}", min(model.saveDone + 1, model.saveTotal), model.saveTotal))
                    idle = 0
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                // Through the buffer server the phone's own transfers take over: done here (0.30.0).
                if model.sendRoute == .buffer { model.backgroundNote = nil; RunLog.add("handed to the buffer server"); break }
                // Then the sending, until nothing that can go now is waiting.
                let (sent, waiting) = counts(since: startSent)
                if waiting == 0 { model.backgroundNote = nil; RunLog.add("all sent: \(sent)"); break }
                // The server away: nothing moves; given up after a minute, and said.
                if model.meter.count == 0 { idle += 1 } else { idle = 0 }
                if idle > 120 {
                    RunLog.add("given up: the server not answering, sent \(sent), \(waiting) waiting")
                    noteStopped(sent: sent, total: sent + waiting, why: Words.t("The NAS wasn't answering."))
                    paused(task, sent: sent, total: sent + waiting)
                    return
                }
                // Moves with each part of a photo, not once per photo (0.29.29): progress
                // that stands still for long can make the phone end the work.
                progress.totalUnitCount = Int64(max(sent + waiting, 1)) * 100
                progress.completedUnitCount = Int64(sent) * 100 + Int64((model.meter.done * 100).rounded(.down))
                task.updateTitle(Words.t("Sending to the NAS"), subtitle: Words.t("{0} of {1}", sent, sent + waiting))
                try? await Task.sleep(for: .milliseconds(500))
            }
            // Stopped by the phone or on the Lock Screen: already ended above.
            guard !stopped else { return }
            progress.completedUnitCount = progress.totalUnitCount
            finish(task, title: nil, detail: nil)
        }
    }

    /// Sending ended before everything was sent: said as paused, with how
    /// far it got, never as failed, since it carries on when Squeaky is open
    /// (0.29.32, David, 17 November 2026: "we need more details").
    @available(iOS 26, *)
    private func paused(_ task: BGContinuedProcessingTask, sent: Int, total: Int) {
        finish(task, title: Words.t("Sending paused"),
               detail: Words.t("{0} of {1} sent. It carries on when Squeaky is open.", sent, total))
    }

    /// The one notification closed, with its last words when given; only
    /// then may another start.
    @available(iOS 26, *)
    private func finish(_ task: BGContinuedProcessingTask, title: String?, detail: String?) {
        guard running != nil else { return }
        RunLog.add("closed by Squeaky: \(title ?? "done") \(detail ?? "")")
        if let title { task.updateTitle(title, subtitle: detail ?? "") }
        task.setTaskCompleted(success: true)
        running = nil
        asked = false
    }
}

/// A record on the phone of each run in the background, read over the cable
/// to find why the iPhone says "Task failed" (0.29.41, David, 17 November
/// 2026). Library/Application Support/Squeaky/background-runs.log, the
/// newest 3000 lines kept.
@MainActor
enum RunLog {
    private static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Squeaky").appendingPathComponent("background-runs.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return f
    }()
    private static var watching: [NSObjectProtocol] = []

    static func add(_ line: String) {
        let text = stamp.string(from: Date()) + "  " + appVersion + "  " + line + "\n"
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var all = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        all += text
        let lines = all.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count > 3000 { all = lines.suffix(3000).joined(separator: "\n") + "\n" }
        try? all.write(to: file, atomically: true, encoding: .utf8)
    }

    /// In front or not, locked or not, and the time the phone still allows.
    static func state() -> String {
        let app = UIApplication.shared
        let place: String
        switch app.applicationState {
        case .active: place = "in front"
        case .inactive: place = "inactive"
        case .background: place = "in the background"
        @unknown default: place = "unknown"
        }
        let left = app.backgroundTimeRemaining
        return place + (app.isProtectedDataAvailable ? ", unlocked" : ", locked")
            + (left < 100_000 ? String(format: ", %.0f s allowed", left) : "")
    }

    /// Squeaky opening, going to the background, the phone locking and unlocking, and Squeaky closing.
    static func watchTheApp() {
        guard watching.isEmpty else { return }
        add("Squeaky opened")
        let centre = NotificationCenter.default
        let events: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "Squeaky in the background"),
            (UIApplication.willEnterForegroundNotification, "Squeaky back in front"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "phone locked"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "phone unlocked"),
            (UIApplication.willTerminateNotification, "Squeaky closing"),
            (UIApplication.didReceiveMemoryWarningNotification, "memory warning"),
        ]
        for (name, words) in events {
            watching.append(centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { add(words) }
            })
        }
    }
}
