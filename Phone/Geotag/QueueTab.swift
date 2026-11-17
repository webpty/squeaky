import GeotagCore
import GeotagUI
import SwiftUI

/// The copies on their way to the NAS.
struct QueueTab: View {
    @ObservedObject var model: AppModel

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
                    StatusRow(text: model.queueLine, busy: model.meter.count > 0)
                    LabeledContent(Words.t("NAS"), value: QueueText.reach(model.nasReach))
                    LabeledContent(Words.t("Waiting"), value: waiting.formatted())
                    if held > 0 { LabeledContent(Words.t("Waiting for the tracks"), value: held.formatted()) }
                    LabeledContent(Words.t("On the NAS"), value: sent.formatted())
                    LabeledContent(Words.t("Failed"), value: failed.count.formatted())
                }
                Section {
                    Button(model.sendPaused ? Words.t("Resume") : Words.t("Pause")) { model.setSendPaused(!model.sendPaused) }
                    Button(Words.t("Retry failed")) { model.retryFailed() }
                        .disabled(failed.isEmpty)
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
            .toolbar { PageTitle(title: Words.t("Queue")) }
            .task { await model.checkNAS() }
            .refreshable { await model.checkNAS() }
        }
    }
}
