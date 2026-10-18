import AppKit
import QuickLookThumbnailing
import SwiftUI
import GeotagCore

enum PhotoText {
    /// The camera's own clock reading, shown as it was, with its zone.
    static func taken(_ photo: ScannedPhoto) -> String {
        taken(raw: photo.taken, zone: photo.zone)
    }

    /// "2026:10:16 12:00:00" as the camera writes it, in the format chosen in Settings.
    static func taken(raw: String?, zone: String?) -> String {
        guard let raw else { return "No time" }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return raw }
        return When.current.dayAndTime(date, zone: TimeZone(secondsFromGMT: 0)!, seconds: true) + (zone.map { " (\($0))" } ?? "")
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func location(_ row: ImportRow, gap: Int) -> String {
        guard let placement = row.placement else { return "" }
        switch placement {
        case .matched(let p): return p.fromPoint == 0 ? "Location matched" : "Location matched, \(p.fromPoint) s from the track"
        case .ownLocation: return "Own location"
        case .review(let reason):
            switch reason {
            case .noTrack: return "No track within \(gap / 60) min"
            case .offsetNotSet: return "Camera time offset not set"
            case .zoneNotSet: return "Camera time zone not set"
            case .noZoneInPhoto: return "No time zone in the photo"
            case .noTime: return "No time in the photo"
            case .unknownCamera: return "Camera not registered"
            }
        }
    }

    static func status(_ status: ImportStatus) -> String {
        switch status {
        case .new: return "New"
        case .alreadyImported: return "Already imported"
        case .unknownCamera: return "Camera not registered"
        }
    }
}

struct PhotosScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var reviewOnly = false
    @State private var columns = TableColumnCustomization<ImportRow>()
    @AppStorage("photoColumns") private var savedColumns = Data()

    /// The columns the Columns button can show or hide, in table order.
    static let toggleable: [(id: String, title: String)] = [
        ("preview", "Preview"), ("name", "Name"), ("status", "Status"), ("taken", "Date and time"),
        ("camera", "Camera model"), ("size", "Size"),
    ]

    private func shows(_ id: String) -> Binding<Bool> {
        Binding(
            get: { columns[visibility: id] != .hidden },
            set: { columns[visibility: id] = $0 ? .visible : .hidden }
        )
    }

    /// To be saved without a location, or saved now without one.
    private func withoutLocation(_ row: ImportRow) -> Bool {
        row.needsReview && (row.ticked || model.results[row.id]?.url != nil)
    }

    private var shown: [ImportRow] {
        reviewOnly ? model.rows.filter(withoutLocation) : model.rows
    }

    private var counts: (photos: Int, fresh: Int, before: Int, review: Int) {
        let rows = model.rows
        let fresh = rows.filter { $0.status != .alreadyImported }.count
        let review = rows.filter(withoutLocation).count
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
                .disabled(model.photosBusy || model.saving || model.alignable.isEmpty)
                if model.saving {
                    Button {
                        model.stopSaving()
                    } label: {
                        Text("Stop").buttonLabel()
                    }
                } else {
                    Button {
                        Task { await model.savePhotos() }
                    } label: {
                        Text("Save photos").buttonLabel()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.photosBusy || model.readyToSave.isEmpty)
                }
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
                Tile(label: "Already imported", value: ready ? c.before.formatted() : "0")
                Tile(label: "Without location", value: ready ? c.review.formatted() : "0")
            }

            HStack(spacing: 8) {
                if model.saving {
                    ProgressView(value: Double(model.saveDone), total: Double(max(model.saveTotal, 1)))
                        .frame(width: 200)
                } else if model.photosBusy {
                    ProgressView().controlSize(.small)
                }
                StatusLine(text: model.photosLine, lines: 2)
                Spacer()
                Menu {
                    ForEach(Self.toggleable, id: \.id) { column in
                        Toggle(column.title, isOn: shows(column.id))
                    }
                } label: {
                    Text("Columns").buttonLabel()
                }
                .menuStyle(.button)
                .fixedSize()
                .handCursor()
                if !model.rows.isEmpty {
                    Picker("", selection: $reviewOnly) {
                        Text("All").tag(false)
                        Text("Without location (\(c.review))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .frame(minHeight: 40)

            Table(shown, columnCustomization: $columns) {
                TableColumn("") { row in
                    // A checkmark once the photo is saved, now or on an earlier card.
                    if model.isSaved(row) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Saved")
                    }
                }
                .width(24)
                .customizationID("done")
                .disabledCustomizationBehavior(.visibility)
                TableColumn("") { row in
                    PhotoPreview(url: row.photo.url)
                }
                .width(56)
                .customizationID("preview")
                TableColumn("Name") { row in
                    Text(row.photo.fileName).lineLimit(1)
                }
                .width(min: 100, ideal: 120)
                .customizationID("name")
                // Next to the name, so it shows even in the smallest window.
                TableColumn("Status") { row in
                    PhotoStatus(row: row)
                }
                .width(min: 150, ideal: 240)
                .customizationID("status")
                TableColumn("Date and time") { row in
                    Text(PhotoText.taken(row.photo)).monospacedDigit().lineLimit(1)
                }
                .width(min: 170, ideal: 200)
                .customizationID("taken")
                TableColumn("Camera model") { row in
                    Text(row.photo.model ?? "Unknown").lineLimit(1)
                }
                .width(min: 100, ideal: 130)
                .customizationID("camera")
                TableColumn("Size") { row in
                    Text(PhotoText.size(row.photo.size)).monospacedDigit().lineLimit(1)
                }
                .width(min: 60, ideal: 70)
                .customizationID("size")
            }
            .clipShape(RoundedRectangle(cornerRadius: Style.radius))
        }
        .padding(Style.pad * 1.5)
        .onAppear {
            if let saved = try? JSONDecoder().decode(TableColumnCustomization<ImportRow>.self, from: savedColumns) { columns = saved }
        }
        .onChange(of: columns) { _, now in
            if let data = try? JSONEncoder().encode(now) { savedColumns = data }
        }
        .sheet(item: $model.askingWhose) { source in
            WhoseCard(source: source)
                .textSelection(.enabled)
        }
        .sheet(isPresented: $model.aligning) {
            AlignmentView()
                .textSelection(.enabled)
        }
    }
}

