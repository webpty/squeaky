import BackgroundTasks
import Combine
import GeotagCore
import GeotagUI
import UIKit

/// A save, then the sending that follows, kept going while Geotag is in the
/// background (0.29.15, David, 16 November 2026): the phone shows its
/// progress on the Lock Screen and at the top of the screen, and cancelling
/// it there is Stop. Without it, the phone pauses Geotag half a minute after
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
    static let prefix = (Bundle.main.bundleIdentifier ?? "com.webpty.geotag") + ".work."

    init(model: AppModel) {
        self.model = model
    }

    /// Watches for a save beginning, or sending beginning without a save
    /// (0.29.29); each asks the phone to let it run on.
    func start() {
        watching = model.$saving.removeDuplicates().sink { [weak self] saving in
            if saving { Task { @MainActor in self?.begin() } }
        }
        watchingSends = model.meter.$going.map { !$0.isEmpty }.removeDuplicates().sink { [weak self] sending in
            guard sending else { return }
            Task { @MainActor in
                // Asked only while Geotag is in front: the phone takes no request from the background.
                guard UIApplication.shared.applicationState == .active else { return }
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

    /// Said when Geotag is back in front (0.29.29, David, 17 November 2026:
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
            refused = Words.t("The phone won't let Geotag keep saving in the background; keep it open until it's done.")
            return
        }
        let request = model.saving
            ? BGContinuedProcessingTaskRequest(identifier: id, title: Words.t("Saving photos"),
                                               subtitle: Words.t("Saving {0} of {1}", model.saveDone + 1, model.saveTotal))
            : BGContinuedProcessingTaskRequest(identifier: id, title: Words.t("Sending to the NAS"), subtitle: "")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            asked = true
            refused = nil
            // Never started by the phone within ten seconds: free to ask again.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                if running == nil { asked = false }
            }
        } catch {
            refused = Words.t("The phone won't let Geotag keep saving in the background; keep it open until it's done.") + " " + error.localizedDescription
        }
    }

    @available(iOS 26, *)
    private func run(_ task: BGContinuedProcessingTask) {
        running = task
        let progress = task.progress
        var stopped = false
        let startSent = model.queueEntries.filter { $0.state == .sent }.count
        task.expirationHandler = { [weak self] in
            // Cancelled on the Lock Screen, or ended by the phone: a save stops as with Stop;
            // sending is said when Geotag is back in front, and carries on then.
            Task { @MainActor in
                guard let self else { return }
                stopped = true
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
            while !stopped {
                // A save, whenever one is going.
                if model.saving {
                    progress.totalUnitCount = Int64(max(model.saveTotal, 1))
                    progress.completedUnitCount = Int64(model.saveDone)
                    task.updateTitle(Words.t("Saving photos"), subtitle: Words.t("Saving {0} of {1}", min(model.saveDone + 1, model.saveTotal), model.saveTotal))
                    idle = 0
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                // Then the sending, until nothing that can go now is waiting.
                let (sent, waiting) = counts(since: startSent)
                if waiting == 0 { model.backgroundNote = nil; break }
                // The server away: nothing moves; given up after a minute, and said.
                if model.meter.count == 0 { idle += 1 } else { idle = 0 }
                if idle > 120 {
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
    /// far it got, never as failed, since it carries on when Geotag is open
    /// (0.29.32, David, 17 November 2026: "we need more details").
    @available(iOS 26, *)
    private func paused(_ task: BGContinuedProcessingTask, sent: Int, total: Int) {
        finish(task, title: Words.t("Sending paused"),
               detail: Words.t("{0} of {1} sent. It carries on when Geotag is open.", sent, total))
    }

    /// The one notification closed, with its last words when given; only
    /// then may another start.
    @available(iOS 26, *)
    private func finish(_ task: BGContinuedProcessingTask, title: String?, detail: String?) {
        guard running != nil else { return }
        if let title { task.updateTitle(title, subtitle: detail ?? "") }
        task.setTaskCompleted(success: true)
        running = nil
        asked = false
    }
}
