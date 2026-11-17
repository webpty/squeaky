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

    /// Seconds still to go, and how many photos they cover, while photos go up.
    var estimate: (total: TimeInterval, each: TimeInterval?)? {
        guard meter.count > 0, let seconds = model.sendingSeconds() else { return nil }
        let left = model.queueEntries.filter { ($0.state == .waiting || $0.state == .sending) && !$0.held }.count
        return (seconds, left > 0 ? seconds / Double(left) : nil)
    }

    var body: some View {
        let entries = model.queueEntries
        let waiting = entries.filter { ($0.state == .waiting || $0.state == .sending) && !$0.held }.count
        let held = entries.filter { $0.held && $0.state == .waiting }.count
        let sent = entries.filter { $0.state == .sent }.count
        let failed = entries.filter { $0.state == .failed }
        NavigationStack {
            List {
                // Each photo going up, at the top: its name on a blue bar that fills as it
                // goes (0.29.41, David, 17 November 2026).
                if meter.count > 0 {
                    Section(Words.t("Sending")) {
                        ForEach(meter.order, id: \.self) { id in
                            if let going = meter.going[id] {
                                Text(going.name).lineLimit(1).truncationMode(.middle)
                                    .listRowBackground(ProgressFill(fraction: going.fraction))
                            }
                        }
                    }
                }
                Section {
                    if let note = model.backgroundNote { StatusRow(text: note, busy: false) }
                    // While photos go up, the Sending section says it; otherwise why nothing goes.
                    if meter.count == 0 { StatusRow(text: model.queueLine, busy: false) }
                    LabeledContent(Words.t("Waiting"), value: waiting.formatted())
                    if held > 0 { LabeledContent(Words.t("Waiting for the tracks"), value: held.formatted()) }
                    LabeledContent(Words.t("On the NAS"), value: sent.formatted())
                    // Retry as a round button beside the count, once one has failed (0.29.41).
                    HStack {
                        Text(Words.t("Failed"))
                        Spacer()
                        Text(failed.count.formatted()).foregroundStyle(.secondary)
                        if !failed.isEmpty {
                            Button { model.retryFailed() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.circle)
                                .accessibilityLabel(Words.t("Retry failed uploads"))
                        }
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
                // The time, the time per photo and the speed, at the bottom (0.29.41).
                if let estimate {
                    Section {
                        LabeledContent(Words.t("Estimated time"), value: Remaining.approx(estimate.total))
                        if let each = estimate.each {
                            LabeledContent(Words.t("Average time per photo"), value: Remaining.each(each))
                        }
                        if let speed = model.sendingSpeed() {
                            LabeledContent(Words.t("Speed"), value: Words.t(speed.rawValue))
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
                // Pause and resume: a round button, top right (0.29.41).
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.setSendPaused(!model.sendPaused) } label: {
                        Image(systemName: model.sendPaused ? "play.fill" : "pause.fill")
                    }
                    .accessibilityLabel(model.sendPaused ? Words.t("Resume") : Words.t("Pause"))
                }
            }
            .task { await model.checkNAS() }
            .refreshable { await model.checkNAS() }
        }
    }
}

/// A row's background filled in blue from the left as far as the photo has got.
private struct ProgressFill: View {
    let fraction: Double
    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .leading) {
                Color(uiColor: .secondarySystemGroupedBackground)
                Color.blue.opacity(0.45)
                    .frame(width: box.size.width * min(max(fraction, 0), 1))
                    .animation(.linear(duration: 0.4), value: fraction)
            }
        }
    }
}
