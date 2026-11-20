#if os(macOS)
import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import SqueakyCore


/// A row of the Photos table with what each column is ordered by.
struct PhotoLine: Identifiable {
    let row: ImportRow
    /// 0 not saved, 1 saved: ascending puts the photos still to save first.
    let saved: Int
    let name: String
    let status: String
    let place: String
    let gap: Int
    let taken: Date
    let camera: String
    let size: Int64
    var id: String { row.id }
}

struct PhotosScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var reviewOnly = false
    @State private var columns = TableColumnCustomization<PhotoLine>()
    @State private var order: [KeyPathComparator<PhotoLine>] = []
    /// The column the photos are ordered by, and which way; newest first to start.
    @AppStorage("photoSort") private var sortId = "taken"
    @AppStorage("photoSortAscending") private var sortAscending = false
    /// Photos saved from an earlier card hidden; those saved this time stay.
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

    static let sorts = SortColumns<PhotoLine>(all: [
        ("done", KeyPathComparator(\PhotoLine.saved)), ("name", KeyPathComparator(\PhotoLine.name)),
        ("status", KeyPathComparator(\PhotoLine.status)), ("place", KeyPathComparator(\PhotoLine.place)),
        ("gap", KeyPathComparator(\PhotoLine.gap)), ("taken", KeyPathComparator(\PhotoLine.taken)),
        ("camera", KeyPathComparator(\PhotoLine.camera)), ("size", KeyPathComparator(\PhotoLine.size)),
    ])

    /// What the Status column says, to order by.
    private func statusText(_ row: ImportRow) -> String {
        if let result = model.results[row.id] {
            if let url = result.url, let entry = model.queueEntry(for: url.path) { return QueueText.photo(entry) }
            switch result {
            case .saved: return "Saved"
            case .alreadyThere: return "Already saved"
            case .failed(let why): return "Not saved: \(why)"
            }
        }
        return row.status == .alreadyImported ? PhotoText.status(row.status) : PhotoText.location(row, gap: model.maxGapSeconds)
    }

    private var shown: [PhotoLine] {
        var rows = reviewOnly ? model.rows.filter(withoutLocation) : model.rows
        // "Hide already saved", shared with the phone's rule (0.34.4, David).
        if model.hideSaved { rows.removeAll { model.isSaved($0) } }
        let lines = rows.map { row in
            PhotoLine(row: row, saved: model.isSaved(row) ? 1 : 0, name: row.photo.fileName, status: statusText(row),
                      place: model.placeName(row) ?? "", gap: model.breaks[row.id] ?? 0,
                      taken: Moments.clockReading(row.photo) ?? .distantPast, camera: row.photo.model ?? "Unknown",
                      size: row.photo.size)
        }
        return order.isEmpty ? lines : lines.sorted(using: order)
    }

    private var sortedBy: String? { Self.sorts.id(of: order) }

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
                // The sync line beside the title, the buttons at the right (0.29.4, David, 16 November 2026).
                StatusLine(text: model.syncActivity ?? QueueText.sync(model.lastSave, problem: model.sharedProblem), lines: 1)
                Spacer(minLength: Style.gap)
                // A button that can't do anything now is dimmed (David, 6 November 2026).
                Button {
                    model.openMap()
                } label: {
                    Text("See photos on the map").buttonLabel()
                }
                .disabled(model.photosBusy || model.saving || !model.canMap)
                Button {
                    naming = true
                } label: {
                    Text("Name place…").buttonLabel()
                }
                .disabled(model.saving || selection.isEmpty || model.source == nil)
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
                        Text("Save").buttonLabel()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
                    // Every photo on the card, the saved ones too when asked (0.33.0, as the phone).
                    Button {
                        model.saveAll()
                    } label: {
                        Text("Save all").buttonLabel()
                    }
                    .disabled(model.source == nil || model.rows.isEmpty || model.photosBusy || model.importPerson == nil)
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
                        .disabled(model.ejecting != nil)
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
                           busy: model.photosBusy || model.ejecting != nil,
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
                    Toggle("Hide already saved", isOn: $model.hideSaved)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                    if model.source == nil {
                        Button {
                            selection = []
                            model.clearPhotos()
                        } label: {
                            Text("Clear").buttonLabel()
                        }
                        .fixedSize()
                        .disabled(model.saving)
                    }
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

            let by = sortedBy
            Table(shown, selection: $selection, sortOrder: $order, columnCustomization: $columns) {
                TableColumn(Text("").sortHeading(by == "done"), value: \PhotoLine.saved) { line in
                    // A checkmark once the photo is saved, now or on an earlier card.
                    Group {
                        if line.saved == 1 {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Saved")
                        }
                    }
                    .sortTint(by == "done")
                }
                .width(24)
                .customizationID("done")
                .disabledCustomizationBehavior(.visibility)
                TableColumn("") { line in
                    if let url = model.pictureURL(line.row) { PhotoPreview(url: url, duration: line.row.photo.duration) }
                }
                .width(56)
                .customizationID("preview")
                TableColumn(Text("Name").sortHeading(by == "name"), value: \PhotoLine.name) { line in
                    Text(line.name).lineLimit(1).sortTint(by == "name")
                }
                .width(min: 100, ideal: 120)
                .customizationID("name")
                // Next to the name, so it shows even in the smallest window.
                TableColumn(Text("Status").sortHeading(by == "status"), value: \PhotoLine.status) { line in
                    PhotoStatus(model: model, row: line.row).sortTint(by == "status")
                }
                .width(min: 150, ideal: 240)
                .customizationID("status")
                // The place its folder is named after: typed, else OpenStreetMap's.
                TableColumn(Text("Place").sortHeading(by == "place"), value: \PhotoLine.place) { line in
                    Group {
                        if !line.place.isEmpty {
                            Text(line.place).lineLimit(1)
                        } else if model.placesSettled {
                            Text("No place").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .sortTint(by == "place")
                }
                .width(min: 90, ideal: 140)
                .customizationID("place")
                // A long break before this photo: often a new place.
                TableColumn(Text("Gap").sortHeading(by == "gap"), value: \PhotoLine.gap) { line in
                    Group {
                        if line.gap > 0 {
                            Text(PhotoText.gap(line.gap)).monospacedDigit().lineLimit(1)
                        }
                    }
                    .sortTint(by == "gap")
                }
                .width(min: 60, ideal: 80)
                .customizationID("gap")
                TableColumn(Text("Date and time").sortHeading(by == "taken"), value: \PhotoLine.taken) { line in
                    Text(PhotoText.taken(line.row.photo)).monospacedDigit().lineLimit(1).sortTint(by == "taken")
                }
                .width(min: 170, ideal: 200)
                .customizationID("taken")
                TableColumn(Text("Camera model").sortHeading(by == "camera"), value: \PhotoLine.camera) { line in
                    Text(line.camera).lineLimit(1).sortTint(by == "camera")
                }
                .width(min: 100, ideal: 130)
                .customizationID("camera")
                TableColumn(Text("Size").sortHeading(by == "size"), value: \PhotoLine.size) { line in
                    Text(PhotoText.size(line.size)).monospacedDigit().lineLimit(1).sortTint(by == "size")
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
                guard let line = shown.first(where: { selection.contains($0.id) }), let url = model.pictureURL(line.row) else { return .ignored }
                previewing = url
                return .handled
            }
            .onChange(of: selection) { _, now in
                if previewing != nil, let line = shown.first(where: { now.contains($0.id) }) { previewing = model.pictureURL(line.row) }
            }
            .quickLookPreview($previewing, in: shown.compactMap { model.pictureURL($0.row) })
            // A video plays in Quick Look; a RAW video cannot (0.33.0).
            .contextMenu(forSelectionType: String.self) { ids in
                if let line = shown.first(where: { ids.contains($0.id) }), line.row.photo.isVideo,
                   !PhotoKinds.isRawVideo(line.row.photo.url), let url = model.pictureURL(line.row) {
                    Button("Play") { previewing = url }
                }
            }
        }
        .padding(Style.pad * 1.5)
        .onAppear {
            if let saved = try? JSONDecoder().decode(TableColumnCustomization<PhotoLine>.self, from: savedColumns) { columns = saved }
            order = Self.sorts.order(sortId, ascending: sortAscending)
        }
        .onChange(of: order) { _, now in
            // The latest choice is the order next time, through restarts.
            guard let id = Self.sorts.id(of: now), let first = now.first else { return }
            sortId = id
            sortAscending = first.order == .forward
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
/// drawn where the window's own objects are not reachable, and Squeaky crashed
/// that way on a card of 3,630 photos (18 October 2026).
struct PhotoStatus: View {
    @ObservedObject var model: AppModel
    let row: ImportRow

    var body: some View {
        if let result = model.results[row.id] {
            if let url = result.url, let entry = model.queueEntry(for: url.path), entry.state == .sending {
                SendingCell(meter: model.meter, id: entry.id)
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
    var duration: Double?
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor))
            // A RAW video: purple with a broken video, as on the phone (0.33.1).
            if PhotoKinds.isRawVideo(url) {
                RoundedRectangle(cornerRadius: 4).fill(Color.purple)
                Image(systemName: "video.slash.fill").font(.system(size: 13)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // A video's length, bottom left, as on the phone (0.33.0).
            if PhotoKinds.isVideo(url), let duration {
                Text(MovieFrames.length(duration))
                    .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 1)
                    .padding(.leading, 2).padding(.bottom, 1)
            }
        }
        .frame(width: 48, height: 32)
        .task(id: url) {
            if PhotoKinds.isRawVideo(url) { return }
            if PhotoKinds.isVideo(url) {
                let u = url
                image = await Task.detached { MovieFrames.picture(u, maxPixel: 96) }.value.map { NSImage(cgImage: $0, size: .zero) }
                return
            }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 48, height: 32),
                                                       scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

struct HistoryScreen: View {
    @EnvironmentObject var model: AppModel
    /// Empty until a heading is clicked: the usual order. Not kept between launches.
    @State private var order: [KeyPathComparator<HistoryRow>] = []

    static let sorts = SortColumns<HistoryRow>(all: [
        ("name", KeyPathComparator(\HistoryRow.name)), ("taken", KeyPathComparator(\HistoryRow.taken)),
        ("size", KeyPathComparator(\HistoryRow.size)), ("imported", KeyPathComparator(\HistoryRow.imported)),
    ])

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
            let rows = model.historyEntries.indices.map { HistoryRow(index: $0, entry: model.historyEntries[$0]) }
            let by = Self.sorts.id(of: order)
            Table(order.isEmpty ? rows : rows.sorted(using: order), sortOrder: $order) {
                TableColumn(Text("Name").sortHeading(by == "name"), value: \HistoryRow.name) { row in
                    Text(row.name).lineLimit(1).sortTint(by == "name")
                }
                .width(min: 120, ideal: 170)
                TableColumn(Text("Date and time").sortHeading(by == "taken"), value: \HistoryRow.taken) { row in
                    Text(PhotoText.taken(raw: row.entry.taken, zone: nil)).monospacedDigit().lineLimit(1).sortTint(by == "taken")
                }
                .width(min: 160, ideal: 210)
                TableColumn(Text("Size").sortHeading(by == "size"), value: \HistoryRow.size) { row in
                    Text(PhotoText.size(row.size)).monospacedDigit().lineLimit(1).sortTint(by == "size")
                }
                .width(min: 60, ideal: 80)
                TableColumn(Text("Imported").sortHeading(by == "imported"), value: \HistoryRow.imported) { row in
                    Text(When.current.dayAndTime(row.imported)).lineLimit(1).sortTint(by == "imported")
                }
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
    var name: String { entry.fileName }
    /// The camera's "YYYY:MM:DD HH:MM:SS", which sorts as written.
    var taken: String { (entry.taken ?? "") + (entry.subSeconds ?? "") }
    var size: Int64 { entry.size }
    var imported: Date { entry.imported }
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
            Toggle("Open Squeaky when a card is inserted", isOn: Binding(get: { model.openOnCard }, set: { model.setOpenOnCard($0) }))
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

#endif
