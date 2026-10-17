import AppKit
import QuickLookThumbnailing
import SwiftUI
import GeotagCore

enum PhotoText {
    /// The camera's own clock reading, shown as it was, with its zone.
    static func taken(_ photo: ScannedPhoto) -> String {
        guard let raw = photo.taken else { return "No time" }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return raw }
        return When.current.dayAndTime(date, zone: TimeZone(secondsFromGMT: 0)!, seconds: true) + (photo.zone.map { " (\($0))" } ?? "")
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func location(_ row: ImportRow, gap: Int) -> String {
        guard let placement = row.placement else { return "" }
        switch placement {
        case .matched(let p): return p.fromPoint == 0 ? "Matched" : "Matched, \(p.fromPoint) s from the track"
        case .ownLocation: return "Own location"
        case .review(let reason):
            switch reason {
            case .noTrack: return "No track within \(gap / 60) min"
            case .offsetNotSet: return "Camera offset not set"
            case .zoneNotSet: return "Camera time zone not set"
            case .noZoneInPhoto: return "No time zone in the photo"
            case .noTime: return "No time in the photo"
            case .unknownCamera: return "Camera not on the list"
            }
        }
    }

    static func status(_ status: ImportStatus) -> String {
        switch status {
        case .new: return "New"
        case .alreadyImported: return "Imported before"
        case .unknownCamera: return "Camera not on the list"
        }
    }
}

struct PhotosScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var reviewOnly = false

    private var shown: [ImportRow] {
        reviewOnly ? model.rows.filter { $0.ticked && $0.needsReview } : model.rows
    }

    private var counts: (photos: Int, fresh: Int, before: Int, review: Int) {
        let rows = model.rows
        let fresh = rows.filter { $0.status != .alreadyImported }.count
        let review = rows.filter { $0.ticked && $0.needsReview && !$0.withoutLocation }.count
        return (rows.count, fresh, rows.count - fresh, review)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            HStack(spacing: Style.gap) {
                ScreenTitle(text: "Photos")
                Button {
                    model.aligning = true
                } label: {
                    Text("See photos on the map").buttonLabel()
                }
                .disabled(model.photosBusy || model.alignable.isEmpty)
            }

            if model.cards.count > 1 {
                HStack(spacing: 8) {
                    ForEach(model.cards) { card in
                        SourceButton(source: card, selected: model.source?.id == card.id) {
                            model.choose(card)
                        }
                        .disabled(model.photosBusy)
                    }
                }
            }

            let c = counts
            let ready = model.source != nil && !model.rows.isEmpty
            HStack(spacing: Style.gap) {
                Tile(label: "Card", value: model.source?.name ?? "No card") {
                    if model.source?.bsd != nil {
                        Button {
                            model.eject()
                        } label: {
                            Text("Eject").buttonLabel()
                        }
                    }
                }
                Tile(label: "Person", value: model.importPerson.flatMap { model.book.person($0)?.name } ?? "Nobody yet") {
                    if let source = model.source {
                        RoundIconButton(symbol: "pencil", label: "Change") { model.askingWhose = source }
                            .disabled(model.photosBusy)
                    }
                }
                Tile(label: "Photos", value: ready ? c.photos.formatted() : "0")
                Tile(label: "New", value: ready ? c.fresh.formatted() : "0")
                Tile(label: "Imported before", value: ready ? c.before.formatted() : "0")
                Tile(label: "To review", value: ready ? c.review.formatted() : "0")
            }

            HStack(spacing: 8) {
                if model.photosBusy { ProgressView().controlSize(.small) }
                StatusLine(text: model.photosLine, lines: 2)
                Spacer()
                if !model.rows.isEmpty {
                    Picker("", selection: $reviewOnly) {
                        Text("All").tag(false)
                        Text("Review (\(c.review))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .frame(minHeight: 40)

            Table(shown) {
                TableColumn("") { row in
                    Toggle("", isOn: Binding(get: { row.ticked }, set: { model.setTicked(row.id, $0) }))
                        .labelsHidden()
                }
                .width(24)
                TableColumn("") { row in
                    PhotoPreview(url: row.photo.url)
                }
                .width(56)
                TableColumn("Name") { row in
                    Text(row.photo.fileName).lineLimit(1)
                }
                .width(min: 100, ideal: 120)
                TableColumn("Taken") { row in
                    Text(PhotoText.taken(row.photo)).monospacedDigit().lineLimit(1)
                }
                .width(min: 170, ideal: 200)
                TableColumn("Camera") { row in
                    Text(row.photo.model ?? "Unknown").lineLimit(1)
                }
                .width(min: 100, ideal: 130)
                TableColumn("Size") { row in
                    Text(PhotoText.size(row.photo.size)).monospacedDigit().lineLimit(1)
                }
                .width(min: 60, ideal: 70)
                TableColumn("Status") { row in
                    let before = row.status == .alreadyImported
                    Text(before ? PhotoText.status(row.status) : PhotoText.location(row, gap: model.maxGapSeconds))
                        .foregroundStyle(before || row.needsReview ? .secondary : .primary)
                        .lineLimit(1)
                }
                .width(min: 150, ideal: 190)
                TableColumn("Without location") { row in
                    if row.needsReview {
                        Toggle("", isOn: Binding(get: { row.withoutLocation }, set: { model.setWithoutLocation(row.id, $0) }))
                            .labelsHidden()
                    }
                }
                .width(110)
            }
            .clipShape(RoundedRectangle(cornerRadius: Style.radius))
        }
        .padding(Style.pad * 1.5)
        .sheet(item: $model.askingWhose) { source in
            WhoseCard(source: source)
        }
        .sheet(isPresented: $model.aligning) {
            AlignmentView()
        }
    }
}

/// A small label over a large figure, with room for a button beside it.
struct Tile<Accessory: View>: View {
    let label: String
    let value: String
    let accessory: Accessory

    init(label: String, value: String, @ViewBuilder accessory: () -> Accessory) {
        self.label = label
        self.value = value
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.title2.monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Style.radius).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Style.radius).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

extension Tile where Accessory == EmptyView {
    init(label: String, value: String) {
        self.init(label: label, value: value) { EmptyView() }
    }
}

struct SourceButton: View {
    let source: PhotoSource
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(source.name, systemImage: source.isCard ? "sdcard" : "folder")
                .lineLimit(1)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: Style.radius)
                        .fill(selected ? Color.accentColor.opacity(0.25) : Color(nsColor: .controlColor))
                )
                .overlay(RoundedRectangle(cornerRadius: Style.radius).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .buttonStyle(.plain)
    }
}

