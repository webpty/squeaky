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
    /// Set when the phone would not take the work, said on the Photos line.
    private(set) var refused: String?
    static let prefix = (Bundle.main.bundleIdentifier ?? "com.webpty.geotag") + ".work."

    init(model: AppModel) {
        self.model = model
    }

    /// Watches for a save beginning; each one asks the phone to let it run on.
    func start() {
        watching = model.$saving.removeDuplicates().sink { [weak self] saving in
            if saving { Task { @MainActor in self?.begin() } }
        }
    }

    /// True while the phone has taken the work on: the screen need not stay on.
    var isRunning: Bool { running != nil }

    private func begin() {
        guard #available(iOS 26, *), running == nil else { return }
        let id = Self.prefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in self?.run(task) }
        }
        guard registered else {
            refused = Words.t("The phone won't let Geotag keep saving in the background; keep it open until it's done.")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: Words.t("Saving photos"),
                                                       subtitle: Words.t("Saving {0} of {1}", model.saveDone + 1, model.saveTotal))
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            refused = nil
        } catch {
            refused = Words.t("The phone won't let Geotag keep saving in the background; keep it open until it's done.") + " " + error.localizedDescription
        }
    }

    @available(iOS 26, *)
    private func run(_ task: BGContinuedProcessingTask) {
        running = task
        let progress = task.progress
        var stopped = false
        task.expirationHandler = { [weak self] in
            // Cancelled on the Lock Screen, or ended by the phone: the same as Stop.
            Task { @MainActor in
                stopped = true
                self?.model.stopSaving()
            }
        }
        Task { @MainActor in
            // The save first.
            while model.saving, !stopped {
                progress.totalUnitCount = Int64(max(model.saveTotal, 1))
                progress.completedUnitCount = Int64(model.saveDone)
                task.updateTitle(Words.t("Saving photos"), subtitle: Words.t("Saving {0} of {1}", min(model.saveDone + 1, model.saveTotal), model.saveTotal))
                try? await Task.sleep(for: .milliseconds(500))
            }
            // Then the sending, until nothing that can go now is waiting.
            let startSent = model.queueEntries.filter { $0.state == .sent }.count
            var idle = 0
            while !stopped {
                let entries = model.queueEntries
                let waiting = entries.filter { ($0.state == .waiting || $0.state == .sending) && !$0.held }.count
                let sent = entries.filter { $0.state == .sent }.count - startSent
                if waiting == 0 { break }
                // The server away: nothing moves; given up after a minute.
                if model.meter.count == 0 { idle += 1 } else { idle = 0 }
                if idle > 120 { break }
                progress.totalUnitCount = Int64(max(sent + waiting, 1))
                progress.completedUnitCount = Int64(sent)
                task.updateTitle(Words.t("Sending to the NAS"), subtitle: Words.t("{0} of {1}", sent, sent + waiting))
                try? await Task.sleep(for: .milliseconds(500))
            }
            progress.completedUnitCount = progress.totalUnitCount
            task.setTaskCompleted(success: !stopped)
            running = nil
        }
    }
}
