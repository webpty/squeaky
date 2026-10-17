import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GeotagCore

public enum Screen: String, CaseIterable, Identifiable {
    case photos
    case tracks
    case queue
    case history
    case settings

    public var id: String { rawValue }

    /// The sidebar's sections. Tracks is not one of them: it is a menu in the
    /// Mac's menu bar, out of the way while it works (David, 16 October 2026).
    public static let sidebar: [Screen] = [.photos, .queue, .history, .settings]

    public var title: String {
        switch self {
        case .tracks: return "Tracks"
        case .photos: return "Photos"
        case .queue: return "Queue"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .tracks: return "map"
        case .photos: return "photo.on.rectangle"
        case .queue: return "arrow.up.circle"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public var appearance = Appearance.system
    @Published public var screen = Screen.photos

    // Track service, as set in Settings.
    @Published public var serviceAddress = ""
    @Published public var serviceKey = ""
    @Published public private(set) var role: KeyRole?
    @Published public private(set) var serviceStatus: ServiceStatus?
    @Published public var settingsLine = ""
    @Published public private(set) var settingsBusy = false

    // Tracks.
    @Published public private(set) var tracks: [Track] = []
    @Published public var tracksLine = ""
    @Published public private(set) var tracksBusy = false
    /// The credit the small maps need, kept for when the Mac is offline.
    @Published public private(set) var mapCredit = ""
    /// Goes up whenever the map source changes, so missing maps are tried again.
    @Published public private(set) var mapsRound = 0
    /// The track open in the viewer, if one is.
    @Published public var viewing: String?

    // People and cameras.
    @Published public private(set) var book = PeopleBook()
    @Published public var peopleLine = ""

    // Photos: cards, whose they are, and what is on them.
    @Published public private(set) var cards: [PhotoSource] = []
    @Published public private(set) var source: PhotoSource?
    /// The card waiting for its owner to be chosen.
    @Published public var askingWhose: PhotoSource?
    @Published public private(set) var importPerson: UUID?
    @Published public private(set) var rows: [ImportRow] = []
    @Published public private(set) var photosBusy = false
    @Published public private(set) var photosLine = ""
    @Published public private(set) var openOnCard = true
    @Published public var cardsLine = ""

    // Dates and times, as chosen in Settings; until then, as the Mac.
    @Published public private(set) var dateOrder = DateOrder.system
    @Published public private(set) var clock24: Bool?

    // Matching.
    @Published public private(set) var maxGapSeconds = 120
    @Published public var aligning = false
    /// Every track's points, built once and again whenever the tracks change.
    public private(set) var timeline = TrackTimeline([])
    private var timelineIds: [String] = []

    // Saving.
    @Published public private(set) var saving = false
    @Published public private(set) var saveDone = 0
    @Published public private(set) var saveTotal = 0
    /// Each row's outcome, by row id, once saving has reached it.
    @Published public private(set) var results: [String: SaveResult] = [:]
    private var stopAsked = false

    // History.
    @Published public var historyPerson: UUID?
    @Published public private(set) var historyEntries: [HistoryEntry] = []

    public let library: TrackLibrary
    public let thumbnails: MapThumbnails
    private let peopleStore: PeopleStorePort
    private let history: HistoryStorePort
    private let queue: QueueStorePort
    private let exifTool: ExifTool?
    private let cardGuard = CardGuard()
    /// Bumped whenever reading should stop: a new card chosen, or an eject.
    private var readingRound = 0
    private var ejecting: String?
    private let secrets: SecretStorePort
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var awaitingStrava = false
    private var started = false

    static let keyAccount = "track-service-key"

    public init(library: TrackLibrary = TrackLibrary(store: TrackStoreFolder.standard()),
                peopleStore: PeopleStorePort = PeopleStoreFile.standard(),
                history: HistoryStorePort = HistoryStoreFolder.standard(),
                queue: QueueStorePort = QueueStoreFile.standard(),
                secrets: SecretStorePort = Keychain(),
                thumbnails: MapThumbnails? = nil,
                exifTool: ExifTool? = nil) {
        self.exifTool = exifTool ?? ExifTool.bundled()
        self.library = library
        self.thumbnails = thumbnails ?? MapThumbnails()
        self.peopleStore = peopleStore
        self.history = history
        self.queue = queue
        self.secrets = secrets
        openOnCard = defaults.object(forKey: "openOnCard") as? Bool ?? true
        if defaults.object(forKey: "maxGapSeconds") != nil { maxGapSeconds = defaults.integer(forKey: "maxGapSeconds") }
        dateOrder = defaults.string(forKey: "dateOrder").flatMap(DateOrder.init(rawValue:)) ?? .system
        clock24 = defaults.object(forKey: "clock24") as? Bool
        When.current = When(order: dateOrder, clock24: clock24)
        do {
            if let saved = try peopleStore.load() {
                book = saved
            } else {
                book = .family()
                try peopleStore.save(book)
            }
        } catch {
            peopleLine = "The people list could not be read: \(error.localizedDescription)"
        }
        if let raw = defaults.string(forKey: "appearance"), let mode = Appearance(rawValue: raw) {
            appearance = mode
        }
        serviceAddress = defaults.string(forKey: "trackServiceAddress") ?? ""
        role = defaults.string(forKey: "trackServiceRole").flatMap(KeyRole.init(rawValue:))
        serviceKey = secrets.read(Self.keyAccount) ?? ""
        mapCredit = defaults.string(forKey: "mapCredit") ?? ""

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cameBack() }
        }
    }

