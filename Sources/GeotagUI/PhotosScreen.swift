import AppKit
import QuickLook
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

    /// "The Canon EOS R7's clock is 520 d 20 h 5 min behind. Set it in the
    /// camera: Set time and date in camera, in the menu bar."
    static func clockNote(_ wrong: [(camera: Camera, offset: Int)]) -> String {
        guard !wrong.isEmpty else { return "" }
        let each = wrong.map { "The \($0.camera.model)'s clock is \(OffsetText.describe($0.offset))." }
        return each.joined(separator: " ") + " Set it in the camera: Set time and date in camera, in the menu bar."
    }

    /// "1 h 25 min", "45 min", "2 d 3 h": a break between two photos.
    static func gap(_ seconds: Int) -> String {
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        if days > 0 { return hours % 24 == 0 ? "\(days) d" : "\(days) d \(hours % 24) h" }
        if hours > 0 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        return "\(minutes) min"
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
    @State private var selection = Set<ImportRow.ID>()
    /// The photo shown big, as Finder's space bar shows it.
    @State private var previewing: URL?
    @State private var naming = false

    /// The columns the Columns button can show or hide, in table order.
    static let toggleable: [(id: String, title: String)] = [
        ("preview", "Preview"), ("name", "Name"), ("status", "Status"), ("place", "Place"), ("gap", "Gap"),
        ("taken", "Date and time"), ("camera", "Camera model"), ("size", "Size"),
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
                // Clickable whatever is missing: the line below says what, and how to fix it.
                Button {
                    model.openMap()
                } label: {
                    Text("See photos on the map").buttonLabel()
                }
                .disabled(model.photosBusy || model.saving)
                Button {
                    if selection.isEmpty {
                        model.tell("Select photos in the list first.")
                    } else {
                        naming = true
                    }
                } label: {
                    Text("Name place…").buttonLabel()
                }
                .disabled(model.saving)
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
                    .disabled(model.photosBusy)
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
                // Nothing else to say: a camera whose clock is far out, and where to set it.
                StatusLine(text: model.photosLine.isEmpty ? PhotoText.clockNote(model.wrongClocks) : model.photosLine, lines: 2,
                           busy: model.photosBusy,
                           progress: model.saving ? Double(model.saveDone) / Double(max(model.saveTotal, 1)) : nil)
                if let fix = model.photosFix {
                    Button {
                        model.take(fix)
                    } label: {
                        Text(fix.title).buttonLabel()
                    }
                    .fixedSize()
                }
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

            Table(shown, selection: $selection, columnCustomization: $columns) {
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
                    PhotoStatus(model: model, row: row)
                }
                .width(min: 150, ideal: 240)
                .customizationID("status")
                // The place its folder is named after: typed, else OpenStreetMap's.
                TableColumn("Place") { row in
                    if let name = model.placeName(row) {
                        Text(name).lineLimit(1)
                    } else if model.placesSettled {
                        Text("No place").foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .width(min: 90, ideal: 140)
                .customizationID("place")
                // A long break before this photo: often a new place.
                TableColumn("Gap") { row in
                    if let seconds = model.breaks[row.id] {
                        Text(PhotoText.gap(seconds)).monospacedDigit().lineLimit(1)
                    }
                }
                .width(min: 60, ideal: 80)
                .customizationID("gap")
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
            // The space bar shows the selected photo big, as Finder does; again closes it.
            .onKeyPress(.space) {
                if previewing != nil {
                    previewing = nil
                    return .handled
                }
                guard let row = shown.first(where: { selection.contains($0.id) }) else { return .ignored }
                previewing = row.photo.url
                return .handled
            }
            .onChange(of: selection) { _, now in
                if previewing != nil, let row = shown.first(where: { now.contains($0.id) }) { previewing = row.photo.url }
            }
            .quickLookPreview($previewing, in: shown.map(\.photo.url))
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
        .sheet(isPresented: $naming) {
            NamePlace(ids: selection, current: commonPlace)
        }
        .onChange(of: model.rows.map(\.id)) { _, now in
            // A new card: nothing of the last one stays chosen.
            selection.formIntersection(now)
        }
    }

    /// The place every selected photo has, to start the name from; empty when they differ.
    private var commonPlace: String {
        let names = Set(model.rows.filter { selection.contains($0.id) }.map { model.placeName($0) ?? "" })
        return names.count == 1 ? names.first ?? "" : ""
    }
}

/// "Name place…": the name of the place the selected photos were taken, for
/// their folder. Empty gives them OpenStreetMap's name back.
struct NamePlace: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let ids: Set<ImportRow.ID>
    @State private var name: String

    init(ids: Set<ImportRow.ID>, current: String) {
        self.ids = ids
        _name = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            Text("Name place").font(.headline).lineLimit(1)
            HStack(spacing: Style.gap) {
                Text("Place").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                TextField("", text: $name).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Cancel").buttonLabel()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    model.givePlace(name, to: ids)
                    dismiss()
                } label: {
                    Text("Save").buttonLabel()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Style.pad * 1.5)
        .frame(width: 460)
    }
}

/// What happened to a photo: before saving, its location or why it has none;
/// once saved, where it stands with the NAS, and why it has no location when
/// it has none. The model is handed in, never looked up: a table cell can be
/// drawn where the window's own objects are not reachable, and Geotag crashed
/// that way on a card of 3,630 photos (18 October 2026).
struct PhotoStatus: View {
    @ObservedObject var model: AppModel
    let row: ImportRow

    var body: some View {
        if let result = model.results[row.id] {
            if let url = result.url, let entry = model.queueEntry(for: url.path), entry.state == .sending {
                SendingText(meter: model.meter, id: entry.id)
                    .foregroundStyle(.secondary)
            } else if let url = result.url, let entry = model.queueEntry(for: url.path) {
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
        // Last time's owner, else whose Mac this is, is the one Return picks.
        let last = model.lastPerson(for: source) ?? model.macOwner
        VStack(alignment: .leading, spacing: Style.gap) {
            Text("Whose is \(source.name)?").font(.headline).lineLimit(1)
            HStack(spacing: 8) {
                ForEach(model.peopleOwnerFirst) { person in
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
            if model.historyPerson == nil { model.showHistory(model.peopleOwnerFirst.first?.id) }
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
            Stepper(value: Binding(get: { model.clockFixMinutes }, set: { model.setClockFixMinutes($0) }), in: 15...10_080, step: 15) {
                Text("Correct the dates when a clock is out by \(PhotoText.gap(model.clockFixMinutes * 60)) or more").lineLimit(1)
            }
            .fixedSize()
        }
    }
}

/// The Photos list's own setting: how long a break between two photos is
/// marked in its Gap column.
struct PhotosListCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "Photos") {
            Stepper(value: Binding(get: { model.breakMinutes }, set: { model.setBreakMinutes($0) }), in: 1...600) {
                Text("Mark gaps longer than: \(PhotoText.gap(model.breakMinutes * 60))").lineLimit(1)
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

/// The Photos page's wording, for the self-test.
public enum PhotoTextProbe {
    public static func gap(_ seconds: Int) -> String { PhotoText.gap(seconds) }
    public static func clockNote(_ wrong: [(camera: Camera, offset: Int)]) -> String { PhotoText.clockNote(wrong) }
}

/// The Photos screen on its own, for pictures made off-screen.
public struct PhotosScreenProbe: View {
    public init() {}
    public var body: some View { PhotosScreen() }
}

/// The sheets and the long Settings page on their own, for pictures made off-screen.
public struct SheetProbe: View {
    public enum Kind: String, CaseIterable, Sendable {
        case whose, person, camera, settings, sidebar, namePlace, lens
        case setupOwner, setupFolders, setupService, setupNAS, setupCards
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
            case .namePlace:
                NamePlace(ids: [], current: "Port Lockroy")
            case .lens:
                LensEditor(lens: model.book.lenses.first
                           ?? Lens(model: "RF600mm F4 L IS USM", serial: nil, personId: UUID(), camera: "Canon EOS R5m2", seen: nil)) { _ in }
            case .setupOwner: SetupView(at: .owner)
            case .setupFolders: SetupView(at: .folders)
            case .setupService: SetupView(at: .service)
            case .setupNAS: SetupView(at: .nas)
            case .setupCards: SetupView(at: .cards)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
