import SwiftUI
import GeotagCore

/// Whether the NAS answers, and at which address: asked as Geotag opens,
/// whenever the Queue page is shown, and with every photo sent.
public enum NASReach: Equatable {
    /// The first answer is not in yet.
    case checking
    case through(String)
    case unreachable
    /// No NAS address in Settings, or nobody with a NAS folder.
    case notSetUp
}

/// The photo going up to the NAS now and how far it has got, kept apart from
/// the model so that its progress redraws only what shows it.
@MainActor
public final class SendMeter: ObservableObject {
    @Published public private(set) var name: String?
    @Published public private(set) var fraction = 0.0

    func begin(_ name: String) {
        self.name = name
        fraction = 0
    }

    func show(_ fraction: Double, for name: String) {
        if self.name == name, self.fraction != fraction { self.fraction = fraction }
    }

    func end() {
        name = nil
        fraction = 0
    }
}

enum QueueText {
    static func status(_ entry: QueueEntry) -> String {
        switch entry.state {
        case .waiting: return "Waiting"
        case .sending: return "Sending"
        case .sent: return entry.sentAs.map { "On the NAS as \($0)" } ?? "On the NAS"
        case .failed: return "Not sent: \(entry.reason ?? "")"
        }
    }

    /// A photo on the Photos page, once saved on this Mac.
    static func photo(_ entry: QueueEntry) -> String {
        switch entry.state {
        case .waiting: return "Waiting for the NAS"
        case .sending: return "Sending to the NAS"
        case .sent: return "On the NAS"
        case .failed: return "Not on the NAS: \(entry.reason ?? "")"
        }
    }

    static func reach(_ reach: NASReach) -> String {
        switch reach {
        case .checking: return "Checking"
        case .through(let address): return NASOverSMB.host(address) ?? address
        case .unreachable: return "Not reachable"
        case .notSetUp: return "Not set up"
        }
    }
}

struct QueueRow: Identifiable {
    let entry: QueueEntry
    let person: String
    var id: UUID { entry.id }
}

struct QueueScreen: View {
    @EnvironmentObject var model: AppModel

    /// What is going up, then what goes next, then what was not sent, then
    /// what is on the NAS, newest first.
    private var rows: [QueueRow] {
        func rank(_ state: QueueState) -> Int {
            switch state {
            case .sending: return 0
            case .waiting: return 1
            case .failed: return 2
            case .sent: return 3
            }
        }
        let names = Dictionary(model.book.people.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return model.queueEntries.sorted { a, b in
            if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
            if a.state == .sent { return (a.sent ?? a.added) > (b.sent ?? b.added) }
            return a.added < b.added
        }
        .map { QueueRow(entry: $0, person: names[$0.personId] ?? "") }
    }

    var body: some View {
        let entries = model.queueEntries
        let waiting = entries.filter { $0.state == .waiting || $0.state == .sending }.count
        let sent = entries.filter { $0.state == .sent }.count
        let failed = entries.filter { $0.state == .failed }.count
        VStack(alignment: .leading, spacing: Style.gap) {
            HStack(spacing: Style.gap) {
                ScreenTitle(text: "Queue")
                Button {
                    model.setSendPaused(!model.sendPaused)
                } label: {
                    Text(model.sendPaused ? "Resume" : "Pause").buttonLabel()
                }
                Button {
                    model.retryFailed()
                } label: {
                    Text("Retry failed").buttonLabel()
                }
                .disabled(failed == 0)
            }

            HStack(spacing: Style.gap) {
                Tile(label: "NAS", value: QueueText.reach(model.nasReach))
                Tile(label: "Waiting", value: waiting.formatted())
                Tile(label: "On the NAS", value: sent.formatted())
                Tile(label: "Not sent", value: failed.formatted())
            }

            if model.nasAway {
                HStack(alignment: .firstTextBaseline, spacing: Style.gap) {
                    StatusLine(text: AppModel.nasAwayText, lines: 2)
                    if Tailscale.app != nil {
                        Button {
                            Tailscale.open()
                        } label: {
                            Text("Open Tailscale").buttonLabel()
                        }
                        .fixedSize()
                    }
                    Spacer()
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SendBar(meter: model.meter).levelWithText()
                StatusLine(text: model.queueLine, lines: 2)
                Spacer()
            }
            .frame(minHeight: 40)

            Table(rows) {
                TableColumn("Name") { row in
                    Text((row.entry.relativePath as NSString).lastPathComponent).lineLimit(1)
                }
                .width(min: 100, ideal: 140)
                TableColumn("Person") { row in
                    Text(row.person).lineLimit(1)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Folder") { row in
                    Text((row.entry.relativePath as NSString).deletingLastPathComponent).monospacedDigit().lineLimit(1)
                }
                .width(min: 80, ideal: 90)
                TableColumn("Saved") { row in
                    Text(When.current.dayAndTime(row.entry.added)).lineLimit(1)
                }
                .width(min: 150, ideal: 180)
                TableColumn("Status") { row in
                    if row.entry.state == .sending {
                        SendingText(meter: model.meter)
                    } else {
                        Text(QueueText.status(row.entry))
                            .foregroundStyle(row.entry.state == .sent ? .primary : .secondary)
                            .lineLimit(1)
                    }
                }
                .width(min: 150, ideal: 220)
            }
            .clipShape(RoundedRectangle(cornerRadius: Style.radius))
        }
        .padding(Style.pad * 1.5)
        // The NAS box says whether the NAS answers now, not when last needed.
        .task { await model.checkNAS() }
    }
}

/// The bar for the photo going up now; nothing when none is.
struct SendBar: View {
    @ObservedObject var meter: SendMeter

    var body: some View {
        if meter.name != nil {
            ProgressView(value: meter.fraction)
                .frame(width: 200)
        }
    }
}

struct SendingText: View {
    @ObservedObject var meter: SendMeter

    var body: some View {
        Text("Sending \(Int((meter.fraction * 100).rounded()))%").monospacedDigit().lineLimit(1)
    }
}

struct NASCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "NAS") {
            Grid(alignment: .leading, horizontalSpacing: Style.gap, verticalSpacing: Style.gap) {
                GridRow {
                    Text("Address").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                    TextField("", text: $model.nasAddress)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Backup address").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                    TextField("", text: $model.nasBackupAddress)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("User name").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                    TextField("", text: $model.nasUser)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Password").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                    SecureField("", text: $model.nasPassword)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Style.gap) {
                Button {
                    Task { await model.saveNAS() }
                } label: {
                    Text("Save").buttonLabel()
                }
                // Greyed out until a field changes.
                .disabled(!model.nasUnsaved)
                Button {
                    Task { await model.testNAS() }
                } label: {
                    Text("Test connection").buttonLabel()
                }
                StatusLine(text: model.nasLine, lines: 2, busy: model.nasBusy)
            }
            .disabled(model.nasBusy)
        }
    }
}

/// The Queue page and the NAS card on their own, for pictures made off-screen.
public struct QueueScreenProbe: View {
    public init() {}
    public var body: some View { QueueScreen() }
}

public struct NASCardProbe: View {
    public init() {}
    public var body: some View {
        NASCard()
            .padding(Style.pad * 1.5)
            .frame(width: 720)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