    public func setAppearance(_ mode: Appearance) {
        appearance = mode
        defaults.set(mode.rawValue, forKey: "appearance")
        applyAppearance()
    }

    /// Light, dark or the Mac's own, for every window. Set on the application
    /// itself: SwiftUI's colour scheme alone left the Mac's own colours behind.
    public func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// At launch: show what this Mac has, then ask the service, and again every ten minutes.
    public func start() async {
        // A window opened again runs this again; the rest is once per launch.
        guard !started else { return }
        started = true
        applyAppearance()
        startCards()
        tracks = await library.listed()
        await refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    var service: TrackServicePort? {
        TrackServiceHTTP(address: serviceAddress, key: serviceKey)
    }

    // MARK: Settings

    public func saveService() async {
        defaults.set(serviceAddress.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "trackServiceAddress")
        do {
            try secrets.write(Self.keyAccount, serviceKey.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            settingsLine = error.localizedDescription
            return
        }
        await testService()
        if role != nil { await refresh() }
    }

    public func testService() async {
        guard let service else {
            settingsLine = ServiceError.notSetUp.localizedDescription
            return
        }
        settingsBusy = true
        defer { settingsBusy = false }
        do {
            let status = try await service.status()
            serviceStatus = status
            role = status.role
            defaults.set(status.role.rawValue, forKey: "trackServiceRole")
            let who = status.role == .owner ? "Owner key" : "Reading key"
            settingsLine = "\(who). \(status.tracks) \(status.tracks == 1 ? "track" : "tracks") on the service."
        } catch {
            settingsLine = error.localizedDescription
        }
    }

    public func connectStrava() async {
        guard let service else {
            settingsLine = ServiceError.notSetUp.localizedDescription
            return
        }
        settingsBusy = true
        defer { settingsBusy = false }
        do {
            let url = try await service.connectLink()
            awaitingStrava = true
            NSWorkspace.shared.open(url)
            settingsLine = "Approve on Strava in the browser."
        } catch {
            settingsLine = error.localizedDescription
        }
    }

    public func disconnectStrava() async {
        guard let service else {
            settingsLine = ServiceError.notSetUp.localizedDescription
            return
        }
        settingsBusy = true
        defer { settingsBusy = false }
        do {
            settingsLine = try await service.disconnect()
            serviceStatus = try? await service.status()
        } catch {
            settingsLine = error.localizedDescription
        }
    }

    /// Back from the browser after approving on Strava: show the news.
    private func cameBack() {
        guard awaitingStrava else { return }
        Task {
            await testService()
            if serviceStatus?.strava.connected == true {
                awaitingStrava = false
                settingsLine = "Strava connected."
                await refresh()
            }
        }
    }

    // MARK: People and cameras

    private func store(_ change: (inout PeopleBook) -> Void) {
        var next = book
        change(&next)
        do {
            try peopleStore.save(next)
            book = next
            peopleLine = ""
        } catch {
            peopleLine = "Not saved: \(error.localizedDescription)"
        }
    }

    public func save(_ person: Person) { store { $0.save(person) } }
    public func remove(person id: UUID) { store { $0.remove(person: id) }; rematch() }
    public func save(_ camera: Camera) { store { $0.save(camera) }; rematch() }
    public func remove(camera id: UUID) { store { $0.remove(camera: id) }; rematch() }

    // MARK: Photos

    private func startCards() {
        cardGuard.onHeld = { [weak self] card in
            guard let self else { return }
            self.cards.removeAll { $0.bsd == card.bsd }
            self.cards.append(card)
            guard self.openOnCard else { return }
            Windows.bringForward()
            self.screen = .photos
            self.choose(card)
        }
        cardGuard.onGone = { [weak self] bsd in
            guard let self else { return }
            let gone = self.cards.first { $0.bsd == bsd }
            self.cards.removeAll { $0.bsd == bsd }
            if let source = self.source, source.bsd == bsd {
                self.readingRound += 1
                self.source = nil
                self.rows = []
                self.importPerson = nil
                if self.ejecting != bsd { self.photosLine = "\(gone?.name ?? "The card") was taken out." }
            }
        }
        cardGuard.onProblem = { [weak self] message in
            guard let self else { return }
            self.photosLine = message
            // A card went in and could not be held: show why, where it is said.
            if self.openOnCard {
                Windows.bringForward()
                self.screen = .photos
            }
        }
        cardGuard.start()
        // On by default: the first time, Geotag joins the Login Items.
        if defaults.object(forKey: "openOnCard") == nil { setOpenOnCard(true) }
    }

    public func setOpenOnCard(_ on: Bool) {
        do {
            try LoginItem.set(on)
            openOnCard = on
            defaults.set(on, forKey: "openOnCard")
            cardsLine = ""
        } catch {
            openOnCard = LoginItem.isOn
            cardsLine = "The Mac refused: \(error.localizedDescription)"
        }
    }

    /// A card picked: first, whose is it.
    // MARK: Saving

    /// The rows Save photos would save: ticked and placed, or let through.
    public var readyToSave: [ImportRow] { rows.filter(\.willImport) }

    /// Copies every ready photo into the person's folder with its location,
    /// one at a time, checking each; records them in History and puts them on
    /// the upload queue. Stop, or Eject, ends it after the current photo.
    public func savePhotos() async {
        guard !saving, let personId = importPerson, let person = book.person(personId), let source else { return }
        guard let folder = person.saveFolder, !folder.isEmpty else {
            photosLine = "\(person.name) has no save folder yet. Choose one in Settings."
            return
        }
        guard let tool = exifTool else {
            photosLine = "ExifTool is missing from Geotag."
            return
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            photosLine = "\(person.name)'s save folder can't be found: \(folder). If it is on a drive, plug the drive in."
            return
        }
        let todo = readyToSave
        guard !todo.isEmpty else { return }
        let saver = Saver(exifTool: tool, folder: URL(fileURLWithPath: folder, isDirectory: true))
        await Task.detached { saver.clearLeftovers() }.value
        let round = readingRound
        saving = true
        stopAsked = false
        saveDone = 0
        saveTotal = todo.count
        defer { saving = false }

        var past = (try? history.load(personId)) ?? []
        var known = Set(past.map(\.key))
        var waiting = (try? queue.load()) ?? []
        func remember(_ photo: ScannedPhoto) {
            guard !known.contains(photo.key) else { return }
            known.insert(photo.key)
            past.append(HistoryEntry(fileName: photo.fileName, size: photo.size, taken: photo.taken,
                                     subSeconds: photo.subSeconds, imported: Date()))
        }
        var savedCount = 0, failedCount = 0
        for row in todo {
            if stopAsked || readingRound != round || self.source?.id != source.id { break }
            photosLine = "Saving \(saveDone + 1) of \(saveTotal)"
            // A photo that cannot be placed is saved as it is, without a location.
            let item = SaveItem(photo: row.photo, placement: row.placement ?? .review(.noTrack), withoutLocation: row.needsReview)
            let result = await Task.detached { saver.save(item) }.value
            results[row.id] = result
            saveDone += 1
            switch result {
            case .saved(let url):
                savedCount += 1
                remember(row.photo)
                let relative = "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
                waiting.append(QueueEntry(personId: personId, localPath: url.path, relativePath: relative))
            case .alreadyThere:
                savedCount += 1
                remember(row.photo)
            case .failed(let why):
                failedCount += 1
                if why == Saver.diskFull {
                    try? history.save(personId, past)
                    try? queue.save(waiting)
                    stopAsked = true
                }
            }
            // Written after every photo, so a crash or a pulled card loses nothing.
            try? history.save(personId, past)
            try? queue.save(waiting)
        }

        // What was saved now counts as imported before.
        let seen = Set(past.map(\.key))
        for i in rows.indices where seen.contains(rows[i].photo.key) {
            rows[i].status = .alreadyImported
            rows[i].ticked = false
        }
        if historyPerson == personId { historyEntries = past }
        // Ejected or another card chosen meanwhile: that line stands.
        guard readingRound == round else { return }
        let stopped = saveDone < saveTotal
        var line = stopped ? "Stopped after \(saveDone) of \(saveTotal)." : "\(savedCount) saved."
        if stopped { line += " \(savedCount) saved." }
        let unplaced = todo.filter { $0.needsReview && results[$0.id]?.url != nil }.count
        if unplaced > 0 { line += " \(unplaced) of them without a location: see the Status column." }
        if failedCount > 0 { line += " \(failedCount) not saved: see the Status column." }
        if results.values.contains(.failed(Saver.diskFull)) { line = "Stopped: \(Saver.diskFull) \(savedCount) saved before that." }
        photosLine = line
    }

    public func stopSaving() {
        stopAsked = true
    }

    /// A card picked. One Geotag has seen before is read straight away for
    /// whoever it was last time (the pencil on the Person tile changes it);
    /// a new one asks whose it is first.
    public func choose(_ source: PhotoSource) {
        readingRound += 1
        self.source = source
        rows = []
        results = [:]
        photosLine = ""
        if let person = lastPerson(for: source) {
            askingWhose = nil
            Task { await read(source, for: person) }
        } else {
            askingWhose = source
        }
    }

    /// Stops reading, forces the card off now and says when it can come out.
    public func eject() {
        guard let card = source, let bsd = card.bsd else { return }
        readingRound += 1
        ejecting = bsd
        askingWhose = nil
        aligning = false
        rows = []
        photosLine = "Ejecting \(card.name)"
        cardGuard.eject(bsd) { [weak self] problem in
            guard let self else { return }
            self.ejecting = nil
            if let problem {
                self.photosLine = "\(card.name) was not ejected. \(problem)"
            } else {
                self.cards.removeAll { $0.bsd == bsd }
                if self.source?.bsd == bsd { self.source = nil; self.importPerson = nil }
                self.photosLine = "\(card.name) is ejected. You can take it out."
            }
        }
    }

    /// Whoever this card belonged to last time.
    public func lastPerson(for source: PhotoSource) -> UUID? {
        let saved = defaults.dictionary(forKey: "cardPeople") as? [String: String] ?? [:]
        return saved[source.id].flatMap(UUID.init(uuidString:)).flatMap { id in book.person(id) != nil ? id : nil }
    }

    public func read(_ source: PhotoSource, for personId: UUID) async {
        var saved = defaults.dictionary(forKey: "cardPeople") as? [String: String] ?? [:]
        saved[source.id] = personId.uuidString
        defaults.set(saved, forKey: "cardPeople")
        askingWhose = nil
        importPerson = personId
        guard let tool = exifTool else {
            photosLine = "ExifTool is missing from Geotag."
            return
        }
        readingRound += 1
        let round = readingRound
        photosBusy = true
        defer { photosBusy = false }
        photosLine = "Looking for photos"
        let url = source.url
        let files = await Task.detached { PhotoScanner.files(in: url) }.value
        let total = files.count
        photosLine = "Reading 0 of \(total)"
        do {
            let photos = try await Task.detached {
                try PhotoScanner(exifTool: tool).scan(files) { done in
                    Task { @MainActor [weak self] in
                        if self?.readingRound == round { self?.photosLine = "Reading \(done) of \(total)" }
                    }
                }
            }.value
            let past = (try? history.load(personId)) ?? []
            guard readingRound == round, self.source?.id == source.id else { return }
            rows = ImportList.rows(photos, history: past, book: book, personId: personId)
            await loadTimeline()
            rematch()
            photosLine = rows.isEmpty ? "No photos on \(source.name)." : ""
            if !alignable.isEmpty { aligning = true }
        } catch {
            if readingRound == round { photosLine = "The photos could not be read: \(error.localizedDescription)" }
        }
    }

    /// Saved now, or imported on an earlier card.
    public func isSaved(_ row: ImportRow) -> Bool {
        if let result = results[row.id] { return result.url != nil }
        return row.status == .alreadyImported
    }

    public func setWithoutLocation(_ id: String, _ on: Bool) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].withoutLocation = on
    }

