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
    /// The service as last saved, so Save is only there when there is something to save.
    @Published private var savedService = ServiceFields()

    private struct ServiceFields: Equatable {
        var address = ""
        var key = ""

        init(address: String = "", key: String = "") {
            self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The address or key differs from what was saved.
    public var serviceUnsaved: Bool {
        ServiceFields(address: serviceAddress, key: serviceKey) != savedService
    }

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

    /// The Download menu's disk image being made.
    @Published public private(set) var makingDownload = false

    // Places and breaks in the card's list.
    /// What OpenStreetMap named each photo's spot, by row.
    @Published public private(set) var foundPlaces: [String: PlaceLookup] = [:]
    /// Names typed with "Name place", by row; they win over OpenStreetMap's.
    @Published public private(set) var givenPlaces: [String: String] = [:]
    /// Every photo's spot asked about, or nothing more to wait for.
    @Published public private(set) var placesSettled = false
    /// The spot each found place was asked for, so a photo that moves is asked again.
    private var placeSpots: [String: String] = [:]
    private var lookingUpPlaces = false
    private var lookUpAgain = false
    /// OpenStreetMap did not answer for this card: no more asking until the next one.
    private var placesUnanswered = false
    /// A break this long between two photos is marked in the list (a setting).
    @Published public private(set) var breakMinutes = 20
    /// The break before a photo, in seconds, where it is at least that long.
    @Published public private(set) var breaks: [String: Int] = [:]

    // History.
    @Published public var historyPerson: UUID?
    @Published public private(set) var historyEntries: [HistoryEntry] = []

    // The NAS, as set in Settings.
    @Published public var nasAddress = ""
    @Published public var nasBackupAddress = ""
    @Published public var nasUser = ""
    @Published public var nasPassword = ""
    @Published public var nasLine = ""
    @Published public private(set) var nasBusy = false
    /// The NAS as last saved: what sending uses, while the fields above may
    /// hold edits not saved yet.
    @Published private var savedNAS = NASFields()

    private struct NASFields: Equatable {
        var address = ""
        var backup = ""
        var user = ""
        var password = ""

        init(address: String = "", backup: String = "", user: String = "", password: String = "") {
            self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            self.backup = backup.trimmingCharacters(in: .whitespacesAndNewlines)
            self.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
            self.password = password
        }

        var port: NASOverSMB { NASOverSMB(addresses: [address, backup], user: user, password: password) }
    }

    private var nasFields: NASFields {
        NASFields(address: nasAddress, backup: nasBackupAddress, user: nasUser, password: nasPassword)
    }

    /// A field differs from what was saved.
    public var nasUnsaved: Bool { nasFields != savedNAS }

    /// Photos that reached the NAS, and that were not sent, since the last
    /// notification: one notification per batch, never one per photo.
    private var batchSent = 0
    private var batchFailed = 0
    private let notifier: NotifierPort
    /// Names the place each photo was taken, for its folder.
    private let places: PlaceNaming

    // The queue: every saved copy on its way to the NAS, as kept in queue.json.
    @Published public private(set) var queueEntries: [QueueEntry] = [] {
        didSet { queueIndex = Dictionary(queueEntries.map { ($0.localPath, $0) }, uniquingKeysWith: { _, last in last }) }
    }
    /// The latest entry for each copy on this Mac.
    private var queueIndex: [String: QueueEntry] = [:]
    @Published public private(set) var sendingId: UUID?
    @Published public private(set) var sendPaused = false
    @Published public private(set) var queueLine = ""
    @Published public private(set) var nasReach = NASReach.checking
    private var checkingNAS = false
    /// The photo going up now; apart, so its progress redraws only the bar.
    public let meter = SendMeter()
    private let nasPort: NASPort?
    private var ourMounts: [String: NASConnection] = [:]
    private var cleanedFolders: Set<String> = []
    private var nextTry: Date?
    private var sendingNow = false
    private var sendTimer: Timer?

    public let library: TrackLibrary
    public let thumbnails: MapThumbnails
    private let peopleStore: PeopleStorePort
    private let history: HistoryStorePort
    private let queue: QueueStorePort
    private let unplaced: UnplacedStorePort
    @Published public private(set) var placingLater = false
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
                unplaced: UnplacedStorePort = UnplacedStoreFile.standard(),
                secrets: SecretStorePort = Keychain(),
                thumbnails: MapThumbnails? = nil,
                exifTool: ExifTool? = nil,
                nas: NASPort? = nil,
                notifier: NotifierPort? = nil,
                places: PlaceNaming? = nil) {
        self.notifier = notifier ?? MacNotifier.shared
        self.places = places ?? PlaceNames.shared
        self.exifTool = exifTool ?? ExifTool.bundled()
        self.library = library
        self.thumbnails = thumbnails ?? MapThumbnails()
        self.peopleStore = peopleStore
        self.history = history
        self.queue = queue
        self.unplaced = unplaced
        self.secrets = secrets
        self.nasPort = nas
        openOnCard = defaults.object(forKey: "openOnCard") as? Bool ?? true
        if defaults.object(forKey: "maxGapSeconds") != nil { maxGapSeconds = defaults.integer(forKey: "maxGapSeconds") }
        if defaults.object(forKey: "breakMinutes") != nil { breakMinutes = defaults.integer(forKey: "breakMinutes") }
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
        readSecrets()
        savedService = ServiceFields(address: serviceAddress, key: serviceKey)
        mapCredit = defaults.string(forKey: "mapCredit") ?? ""
        nasAddress = defaults.string(forKey: "nasAddress") ?? ""
        nasBackupAddress = defaults.string(forKey: "nasBackupAddress") ?? ""
        nasUser = defaults.string(forKey: "nasUser") ?? ""
        savedNAS = nasFields
        sendPaused = defaults.bool(forKey: "sendPaused")
        // A send cut off by a crash or a shutdown starts again from the beginning.
        var entries = (try? queue.load()) ?? []
        for i in entries.indices where entries[i].state == .sending { entries[i].state = .waiting }
        queueEntries = entries

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
        startSending()
        Task { await checkNAS() }
        // A click on a notification opens the Queue page.
        MacNotifier.onOpen = { [weak self] in
            self?.screen = .queue
            Windows.bringForward()
        }
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

    /// The service key and the NAS password share one keychain item, so a new
    /// build of Geotag asks for the Mac's password no more often than before.
    private struct StoredSecrets: Codable {
        var serviceKey: String
        var nasPassword: String
    }

    private func readSecrets() {
        let raw = secrets.read(Self.keyAccount) ?? ""
        if raw.hasPrefix("{"), let stored = try? JSONDecoder().decode(StoredSecrets.self, from: Data(raw.utf8)) {
            serviceKey = stored.serviceKey
            nasPassword = stored.nasPassword
        } else {
            // Kept before 0.12.0: the service key alone.
            serviceKey = raw
        }
    }

    private func writeSecrets(serviceKey: String, nasPassword: String) throws {
        let data = try JSONEncoder().encode(StoredSecrets(serviceKey: serviceKey, nasPassword: nasPassword))
        try secrets.write(Self.keyAccount, String(decoding: data, as: UTF8.self))
    }

    /// Saves the address and key, says so at once, then what the service answers.
    public func saveService() async {
        let fields = ServiceFields(address: serviceAddress, key: serviceKey)
        do {
            // The NAS password as last saved goes with it, never an edit not saved yet.
            try writeSecrets(serviceKey: fields.key, nasPassword: savedNAS.password)
        } catch {
            settingsLine = error.localizedDescription
            return
        }
        defaults.set(fields.address, forKey: "trackServiceAddress")
        savedService = fields
        await testService(saying: "Saved. ")
        if role != nil { await refresh() }
    }

    public func testService(saying prefix: String = "") async {
        guard let service else {
            settingsLine = prefix + ServiceError.notSetUp.localizedDescription
            return
        }
        settingsBusy = true
        defer { settingsBusy = false }
        settingsLine = prefix + "Checking the service"
        do {
            let status = try await service.status()
            serviceStatus = status
            role = status.role
            defaults.set(status.role.rawValue, forKey: "trackServiceRole")
            let who = status.role == .owner ? "Owner key" : "Reading key"
            settingsLine = prefix + "\(who). \(status.tracks) \(status.tracks == 1 ? "track" : "tracks") on the service."
        } catch {
            settingsLine = prefix + error.localizedDescription
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
                self.clearPlaces()
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
        // Earlier photos being placed write the same records: wait for them.
        while placingLater { try? await Task.sleep(for: .milliseconds(200)) }
        var later = (try? unplaced.load()) ?? []
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
        func remember(_ photo: ScannedPhoto) {
            guard !known.contains(photo.key) else { return }
            known.insert(photo.key)
            past.append(HistoryEntry(fileName: photo.fileName, size: photo.size, taken: photo.taken,
                                     subSeconds: photo.subSeconds, imported: Date()))
        }
        var savedCount = 0, failedCount = 0
        // Every photo's place first, for its folder: the lookups still going
        // are waited for, so none is asked twice.
        photosLine = "Looking up places"
        await lookUpRowPlaces()
        while lookingUpPlaces { try? await Task.sleep(for: .milliseconds(100)) }
        for row in todo {
            if stopAsked || readingRound != round || self.source?.id != source.id { break }
            photosLine = "Saving \(saveDone + 1) of \(saveTotal)"
            // A photo that cannot be placed is saved as it is, without a location.
            var item = SaveItem(photo: row.photo, placement: row.placement ?? .review(.noTrack), withoutLocation: row.needsReview)
            // Its place names its folder: the name typed for it, else
            // OpenStreetMap's, looked up before saving began.
            if let given = givenPlaces[row.id] {
                item.place = given
            } else if let spot = Self.spot(item), placeSpots[row.id] == Self.spotKey(spot),
                      case .found(let name)? = foundPlaces[row.id] {
                item.place = name
            }
            let named = item
            let result = await Task.detached { saver.save(named) }.value
            results[row.id] = result
            saveDone += 1
            switch result {
            case .saved(let url):
                savedCount += 1
                remember(row.photo)
                // Saved without a location: kept on the list to be placed later,
                // unless it has no time at all and never can be.
                if case .review(let reason)? = row.placement, reason != .noTime,
                   !later.contains(where: { $0.localPath == url.path }) {
                    later.append(UnplacedEntry(personId: personId, localPath: url.path, photo: row.photo))
                }
                changeQueue { $0.append(QueueEntry(personId: personId, localPath: url.path, relativePath: Self.relative(url))) }
            case .alreadyThere(let url):
                savedCount += 1
                remember(row.photo)
                // Its first save put it on the queue; should that be lost, it goes on again.
                if queueIndex[url.path] == nil {
                    changeQueue { $0.append(QueueEntry(personId: personId, localPath: url.path, relativePath: Self.relative(url))) }
                }
            case .failed(let why):
                failedCount += 1
                if why == Saver.diskFull { stopAsked = true }
            }
            // Written after every photo, so a crash or a pulled card loses nothing.
            try? history.save(personId, past)
            try? unplaced.save(later)
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
        if results.values.contains(.failed(Saver.diskFull)) { line = "Stopped: \(Saver.diskFull.lowercased()). \(savedCount) saved before that." }
        photosLine = line
    }

    public func stopSaving() {
        stopAsked = true
    }

    /// Where a photo is, for naming its folder: the track's position written
    /// into it, or its own; nil for one saved without a location.
    static func spot(_ item: SaveItem) -> (lat: Double, lon: Double)? {
        if let p = item.position { return (p.lat, p.lon) }
        if case .ownLocation = item.placement, let lat = item.photo.ownLat, let lon = item.photo.ownLon { return (lat, lon) }
        return nil
    }

    /// A card picked. One Geotag has seen before is read straight away for
    /// whoever it was last time (the pencil on the Person tile changes it);
    /// a new one asks whose it is first.
    public func choose(_ source: PhotoSource) {
        readingRound += 1
        self.source = source
        rows = []
        results = [:]
        clearPlaces()
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
        clearPlaces()
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
            refreshBreaks()
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
        Task { await placeLater() }
        guard let personId = importPerson, !rows.isEmpty else { return }
        for i in rows.indices {
            let photo = rows[i].photo
            let camera = photo.model.flatMap { book.camera(personId: personId, model: $0) }
            rows[i].placement = Matcher.place(photo, camera: camera, timeline: timeline, gap: maxGapSeconds)
        }
        // Placed photos may have moved: their places are asked again.
        Task { await lookUpRowPlaces() }
    }

    // MARK: Places and breaks

    /// "-54.8065,-68.3030": the spot a place was asked for.
    static func spotKey(_ spot: (lat: Double, lon: Double)) -> String {
        String(format: "%.4f,%.4f", spot.lat, spot.lon)
    }

    private func clearPlaces() {
        foundPlaces = [:]
        givenPlaces = [:]
        placeSpots = [:]
        placesSettled = false
        placesUnanswered = false
        breaks = [:]
    }

    /// Each photo's place, for the Place column and its folder: asked of
    /// OpenStreetMap a spot at a time (it keeps its answers), and again for a
    /// photo whose spot moved. Once it stops answering, the rest are left
    /// until the next change.
    public func lookUpRowPlaces() async {
        if lookingUpPlaces {
            lookUpAgain = true
            return
        }
        lookingUpPlaces = true
        defer { lookingUpPlaces = false }
        repeat {
            lookUpAgain = false
            let round = readingRound
            var found = foundPlaces
            var spots = placeSpots
            var sinceShown = 0
            for row in rows {
                let item = SaveItem(photo: row.photo, placement: row.placement ?? .review(.noTrack), withoutLocation: row.needsReview)
                guard let spot = Self.spot(item) else {
                    found[row.id] = nil
                    spots[row.id] = nil
                    continue
                }
                let key = Self.spotKey(spot)
                if spots[row.id] == key, found[row.id] != nil { continue }
                // No internet: the rest are not asked, rather than each waiting on it.
                if placesUnanswered { continue }
                let answer = await places.place(lat: spot.lat, lon: spot.lon)
                guard readingRound == round else { return }
                if answer == .unreachable {
                    placesUnanswered = true
                    continue
                }
                found[row.id] = answer
                spots[row.id] = key
                sinceShown += 1
                // Shown as they come, a batch at a time.
                if sinceShown >= 25 {
                    foundPlaces = found
                    placeSpots = spots
                    sinceShown = 0
                }
            }
            guard readingRound == round else { return }
            foundPlaces = found
            placeSpots = spots
            placesSettled = true
        } while lookUpAgain
    }

    /// The place a photo's folder will be named after: the name typed for
    /// it, else OpenStreetMap's; nil for none.
    public func placeName(_ row: ImportRow) -> String? {
        if let given = givenPlaces[row.id] { return given }
        if case .found(let name)? = foundPlaces[row.id] { return name }
        return nil
    }

    /// "Name place": that name for those photos' folder, over OpenStreetMap's.
    /// An empty name gives them OpenStreetMap's back.
    public func givePlace(_ name: String, to ids: Set<String>) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var given = givenPlaces
        for id in ids { given[id] = clean.isEmpty ? nil : clean }
        givenPlaces = given
    }

    public func setBreakMinutes(_ minutes: Int) {
        breakMinutes = min(max(minutes, 1), 600)
        defaults.set(breakMinutes, forKey: "breakMinutes")
        refreshBreaks()
    }

    private func refreshBreaks() {
        breaks = Breaks.find(rows.map(\.photo), minutes: breakMinutes)
    }

    /// Photos saved earlier without a location, tried again: a camera's offset
    /// or zone may have been set, the gap changed, or new tracks arrived. Each
    /// that can now be placed gets the location written into its copy on this
    /// Mac, checked like any save, and goes on the upload queue again.
    public func placeLater() async {
        guard !placingLater, !saving, let tool = exifTool else { return }
        let entries = (try? unplaced.load()) ?? []
        guard !entries.isEmpty else { return }
        placingLater = true
        defer { placingLater = false }
        await loadTimeline()
        var keep: [UnplacedEntry] = []
        var placed = 0
        var problems: [String] = []
        for entry in entries {
            // Moved or removed since by its owner: nothing to place.
            guard FileManager.default.fileExists(atPath: entry.localPath) else { continue }
            let camera = entry.model.flatMap { book.camera(personId: entry.personId, model: $0) }
            guard case .matched(let position) = Matcher.place(entry.photo, camera: camera, timeline: timeline, gap: maxGapSeconds) else {
                keep.append(entry)
                continue
            }
            let url = URL(fileURLWithPath: entry.localPath)
            let saver = Saver(exifTool: tool, folder: url.deletingLastPathComponent().deletingLastPathComponent())
            if let problem = await Task.detached(operation: { saver.addLocation(to: url, position) }).value {
                problems.append("\(entry.fileName): \(problem)")
                keep.append(entry)
                continue
            }
            placed += 1
            changeQueue { all in
                // Not sent yet: what goes is the copy as it is now. Sent, or on
                // its way: it goes again and replaces Geotag's earlier copy.
                if let i = all.lastIndex(where: { $0.localPath == entry.localPath && ($0.state == .waiting || $0.state == .failed) }) {
                    if all[i].state == .failed {
                        all[i].state = .waiting
                        all[i].reason = nil
                    }
                } else {
                    all.append(QueueEntry(personId: entry.personId, localPath: entry.localPath,
                                          relativePath: Self.relative(url), update: true))
                }
            }
        }
        try? unplaced.save(keep)
        guard placed > 0 || !problems.isEmpty, !photosBusy, !saving else { return }
        var line = placed == 0 ? "" : placed == 1 ? "1 photo saved earlier now has its location." : "\(placed) photos saved earlier now have their location."
        if let first = problems.first { line += (line.isEmpty ? "" : " ") + "Not placed: \(first)" }
        photosLine = line
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

    // MARK: The NAS

    /// "2027.01.12/IMG_0001.jpg": a saved copy's place under its person's folder.
    static func relative(_ url: URL) -> String {
        "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
    }

    /// Every change to the queue goes through here and is written at once, so
    /// saving and sending never undo each other's changes. Photos sent more
    /// than a week ago leave the list; History keeps every photo.
    private func changeQueue(_ change: (inout [QueueEntry]) -> Void) {
        var next = queueEntries
        change(&next)
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        next.removeAll { $0.state == .sent && ($0.sent ?? $0.added) < cutoff }
        queueEntries = next
        try? queue.save(next)
    }

    private func changeEntry(_ id: UUID, _ change: (inout QueueEntry) -> Void) {
        changeQueue { all in
            if let i = all.firstIndex(where: { $0.id == id }) { change(&all[i]) }
        }
    }

    /// Where a copy saved on this Mac stands with the NAS.
    public func queueEntry(for path: String) -> QueueEntry? {
        queueIndex[path]
    }

    /// Sending uses the NAS as last saved.
    private var nas: NASPort { nasPort ?? savedNAS.port }

    /// Saves the NAS settings, says so at once, then what the NAS answers.
    public func saveNAS() async {
        let fields = nasFields
        do {
            // The service key as last saved goes with it, never an edit not saved yet.
            try writeSecrets(serviceKey: savedService.key, nasPassword: fields.password)
        } catch {
            nasLine = error.localizedDescription
            return
        }
        defaults.set(fields.address, forKey: "nasAddress")
        defaults.set(fields.backup, forKey: "nasBackupAddress")
        defaults.set(fields.user, forKey: "nasUser")
        savedNAS = fields
        // New settings are tried now, not at the next minute.
        nextTry = nil
        await testNAS(saying: "Saved. ")
    }

    /// Opens the shared folder of every NAS folder in People with the settings
    /// on screen, saved or not, and says how it went.
    public func testNAS(saying prefix: String = "") async {
        let shares = Set(book.people.compactMap { NASFolder($0.nasFolder)?.share }).sorted()
        guard !shares.isEmpty else {
            nasLine = prefix + "Nobody has a NAS folder yet. Choose one in People."
            return
        }
        nasBusy = true
        defer { nasBusy = false }
        nasLine = prefix + "Checking the NAS"
        let port = nasPort ?? nasFields.port
        var lines: [String] = []
        var answered = false
        for share in shares {
            do {
                let connection = try await port.connect(share: share)
                if connection.ours { ourMounts[connection.folder.path] = connection }
                nasReach = .through(connection.address)
                answered = true
                let host = NASOverSMB.host(connection.address) ?? connection.address
                lines.append(shares.count == 1 ? "Connected through \(host)." : "\(share): connected through \(host).")
            } catch {
                nasReach = .unreachable
                lines.append((shares.count == 1 ? "" : "\(share): ") + error.localizedDescription)
            }
        }
        nasLine = prefix + lines.joined(separator: " ")
        if answered { nextTry = nil }
    }

    /// "19 photos are on the NAS." or "17 photos are on the NAS. 2 were not sent."
    public static func batchText(sent: Int, failed: Int) -> String {
        var parts: [String] = []
        if sent > 0 { parts.append(sent == 1 ? "1 photo is on the NAS." : "\(sent.formatted()) photos are on the NAS.") }
        if failed > 0 {
            if sent > 0 {
                parts.append(failed == 1 ? "1 was not sent." : "\(failed.formatted()) were not sent.")
            } else {
                parts.append(failed == 1 ? "1 photo was not sent." : "\(failed.formatted()) photos were not sent.")
            }
        }
        return parts.joined(separator: " ")
    }

    /// Whether the NAS answers now, for the NAS box on the Queue page: asked
    /// as Geotag opens and whenever the Queue page is shown, with the saved
    /// settings. Every shared folder in People must answer.
    public func checkNAS() async {
        guard !checkingNAS else { return }
        let shares = Set(book.people.compactMap { NASFolder($0.nasFolder)?.share }).sorted()
        guard !shares.isEmpty, nasPort != nil || !savedNAS.port.addresses.isEmpty else {
            nasReach = .notSetUp
            return
        }
        checkingNAS = true
        defer { checkingNAS = false }
        var answered: NASReach = .unreachable
        for share in shares {
            do {
                let connection = try await nas.connect(share: share)
                // Opened only to ask: closed again with Geotag's other openings once nothing is waiting.
                if connection.ours { ourMounts[connection.folder.path] = connection }
                answered = .through(connection.address)
            } catch {
                answered = .unreachable
                break
            }
        }
        if nasReach != answered { nasReach = answered }
    }

    private func startSending() {
        sendTimer?.invalidate()
        sendTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sendWaiting() }
        }
    }

    public func setSendPaused(_ on: Bool) {
        sendPaused = on
        defaults.set(on, forKey: "sendPaused")
        if on {
            say(sendingId == nil ? "Paused." : "Pausing after this photo.")
        } else {
            nextTry = nil
            say("")
        }
    }

    public func retryFailed() {
        changeQueue { all in
            for i in all.indices where all[i].state == .failed {
                all[i].state = .waiting
                all[i].reason = nil
                all[i].tries = 0
                all[i].notBefore = nil
            }
        }
        nextTry = nil
    }

    /// The queue's line, set only when it changes: every setting redraws the window.
    private func say(_ line: String) {
        if queueLine != line { queueLine = line }
    }

    /// The oldest photo that can go now: its person has a NAS folder, and it
    /// is not resting after a try that broke off.
    private func nextToSend() -> QueueEntry? {
        let now = Date()
        return queueEntries
            .filter { $0.state == .waiting && ($0.notBefore ?? .distantPast) <= now && NASFolder(book.person($0.personId)?.nasFolder) != nil }
            .min { $0.added < $1.added }
    }

    /// Sends waiting photos to the NAS, oldest first and one at a time, until
    /// nothing more can go now, the NAS can't be reached, or sending is paused.
    /// Called every few seconds from launch; the queue is on disk, so it
    /// carries on after a restart.
    public func sendWaiting() async {
        guard !sendingNow, !sendPaused else { return }
        if let next = nextTry, Date() < next { return }
        sendingNow = true
        defer { sendingNow = false }
        nextTry = nil
        // Someone taken off the list: their photos can't go anywhere.
        if queueEntries.contains(where: { $0.state == .waiting && book.person($0.personId) == nil }) {
            changeQueue { all in
                for i in all.indices where all[i].state == .waiting && book.person(all[i].personId) == nil {
                    all[i].state = .failed
                    all[i].reason = "Their person was removed from People"
                    batchFailed += 1
                }
            }
        }
        while !sendPaused, let entry = nextToSend() {
            guard let place = NASFolder(book.person(entry.personId)?.nasFolder) else { break }
            let connection: NASConnection
            do {
                connection = try await nas.connect(share: place.share)
            } catch {
                nasReach = .unreachable
                let retry = Date().addingTimeInterval(60)
                nextTry = retry
                say("\(error.localizedDescription) Trying again at \(When.current.time(retry)).")
                return
            }
            if connection.ours { ourMounts[connection.folder.path] = connection }
            if nasReach != .through(connection.address) { nasReach = .through(connection.address) }

            let name = (entry.relativePath as NSString).lastPathComponent
            let day = (entry.relativePath as NSString).deletingLastPathComponent
            var folder = place.folder(in: connection.folder)
            if !day.isEmpty { folder.appendPathComponent(day, isDirectory: true) }
            let clean = cleanedFolders.insert(folder.path).inserted
            changeEntry(entry.id) { $0.state = .sending }
            sendingId = entry.id
            meter.begin(name)
            let more = queueEntries.filter { $0.state == .waiting }.count
            let host = NASOverSMB.host(connection.address) ?? connection.address
            say("Sending \(name) to \(host)." + (more == 0 ? "" : " \(more) more waiting."))
            let local = URL(fileURLWithPath: entry.localPath)
            let tool = exifTool, update = entry.update, meter = self.meter
            // On a thread of its own: a connection that hangs must not hold up
            // the threads the rest of Geotag runs on.
            let outcome: Result<SendOutcome, NASError> = await withCheckedContinuation { done in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        done.resume(returning: .success(try NASSender.send(local, as: name, into: folder, update: update,
                                                                           clean: clean, exifTool: tool) { fraction in
                            Task { @MainActor in meter.show(fraction, for: name) }
                        }))
                    } catch {
                        done.resume(returning: .failure(error as? NASError ?? .failed(error.localizedDescription)))
                    }
                }
            }
            sendingId = nil
            meter.end()
            switch outcome {
            case .success(let result):
                batchSent += 1
                let landed = result.url.lastPathComponent
                changeEntry(entry.id) { e in
                    e.state = .sent
                    e.sent = Date()
                    e.sentAs = landed == name ? nil : landed
                    e.reason = nil
                    e.notBefore = nil
                }
            case .failure(.offline(let why)):
                // It rests a little longer after each break, so the others go first.
                changeEntry(entry.id) { e in
                    e.state = .waiting
                    e.tries += 1
                    e.reason = why
                    e.notBefore = Date().addingTimeInterval(Double(min(e.tries, 10)) * 60)
                }
            case .failure(.full):
                changeEntry(entry.id) { $0.state = .waiting }
                let retry = Date().addingTimeInterval(300)
                nextTry = retry
                say("NAS full. Trying again at \(When.current.time(retry)).")
                return
            case .failure(.failed(let why)):
                batchFailed += 1
                changeEntry(entry.id) { e in
                    e.state = .failed
                    e.reason = why
                }
            }
        }
        say(sendPaused ? "Paused." : restingLine())
        let waiting = queueEntries.contains { $0.state == .waiting && NASFolder(book.person($0.personId)?.nasFolder) != nil }
        // All that can go has gone, and nothing is still being saved or placed:
        // one notification for the whole batch.
        if !sendPaused, !waiting, !saving, !placingLater, batchSent + batchFailed > 0 {
            notifier.post(Self.batchText(sent: batchSent, failed: batchFailed))
            batchSent = 0
            batchFailed = 0
        }
        if !sendPaused, !waiting { await closeOurMounts() }
    }

    /// What the queue is waiting on, when nothing is going up.
    private func restingLine() -> String {
        let waiting = queueEntries.filter { $0.state == .waiting }
        let failed = queueEntries.filter { $0.state == .failed }.count
        var parts: [String] = []
        let names = Set(waiting.map(\.personId))
            .compactMap { book.person($0) }
            .filter { NASFolder($0.nasFolder) == nil }
            .map(\.name)
            .sorted()
        if !names.isEmpty {
            parts.append("\(names.joined(separator: ", ")) \(names.count == 1 ? "has" : "have") no NAS folder. Choose one in Settings, People.")
        }
        let resting = waiting.compactMap(\.notBefore).filter { $0 > Date() }
        if let soonest = resting.min() {
            parts.append("\(resting.count) to try again at \(When.current.time(soonest)).")
        }
        if failed > 0 { parts.append("\(failed) not sent: see the list.") }
        if parts.isEmpty, waiting.isEmpty, !queueEntries.isEmpty { return "Everything is on the NAS." }
        return parts.joined(separator: " ")
    }

    /// Shared folders Geotag opened, closed again once nothing is waiting.
    private func closeOurMounts() async {
        guard !ourMounts.isEmpty else { return }
        let open = Array(ourMounts.values)
        ourMounts = [:]
        cleanedFolders = []
        for connection in open { await nas.disconnect(connection) }
    }

    // MARK: Download

    /// The Download menu: a disk image of this Geotag, made now, put in the
    /// Downloads folder over one of the same name, and shown there in Finder.
    public func saveDownload() async {
        guard !makingDownload else { return }
        makingDownload = true
        defer { makingDownload = false }
        let app = Bundle.main.bundleURL
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let made: Result<URL, Error> = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(returning: Result { try Installer.save(app: app, version: appVersion, into: downloads) })
            }
        }
        switch made {
        case .success(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .failure(let error):
            let alert = NSAlert()
            alert.messageText = "Geotag was not saved to Downloads."
            alert.informativeText = error.localizedDescription
            alert.runModal()
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
        if !rows.isEmpty || report.added > 0 {
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