/// What happened to a photo: before saving, its location or why it has none;
/// once saved, where it stands with the NAS, and why it has no location when
/// it has none.
struct PhotoStatus: View {
    @EnvironmentObject var model: AppModel
    let row: ImportRow

    var body: some View {
        if let result = model.results[row.id] {
            if let url = result.url, let entry = model.queueEntry(for: url.path) {
                let why = row.needsReview ? " · " + PhotoText.location(row, gap: model.maxGapSeconds) : ""
                Text(QueueText.photo(entry) + why)
                    .foregroundStyle(entry.state == .sent && why.isEmpty ? .primary : .secondary)
                    .lineLimit(1)
            } else {
                switch result {
                case .saved: Text("Saved").lineLimit(1)
                case .alreadyThere: Text("Already saved").foregroundStyle(.secondary).lineLimit(1)
                case .failed(let why): Text("Not saved: \(why)").foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } else {
            let before = row.status == .alreadyImported
            Text(before ? PhotoText.status(row.status) : PhotoText.location(row, gap: model.maxGapSeconds))
                .foregroundStyle(before || row.needsReview ? .secondary : .primary)
                .lineLimit(1)
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
                    .minimumScaleFactor(0.75)
                Text(value)
                    .font(.title2.monospacedDigit())
                    .lineLimit(1)
                    // A long card name gets smaller before it is cut short.
                    .minimumScaleFactor(0.6)
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
        .handCursor()
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
                    .width(min: 120, ideal: 170)
                TableColumn("Date and time") { row in
                    Text(PhotoText.taken(raw: row.entry.taken, zone: nil)).monospacedDigit().lineLimit(1)
                }
                .width(min: 160, ideal: 210)
                TableColumn("Size") { Text(PhotoText.size($0.entry.size)).monospacedDigit().lineLimit(1) }
                    .width(min: 60, ideal: 80)
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
            if !model.cardsLine.isEmpty {
                StatusLine(text: model.cardsLine)
            }
        }
    }
}

/// The Photos screen on its own, for pictures made off-screen.
public struct PhotosScreenProbe: View {
    public init() {}
    public var body: some View { PhotosScreen() }
}

/// The sheets and the long Settings page on their own, for pictures made off-screen.
public struct SheetProbe: View {
    public enum Kind: String, CaseIterable, Sendable {
        case whose, person, camera, settings, sidebar
    }

    @EnvironmentObject var model: AppModel
    let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public var body: some View {
        Group {
            switch kind {
            case .whose:
                WhoseCard(source: model.source ?? PhotoSource(id: "probe", name: "EOS_DIGITAL", url: URL(fileURLWithPath: "/"), isCard: true))
            case .person:
                PersonEditor(person: model.book.people[0]) { _ in }
            case .camera:
                CameraEditor(camera: model.book.cameras[0], people: model.book.people) { _ in }
            case .settings:
                SettingsScreen()
            case .sidebar:
                // Drawn on its own: off-screen, the window's sidebar shows blank.
                Sidebar().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