    // MARK: Dates and times

    public func setDateOrder(_ order: DateOrder) {
        dateOrder = order
        defaults.set(order.rawValue, forKey: "dateOrder")
        When.current = When(order: dateOrder, clock24: clock24)
    }

    public func setClock24(_ on: Bool) {
        clock24 = on
        defaults.set(on, forKey: "clock24")
        When.current = When(order: dateOrder, clock24: clock24)
    }

    // MARK: Matching

    public func setMaxGap(_ seconds: Int) {
        maxGapSeconds = min(max(seconds, 60), 3600)
        defaults.set(maxGapSeconds, forKey: "maxGapSeconds")
        rematch()
    }

    /// The tracks' points, read again only when the tracks have changed.
    public func loadTimeline() async {
        let ids = tracks.map(\.id)
        guard ids != timelineIds else { return }
        var pieces: [(id: String, points: TrackPoints)] = []
        for id in ids {
            if let p = await library.points(id) { pieces.append((id, p)) }
        }
        timeline = TrackTimeline(pieces)
        timelineIds = ids
    }

    /// Every photo placed again: after a card is read, a camera changes, the
    /// gap changes, or new tracks arrive.
    public func rematch() {
        guard let personId = importPerson, !rows.isEmpty else { return }
        for i in rows.indices {
            let photo = rows[i].photo
            let camera = photo.model.flatMap { book.camera(personId: personId, model: $0) }
            rows[i].placement = Matcher.place(photo, camera: camera, timeline: timeline, gap: maxGapSeconds)
        }
    }

