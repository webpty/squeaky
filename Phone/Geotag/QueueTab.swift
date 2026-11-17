import GeotagCore
import GeotagUI
import SwiftUI

/// The copies on their way to the NAS.
struct QueueTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meter: SendMeter

    init(model: AppModel) {
        self.model = model
        self.meter = model.meter
    }

    /// "≈ 9 h 15 min left", beside the title while photos go up (0.29.33).
    var timeLeft: String? {
        guard meter.count > 0, let seconds = model.sendingSeconds() else { return nil }
        return Words.t("{0} left", Remaining.approx(seconds))
    }

    var body: some View {
        let entries = model.queueEntries
        let waiting = entries.filter { ($0.state == .waiting || $0.state == .sending) && !$0.held }.count
        let held = entries.filter { $0.held && $0.state == .waiting }.count
        let sent = entries.filter { $0.state == .sent }.count
        let failed = entries.filter { $0.state == .failed }
        NavigationStack {
            List {
                Section {
                    if let note = model.backgroundNote { StatusRow(text: note, busy: false) }
                    // While photos go up, the Sending section below says it; otherwise why nothing goes.
                    if meter.count == 0 { StatusRow(text: model.queueLine, busy: false) }
                    LabeledContent(Words.t("NAS"), value: QueueText.reach(model.nasReach))
                    LabeledContent(Words.t("Waiting"), value: waiting.formatted())
                    if held > 0 { LabeledContent(Words.t("Waiting for the tracks"), value: held.formatted()) }
                    LabeledContent(Words.t("On the NAS"), value: sent.formatted())
                    LabeledContent(Words.t("Failed"), value: failed.count.formatted())
                }
                // Each photo going up: its name, the wheel at the right edge so it
                // stays put when the name changes (0.29.33, David, 17 November 2026).
                if meter.count > 0 {
                    Section(Words.t("Sending")) {
                        ForEach(meter.order, id: \.self) { id in
                            if let going = meter.going[id] {
                                HStack {
                                    Text(going.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                    }
                }
                Section {
                    HStack(spacing: 12) {
                        HalfButton(model.sendPaused ? Words.t("Resume") : Words.t("Pause")) { model.setSendPaused(!model.sendPaused) }
                        HalfButton(Words.t("Retry failed uploads")) { model.retryFailed() }
                            .disabled(failed.isEmpty)
                    }
                }
                if !failed.isEmpty {
                    Section(Words.t("Failed")) {
                        ForEach(failed) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text((entry.relativePath as NSString).lastPathComponent)
                                Sentences(text: QueueText.status(entry)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            // The last card's photo behind every tab, veiled (0.29.5, David, 16 November 2026).
            .background(Backdrop(image: model.sidebarImage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PageTitle(title: Words.t("Queue"))
                if let timeLeft {
                    if #available(iOS 26, *) {
                        ToolbarItem(placement: .topBarTrailing) { TimeLeft(text: timeLeft) }
                            .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .topBarTrailing) { TimeLeft(text: timeLeft) }
                    }
                }
            }
            .task { await model.checkNAS() }
            .refreshable { await model.checkNAS() }
        }
    }
}

/// The time left in the top row, plain words, not a button.
private struct TimeLeft: View {
    let text: String
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }
}