/// Whose card is this: one button per person, last time's owner first in line.
struct WhoseCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let source: PhotoSource

    var body: some View {
        let last = model.lastPerson(for: source)
        VStack(alignment: .leading, spacing: Style.gap) {
            Text("Whose is \(source.name)?").font(.headline).lineLimit(1)
            HStack(spacing: 8) {
                ForEach(model.book.people) { person in
                    if person.id == last {
                        Button {
                            pick(person.id)
                        } label: {
                            Text(person.name).buttonLabel()
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button {
                            pick(person.id)
                        } label: {
                            Text(person.name).buttonLabel()
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Cancel").buttonLabel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Style.pad * 1.5)
        .frame(minWidth: 420)
    }

    private func pick(_ id: UUID) {
        dismiss()
        Task { await model.read(source, for: id) }
    }
}

/// The photo's small preview, as Finder makes it.
struct PhotoPreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            }
        }
        .frame(width: 48, height: 32)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 48, height: 32),
                                                       scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

struct HistoryScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            HStack(spacing: Style.gap) {
                ScreenTitle(text: "History")
                Picker("", selection: Binding(get: { model.historyPerson }, set: { model.showHistory($0) })) {
                    ForEach(model.book.people) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Table(model.historyEntries.indices.map { HistoryRow(index: $0, entry: model.historyEntries[$0]) }) {
                TableColumn("Name") { Text($0.entry.fileName).lineLimit(1) }
                TableColumn("Taken") { row in
                    Text(row.entry.taken ?? "No time").monospacedDigit().lineLimit(1)
                }
                TableColumn("Size") { Text(PhotoText.size($0.entry.size)).monospacedDigit().lineLimit(1) }
                TableColumn("Imported") { Text(When.current.dayAndTime($0.entry.imported)).lineLimit(1) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Style.radius))
        }
        .padding(Style.pad * 1.5)
        .onAppear {
            if model.historyPerson == nil { model.showHistory(model.book.people.first?.id) }
        }
    }
}

struct HistoryRow: Identifiable {
    let index: Int
    let entry: HistoryEntry
    var id: Int { index }
}

struct DatesCard: View {
    @EnvironmentObject var model: AppModel

    /// Whether the Mac itself writes times on a 24-hour clock.
    private var macUses24: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }

    var body: some View {
        let today = Date()
        Card(title: "Dates and times") {
            Picker("Date order", selection: Binding(get: { model.dateOrder }, set: { model.setDateOrder($0) })) {
                ForEach(DateOrder.allCases) { order in
                    Text("\(order.title) (\(When(order: order, clock24: model.clock24).day(today)))").tag(order)
                }
            }
            .fixedSize()
            Toggle("24-hour clock", isOn: Binding(get: { model.clock24 ?? macUses24 }, set: { model.setClock24($0) }))
                .toggleStyle(.switch)
            Text(When.current.dayAndTime(today, weekday: true))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct MatchingCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "Matching") {
            Stepper(value: Binding(get: { model.maxGapSeconds / 60 }, set: { model.setMaxGap($0 * 60) }), in: 1...60) {
                Text("Maximum gap: \(model.maxGapSeconds / 60) min").lineLimit(1)
            }
            .fixedSize()
        }
    }
}

struct CardsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "Cards") {
            Toggle("Open Geotag when a card is inserted", isOn: Binding(get: { model.openOnCard }, set: { model.setOpenOnCard($0) }))
                .toggleStyle(.switch)
            StatusLine(text: model.cardsLine)
        }
    }
}

/// The Photos screen on its own, for pictures made off-screen.
public struct PhotosScreenProbe: View {
    public init() {}
    public var body: some View { PhotosScreen() }
}