    /// Ticked photos whose camera is known and whose time can be read: the
    /// ones the alignment window can slide.
    public var alignable: [ImportRow] {
        guard let personId = importPerson else { return [] }
        return rows.filter { row in
            guard row.ticked, !row.photo.hasLocation, row.photo.taken != nil,
                  let model = row.photo.model, let camera = book.camera(personId: personId, model: model) else { return false }
            return camera.zone != .notSet
        }
    }

    // MARK: History

    public func showHistory(_ personId: UUID?) {
        historyPerson = personId
        historyEntries = personId.flatMap { try? history.load($0) } ?? []
    }

    // MARK: Tracks

    public func refresh(pullStrava: Bool = false) async {
        guard !tracksBusy else { return }
        guard let service else {
            tracks = await library.listed()
            tracksLine = ServiceError.notSetUp.localizedDescription
            return
        }
        tracksBusy = true
        defer { tracksBusy = false }
        if role == nil { await testService() }
        guard let role else {
            tracks = await library.listed()
            tracksLine = settingsLine
            return
        }
        await loadMaps(service)
        if thumbnails.forgetFailures() { mapsRound += 1 }
        let report = await library.refresh(service: service, role: role, pullStrava: pullStrava)
        tracks = await library.listed()
        tracksLine = report.line
        if !rows.isEmpty {
            await loadTimeline()
            rematch()
        }
    }

