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
                    StatusRow(text: model.queueLine, busy: model.meter.count > 0)
                    LabeledContent("NAS", value: QueueText.reach(model.nasReach))
                    LabeledContent("Waiting", value: waiting.formatted())
                    if held > 0 { LabeledContent("Waiting for the tracks", value: held.formatted()) }
                    LabeledContent("On the NAS", value: sent.formatted())
                    LabeledContent("Not sent", value: failed.count.formatted())
                }
                Section {
                    Button(model.sendPaused ? "Resume" : "Pause") { model.setSendPaused(!model.sendPaused) }
                    Button("Retry failed") { model.retryFailed() }
                        .disabled(failed.isEmpty)
                }
                if !failed.isEmpty {
                    Section("Not sent") {
                        ForEach(failed) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text((entry.relativePath as NSString).lastPathComponent)
                                Text(QueueText.status(entry)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .task { await model.checkNAS() }
            .refreshable { await model.checkNAS() }
        }
    }
}