    /// Where the small maps come from. Without it, rows show the bare line.
    private func loadMaps(_ service: TrackServicePort) async {
        guard let source = try? await service.maps() else { return }
        useMaps(source)
    }

    public func useMaps(_ source: MapSource) {
        if source != thumbnails.source {
            thumbnails.source = source
            mapsRound += 1
        }
        mapCredit = source.credit
        defaults.set(source.credit, forKey: "mapCredit")
    }

    /// Shows what the library holds, without asking the service.
    public func showLibrary() async {
        tracks = await library.listed()
    }

    /// Import from the Tracks menu: the Mac's own file window, GPX and FIT only.
    public func importWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx"), UTType(filenameExtension: "fit")].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importFiles(urls) }
    }

    public func importFiles(_ urls: [URL]) async {
        var added = 0
        var lines: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                switch try await library.importFile(url, role: role) {
                case .added: added += 1
                case .alreadyHere(let existing): lines.append("\(url.lastPathComponent) is already here as \(existing.name).")
                }
            } catch {
                lines.append(error.localizedDescription)
            }
        }
        tracks = await library.listed()
        if added > 0 {
            lines.insert(added == 1 ? "1 track imported." : "\(added) tracks imported.", at: 0)
        }
        if added > 0, role == .owner {
            await refresh()
            let waiting = await library.waitingCount
            if waiting > 0 { lines.append(tracksLine) }
        }
        tracksLine = lines.joined(separator: " ")
    }

    public func points(_ id: String) async -> TrackPoints? {
        await library.points(id)
    }
}
