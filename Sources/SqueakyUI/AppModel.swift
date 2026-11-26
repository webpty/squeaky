import UIKit
import SwiftUI
import UniformTypeIdentifiers
import SqueakyCore

public enum Screen: String, CaseIterable, Identifiable {
    case photos
    case tracks
    case queue
    case history
    case settings
    case clockDrift
    case cameraClocks
    case download

    public var id: String { rawValue }

    /// The sidebar's pages, then, after a line, what used to be menus at the
    /// top of the screen (David, 6 November 2026). Every one is a page of the
    /// one window: no other windows ("i despise apps that have many windows").
    public static let sidebar: [Screen] = [.photos, .queue, .history, .settings]
    public static let tools: [Screen] = [.tracks, .clockDrift, .cameraClocks, .download]

    public var title: String {
        switch self {
        case .tracks: return "Tracks"
        case .photos: return "Photos"
        case .queue: return "Queue"
        case .history: return "History"
        case .settings: return "Settings"
        case .clockDrift: return "Clock drift"
        case .cameraClocks: return "Camera clocks"
        case .download: return "Download"
        }
    }

    public var symbol: String {
        switch self {
        case .tracks: return "map"
        case .photos: return "photo.on.rectangle"
        case .queue: return "arrow.up.circle"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        case .clockDrift: return "clock.badge.exclamationmark"
        case .cameraClocks: return "camera"
        case .download: return "arrow.down.circle"
        }
    }
}

/// What a button could not do needs, offered beside the line that says so
/// (David, 1 November 2026: never a button that does nothing).
public enum PhotosFix: Equatable {
    /// Whose card this is, for a card read for nobody yet.
    case chooseWhose
    /// The person's save folder, then the save goes on.
    case chooseFolder(UUID)
    /// The track service, in Settings.
    case trackService
    /// A camera's details, opened in Settings.
    case camera(UUID)
    /// The camera list, in Settings.
    case cameras
    /// Tailscale, to reach the NAS from away.
    case openTailscale

    public var title: String {
        switch self {
        case .chooseWhose: return "Choose whose card"
        case .chooseFolder: return "Choose folder…"
        case .trackService: return "Open Settings"
        case .camera: return "Edit camera"
        case .cameras: return "Open Settings"
        case .openTailscale: return "Open Tailscale"
        }
    }
}

/// Where the check before saving stands: checking, or the photos still
/// without a track, the track service answering or not.
public enum TrackCheck: Equatable, Sendable {
    case checking
    /// Every photo has a track: on the phone, still shown before saving (0.29.5).
    case ready
    case noTrack(Int)
    case offline(Int)
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public var appearance = Appearance.system
    @Published public var screen = Screen.photos
    /// The offset code, laid over the whole window.
    @Published public var showingOffsetCode = false

    /// A page of the window. Camera clocks opens on the first camera.
    public func show(_ page: Screen) {
        screen = page
    }

    // The buffer server, bufr.cc, as set in Settings (0.30.0).
    @Published public var bufferAddress = ""
    @Published public var bufferKey = ""
    @Published public var bufferLine = ""
    @Published public private(set) var bufferBusy = false
    /// Photos sent to the buffer server that the NAS has not fetched yet, as last asked.
    @Published public private(set) var bufferWaiting: Int?
    /// Which way photos go now: straight to the NAS, or through the buffer server.
    @Published public private(set) var sendRoute: SendRoute?
    @Published private var savedBuffer = ServiceFields()
    private var bufferAsked: (at: Date, atHome: Bool?)?
    private var bufferTopping = false
    public let bufferUploads = BufferUploads()

    public enum SendRoute: Sendable { case nas, buffer }

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

    /// A key has been saved for the track service (0.29.30).
    public var serviceKeySaved: Bool { !savedService.key.isEmpty }

    /// The address and key put back as last saved: Change given up (0.29.30).
    public func revertService() {
        serviceAddress = savedService.address
        serviceKey = savedService.key
    }

    /// The track service forgotten: address and key cleared (0.29.30).
    public func removeService() async {
        do {
            try writeSecrets(serviceKey: "", nasPassword: savedNAS.password)
        } catch {
            settingsLine = error.localizedDescription
            return
        }
        defaults.removeObject(forKey: "trackServiceAddress")
        defaults.removeObject(forKey: "trackServiceRole")
        serviceAddress = ""
        serviceKey = ""
        savedService = ServiceFields()
        role = nil
        serviceStatus = nil
        settingsLine = ""
    }

    // Tracks.
    @Published public private(set) var tracks: [Track] = []
    /// Tracks named by where they are, by track id (0.29.5).
    @Published public private(set) var trackPlaces: [String: String] = [:]
    @Published public private(set) var namingTracks = false

    /// A track's name as Squeaky shows it: where it is, once looked up.
    /// The track service's name first (0.29.20), so every site shows the same;
    /// Squeaky's own only for a track the service does not hold.
    public func trackTitle(_ track: Track) -> String { track.place ?? trackPlaces[track.id] ?? track.name }
    @Published public var tracksLine = ""
    @Published public private(set) var tracksBusy = false
    /// The check before a card is saved by itself, while some of its photos
    /// have no track (0.27.0, David, 12 November 2026).
    @Published public private(set) var trackCheck: TrackCheck?
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
    @Published public private(set) var source: PhotoSource? {
        // The check before saving belongs to its card.
        didSet { if source?.id != oldValue?.id { trackCheck = nil } }
    }
    /// The card waiting for its owner to be chosen.
    @Published public var askingWhose: PhotoSource?
    @Published public private(set) var importPerson: UUID? { didSet { keepListSoon() } }
    @Published public private(set) var rows: [ImportRow] = [] { didSet { keepListSoon() } }
    @Published public private(set) var photosBusy = false { didSet { refreshWork() } }
    /// Any new line clears the fix offered with the last one.
    @Published public private(set) var photosLine = "" { didSet { photosFix = nil; refreshWork() } }
    /// The way to what the Photos line says is missing, as a button beside it.
    @Published public private(set) var photosFix: PhotosFix?
    /// How far reading the card has got.
    private var readProgress: (done: Int, total: Int)?
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
    @Published public private(set) var saving = false { didSet { refreshWork() } }
    @Published public private(set) var saveDone = 0 { didSet { refreshWork() } }
    @Published public private(set) var saveTotal = 0
    /// Each row's outcome, by row id, once saving has reached it.
    @Published public private(set) var results: [String: SaveResult] = [:] { didSet { keepListSoon() } }
    private var stopAsked = false

    /// The Download menu's disk image being made.
    /// The kind of Mac a disk image is being made for, while it is.
    public var makingDownload: Bool { false }
    /// What became of the last disk image, on the Download page.
    @Published public private(set) var downloadLine = ""
    /// The camera the "Set time and date in camera" window shows.
    @Published public var cameraGuide = "r5m2"

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
    /// A camera clock out by this many minutes or more gets its photos' dates
    /// corrected in the copies (a setting).
    @Published public private(set) var clockFixMinutes = 60
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

        var port: NASThroughFiles { NASThroughFiles() }
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
    /// The battery, to warn before a save outlasts it.
    private let power: PowerPort
    /// Each camera's own temperature, from its photos, for the Clock drift window.
    private let temperatureStore: TemperatureStorePort
    @Published public private(set) var temperatures = CameraTemperatures()
    /// Names the place each photo was taken, for its folder.
    private let places: PlaceNaming

    // The queue: every saved copy on its way to the NAS, as kept in queue.json.
    @Published public private(set) var queueEntries: [QueueEntry] = [] {
        didSet { queueIndex = Dictionary(queueEntries.map { ($0.localPath, $0) }, uniquingKeysWith: { _, last in last }) }
    }
    /// The latest entry for each copy on this Mac.
    private var queueIndex: [String: QueueEntry] = [:]
    /// How many photos go up to the NAS at once (David, 2 November 2026). One
    /// by default: over Tailscale three were no faster, the link already full.
    @Published public private(set) var sendAtOnce = 1
    /// How long a copy stays on this Mac once on the NAS (David, 5 November 2026).
    @Published public private(set) var keepOnMac = KeepOnMac.thirtyDays
    /// Every photo that reached the NAS, for good.
    @Published public private(set) var sentRecords: [SentRecord] = []
    private var lastTidy: Date?
    private var sentSinceTidy = false
    /// How long each step took for the last photos, for each NAS address.
    public private(set) var stepTimes = StepTimes()
    /// Photos are going up in this round of sending.
    private var sendingBatch = false { didSet { if sendingBatch != oldValue { refreshWork() } } }
    /// What the menu bar icon shows.
    public let work = WorkStatus()
    @Published public private(set) var sendPaused = false
    @Published public private(set) var queueLine = ""
    /// Said when the phone ended Squeaky's background time with photos still to send (0.29.29).
    @Published public var backgroundNote: String?
    @Published public private(set) var nasReach = NASReach.checking {
        didSet {
            // It answers again: the warning goes by itself.
            guard case .through = nasReach, nasAway else { return }
            nasAway = false
            if photosFix == .openTailscale { photosLine = "" }
        }
    }
    /// Squeaky opened with photos waiting and the NAS did not answer.
    @Published public private(set) var nasAway = false
    public static let nasAwayText = Words.t("The NAS isn't answering. If you're away from home, turn on Tailscale; otherwise check the connection.")
    private var checkingNAS = false
    /// The photos going up now; apart, so their progress redraws only the bar.
    public let meter = SendMeter()
    private let nasPort: NASPort?
    private var ourMounts: [String: NASConnection] = [:]
    private var cleanedFolders: Set<String> = []
    private var nextTry: Date?
    private var sendingNow = false
    /// When this run of sending began, and how many photos it has done: the pace for "about 20 min left".
    /// Whole photos timed going up, per NAS address, kept between launches.
    public private(set) var sendSpeeds = SendSpeeds()
    /// The address photos are going up through now; nil when none are.
    private var sendingThrough: String?
    /// Each queue entry's Mac copy size, for the time left.
    private var entrySizes: [UUID: Int64] = [:]
    private var sendTimer: Timer?

    public let library: TrackLibrary
    public let thumbnails: MapThumbnails
    private let peopleStore: PeopleStorePort
    private let history: HistoryStorePort
    private let queue: QueueStorePort
    private let unplaced: UnplacedStorePort
    private let sentLog: SentLogPort
    /// The Photos list kept through a restart; nil in a test that gives no queue file.
    private let photoList: PhotoListFile?
    private var keeping: Task<Void, Never>?
    /// Held photos and the server list, looked at each minute.
    private var minuteTimer: Timer?
    /// The photo behind the sidebar, from the last card inserted; nil until one has had a JPEG.
    @Published public private(set) var sidebarImage: PlatformImage?
    /// Its copy, beside the people list; nil when people are not kept in a file.
    let sidebarFile: URL?
    @Published public private(set) var placingLater = false
    /// What reads and writes the photos: ExifTool on the Mac, Squeaky's own
    /// writer for CR3 and JPG on the iPhone.
    private let engine: PhotoEngine?
    /// Bumped whenever reading should stop: a new card chosen, or an eject.
    private var readingRound = 0
    /// The card being ejected, while the Mac closes it: the Photos line spins
    /// and Eject is dimmed (0.27.2, David, 13 November 2026).
    @Published public private(set) var ejecting: String?
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
                exifTool: Any? = nil,
                nas: NASPort? = nil,
                notifier: NotifierPort? = nil,
                places: PlaceNaming? = nil,
                power: PowerPort? = nil,
                temperatures: TemperatureStorePort? = nil,
                sentLog: SentLogPort? = nil) {
        // Beside the people list unless told otherwise, so a test's stays in its scratch folder.
        self.temperatureStore = temperatures
            ?? (peopleStore as? PeopleStoreFile).map { TemperatureStoreFile(url: $0.url.deletingLastPathComponent().appendingPathComponent("temperatures.json")) }
            ?? TemperatureStoreFile.standard()
        self.sentLog = sentLog
            ?? (queue as? QueueStoreFile).map { SentLogFile(url: $0.url.deletingLastPathComponent().appendingPathComponent("sent.jsonl")) }
            ?? SentLogFile.standard()
        self.photoList = (queue as? QueueStoreFile).map { PhotoListFile.beside($0.url) }
        self.sidebarFile = (peopleStore as? PeopleStoreFile)?.url.deletingLastPathComponent().appendingPathComponent("Sidebar.jpg")
        if let sidebarFile, FileManager.default.fileExists(atPath: sidebarFile.path) {
            self.sidebarImage = PlatformImage.load(sidebarFile)
        }
        self.notifier = notifier ?? MacNotifier.shared
        self.power = power ?? MacPower()
        self.places = places ?? PlaceNames.shared
        self.engine = .native
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
        if defaults.object(forKey: "clockFixMinutes") != nil { clockFixMinutes = defaults.integer(forKey: "clockFixMinutes") }
        dateOrder = defaults.string(forKey: "dateOrder").flatMap(DateOrder.init(rawValue:)) ?? .system
        clock24 = defaults.object(forKey: "clock24") as? Bool
        When.current = When(order: dateOrder, clock24: clock24)
        do {
            if let saved = try peopleStore.load() {
                book = saved
            } else {
                // A new install starts with nobody: people are added in the setup or in Settings,
                // or come from iCloud (0.21.0, David, 5 November 2026).
                book = PeopleBook()
            }
        } catch {
            peopleLine = Words.t("The people list could not be read: {0}", error.localizedDescription)
        }
        self.temperatures = (try? temperatureStore.load()) ?? CameraTemperatures()
        if let raw = defaults.string(forKey: "appearance"), let mode = Appearance(rawValue: raw) {
            appearance = mode
        }
        macOwner = defaults.string(forKey: "macOwner").flatMap(UUID.init(uuidString:)).flatMap { id in book.person(id) != nil ? id : nil }
        serviceAddress = defaults.string(forKey: "trackServiceAddress") ?? ""
        if serviceAddress.isEmpty { serviceAddress = "https://geotrac.cc" }
        role = defaults.string(forKey: "trackServiceRole").flatMap(KeyRole.init(rawValue:))
        // Names given to cards in Squeaky removed (0.29.44, David): the iPhone cannot
        // rename a card, so each card shows its own name, as in Files.
        defaults.removeObject(forKey: "cardNicknames")
        readSecrets()
        savedService = ServiceFields(address: serviceAddress, key: serviceKey)
        bufferAddress = defaults.string(forKey: "bufferAddress") ?? ""
        if bufferAddress.isEmpty { bufferAddress = "https://bufr.cc" }
        savedBuffer = ServiceFields(address: bufferAddress, key: bufferKey)
        bufferUploads.onProgress = { [weak self] id, fraction in
            guard let self, self.meter.going[id] != nil else { return }
            self.meter.show(.sending(fraction), for: id)
        }
        bufferUploads.onDone = { [weak self] id, problem, seconds in self?.bufferDone(id, problem: problem, seconds: seconds) }
        bufferUploads.wake()
        mapCredit = defaults.string(forKey: "mapCredit") ?? ""
        nasAddress = defaults.string(forKey: "nasAddress") ?? ""
        nasBackupAddress = defaults.string(forKey: "nasBackupAddress") ?? ""
        nasUser = defaults.string(forKey: "nasUser") ?? ""
        savedNAS = nasFields
        sendPaused = defaults.bool(forKey: "sendPaused")
        if let data = defaults.data(forKey: "stepTimes"), let times = try? JSONDecoder().decode(StepTimes.self, from: data) { stepTimes = times }
        if let data = defaults.data(forKey: "sendSpeeds"), let speeds = try? JSONDecoder().decode(SendSpeeds.self, from: data) { sendSpeeds = speeds }
        if defaults.object(forKey: "sendAtOnce") != nil { sendAtOnce = min(max(defaults.integer(forKey: "sendAtOnce"), 1), 6) }
        // A send cut off by a crash or a shutdown starts again from the beginning.
        var entries = (try? queue.load()) ?? []
        for i in entries.indices where entries[i].state == .sending { entries[i].state = .waiting }
        // Reinstalled since (every week with a free Apple ID): the copies are
        // where they were, under this install's folder.
        if entries.contains(where: { PhoneFolders.current($0.localPath) != $0.localPath }) {
            for i in entries.indices { entries[i].localPath = PhoneFolders.current(entries[i].localPath) }
            try? queue.save(entries)
        }
        if var list = try? unplaced.load(), list.contains(where: { PhoneFolders.current($0.localPath) != $0.localPath }) {
            for i in list.indices { list[i].localPath = PhoneFolders.current(list[i].localPath) }
            try? unplaced.save(list)
        }
        queueEntries = entries
        keepOnMac = defaults.string(forKey: "keepOnMac").flatMap(KeepOnMac.init(rawValue:)) ?? .thirtyDays
        // Each person manages their own photos: the phone never removes a copy (David, 15 November 2026).
        keepOnMac = .always
        sentRecords = (try? self.sentLog.load()) ?? []
        if sentRecords.contains(where: { PhoneFolders.current($0.localPath) != $0.localPath }) {
            for i in sentRecords.indices { sentRecords[i].localPath = PhoneFolders.current(sentRecords[i].localPath) }
            try? self.sentLog.save(sentRecords)
        }
        // The list from before a restart, its card out until it comes back.
        if let kept = photoList?.load() {
            rows = kept.rows
            results = kept.results
            // Reinstalled since: the copies are under this install's folder (0.29.14).
            for (id, result) in results {
                switch result {
                case .saved(let url): results[id] = .saved(URL(fileURLWithPath: PhoneFolders.current(url.path)))
                case .alreadyThere(let url): results[id] = .alreadyThere(URL(fileURLWithPath: PhoneFolders.current(url.path)))
                case .failed: break
                }
            }
            importPerson = kept.personId.flatMap { book.person($0) != nil ? $0 : nil }
            photosLine = Self.cardOut
        }
        // The first time: the photos the queue still lists as sent go into the
        // record. Those sent before that have none, and stay (David, 5 November 2026).
        if sentRecords.isEmpty {
            let seeded = entries.filter { $0.state == .sent }.compactMap { e -> SentRecord? in
                guard let stamp = SentRecord.stamp(e.localPath) else { return nil }
                return SentRecord(personId: e.personId, localPath: e.localPath, nasPath: Self.landed(e), sent: e.sent ?? e.added,
                                  size: stamp.size, modified: stamp.modified)
            }
            try? self.sentLog.add(seeded)
            sentRecords = seeded
        }

        // The phone's person, set up by itself and tied to the ID the phone gives Squeaky
        // (0.29.25, David: "just register it to the phone's ... unique ID"); no name needed.
        if macOwner == nil {
            let id = UIDevice.current.identifierForVendor ?? UUID()
            var phone = Person(id: id, name: "")
            phone.nasFolder = NASThroughFiles.share
            var next = book
            if next.person(id) == nil { next.save(phone) }
            if next.person(PhoneFolders.othersId) == nil { next.save(Person(id: PhoneFolders.othersId, name: "Others")) }
            try? peopleStore.save(next)
            book = next
            macOwner = id
            defaults.set(id.uuidString, forKey: "macOwner")
        }
        // Once (0.29.19), before any card is read (0.29.21): cards switched to someone
        // else's by a tap on the old Card row go back to the phone's person.
        if !defaults.bool(forKey: "cardOwnersReset"), let owner = macOwner {
            var owners = defaults.dictionary(forKey: "cardPeople") as? [String: String] ?? [:]
            for (card, person) in owners where person == PhoneFolders.othersId.uuidString { owners[card] = owner.uuidString }
            defaults.set(owners, forKey: "cardPeople")
            defaults.set(true, forKey: "cardOwnersReset")
        }
        let active = UIApplication.didBecomeActiveNotification
        NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in
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
    }

    /// As Squeaky opens: photos waiting and no answer from the NAS at either
    /// address, so say so once, here and as a notification (David, 1 November 2026).
    public func announceNASAway() {
        let waiting = queueEntries.contains { $0.state == .waiting && NASFolder(book.person($0.personId)?.nasFolder) != nil }
        guard nasReach == .unreachable, waiting else { return }
        nasAway = true
        notifier.post(Self.nasAwayText, kind: "nas-away")
        if photosLine.isEmpty { say(Self.nasAwayText, fix: Tailscale.app == nil ? nil : .openTailscale) }
    }

    // MARK: Setting up this Mac

    /// The setup is showing: once on a new Mac, and from the Squeaky menu.
    @Published public var settingUp = false
    /// Whose Mac this is: first in line when a new card asks whose it is.
    @Published public private(set) var macOwner: UUID?

    public func setMacOwner(_ id: UUID?) {
        macOwner = id
        defaults.set(id?.uuidString, forKey: "macOwner")
    }

    /// A Mac set up before the setup existed has a track service or a save
    /// folder already, and never sees it unasked.
    public var needsSetup: Bool {
        guard !defaults.bool(forKey: "setupDone") else { return false }
        // A new install that took its settings from iCloud still wants this
        // Mac's own: the password, the key, the save folders.
        return serviceAddress.isEmpty && !book.people.contains { !($0.saveFolder ?? "").isEmpty }
    }

    public func finishSetup() {
        defaults.set(true, forKey: "setupDone")
        settingUp = false
    }

    /// Everyone, whose Mac this is first.
    public var peopleOwnerFirst: [Person] {
        guard let owner = macOwner, let i = book.people.firstIndex(where: { $0.id == owner }) else { return book.people }
        var people = book.people
        people.insert(people.remove(at: i), at: 0)
        return people
    }

    /// What quitting now would cut off, for Command-Q to ask about; nil when nothing.
    public func quitCutOff() -> String? {
        var parts: [String] = []
        if saving, let source {
            let left = saveTotal - saveDone
            parts.append(Words.t("{0} {1} on {2} {3} not saved yet. Reopening Squeaky and clicking Save photos carries on from there.", left.formatted(), left == 1 ? Words.t("photo") : Words.t("photos"), source.name, left == 1 ? Words.t("is") : Words.t("are")))
        }
        let going = queueEntries.filter { ($0.state == .waiting || $0.state == .sending) && NASFolder(book.person($0.personId)?.nasFolder) != nil }.count
        if going > 0 {
            parts.append(Words.t("{0} {1} uploading to the NAS. Reopening Squeaky will resume the upload.", going.formatted(), going == 1 ? Words.t("photo is") : Words.t("photos are")))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// At launch: show what this Mac has, then ask the service, and again every ten minutes.
    public func start() async {
        // A window opened again runs this again; the rest is once per launch.
        guard !started else { return }
        started = true
        // Anyone else left on the phone from before is removed, and a NAS
        // folder kept from before gives way to the server chosen in Settings.
        if let owner = macOwner.flatMap({ book.person($0) }),
           book.people.contains(where: { $0.id != owner.id && $0.id != PhoneFolders.othersId })
            || owner.nasFolder != NASThroughFiles.share || book.person(PhoneFolders.othersId) == nil {
            setPhonePerson(name: owner.name)
        }
        removeCamerasWithoutOffset()
        if needsSetup {
            settingUp = true
        } else {
            defaults.set(true, forKey: "setupDone")
        }
        applyAppearance()
        startCards()
        // Before any sending: nothing tidied away before it is in the library.
        await moveOutOfFiles()
        startSending()
        Task {
            await checkNAS()
            announceNASAway()
            await publishAllHistory()
        }
        // A click on a notification opens the Queue page.
        MacNotifier.onOpen = { [weak self] in
            self?.screen = .queue
            Windows.bringForward()
        }
        tracks = await library.listed()
        trackPlaces = TrackPlaces.load(TrackPlaces.file(beside: (peopleStore as? PeopleStoreFile)?.url))
        await refresh()
        minuteTimer?.invalidate()
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if self?.queueEntries.contains(where: \.held) == true { await self?.refresh() }
                // Not on the server yet: tried again each minute, in the background (0.29.21).
                if self?.sharedProblem != nil { await self?.shareWithServer() }
            }
        }
        timer?.invalidate()
        remindClocks()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
                self?.remindClocks()
            }
        }
    }

    var service: TrackServicePort? {
        serviceForTest ?? TrackServiceHTTP(address: serviceAddress, key: serviceKey)
    }

    /// A stand-in track service, for the self-test: nothing goes online and
    /// no setting is written.
    private var serviceForTest: TrackServicePort?
    public func useServiceForTest(_ service: TrackServicePort, role: KeyRole) {
        serviceForTest = service
        self.role = role
    }

    // MARK: Settings

    /// The service key and the NAS password share one keychain item, so a new
    /// build of Squeaky asks for the Mac's password no more often than before.
    private struct StoredSecrets: Codable {
        var serviceKey: String
        var nasPassword: String
        /// The buffer server's key, from 0.30.0.
        var bufferKey: String?
    }

    private func readSecrets() {
        let raw = secrets.read(Self.keyAccount) ?? ""
        if raw.hasPrefix("{"), let stored = try? JSONDecoder().decode(StoredSecrets.self, from: Data(raw.utf8)) {
            serviceKey = stored.serviceKey
            nasPassword = stored.nasPassword
            bufferKey = stored.bufferKey ?? ""
        } else {
            // Kept before 0.12.0: the service key alone.
            serviceKey = raw
        }
    }

    private func writeSecrets(serviceKey: String, nasPassword: String, bufferKey: String? = nil) throws {
        let data = try JSONEncoder().encode(StoredSecrets(serviceKey: serviceKey, nasPassword: nasPassword,
                                                          bufferKey: bufferKey ?? savedBuffer.key))
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
        await testService(saying: Words.t("Saved. "))
        if role != nil { await refresh() }
    }

    public func testService(saying prefix: String = "") async {
        guard let service else {
            settingsLine = prefix + ServiceError.notSetUp.localizedDescription
            return
        }
        settingsBusy = true
        defer { settingsBusy = false }
        settingsLine = prefix + Words.t("Checking the service")
        do {
            let status = try await service.status()
            serviceStatus = status
            role = status.role
            defaults.set(status.role.rawValue, forKey: "trackServiceRole")
            let who = status.role == .owner ? Words.t("Owner key") : Words.t("Reading key")
            settingsLine = prefix + Words.t("{0}. {1} {2} on the service.", who, status.tracks, status.tracks == 1 ? Words.t("track") : Words.t("tracks"))
        } catch {
            settingsLine = prefix + error.localizedDescription
        }
    }

    /// The track service is set up, so Strava can be connected through it.
    public var hasService: Bool { service != nil }

    /// Somebody has a NAS folder and the NAS card an address, so there is something to test.
    public var canTestNAS: Bool {
        book.people.contains { NASFolder($0.nasFolder) != nil } && (nasPort != nil || !nasFields.port.addresses.isEmpty)
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
            await UIApplication.shared.open(url)
            settingsLine = Words.t("Approve on Strava in the browser.")
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
                settingsLine = Words.t("Strava connected.")
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
            peopleLine = Words.t("Not saved: {0}", error.localizedDescription)
        }
    }

    public func save(_ person: Person) { store { $0.save(person) } }
    public func remove(person id: UUID) { store { $0.remove(person: id) }; rematch() }
    public func save(_ camera: Camera) {
        var camera = camera
        // An offset set here: dated, and shared with the person's other devices (0.29.1).
        let before = book.cameras.first { $0.id == camera.id }
        let changed = before?.offsetSeconds != camera.offsetSeconds || before?.readings != camera.readings
        if changed, camera.offsetSeconds != nil { camera.offsetSet = Date() }
        store { $0.save(camera) }
        rematch()
        if changed { let person = camera.personId; Task { await publishCameras(person) } }
    }
    public func remove(camera id: UUID) { store { $0.remove(camera: id) }; rematch() }

    // MARK: Photos

    private func startCards() {
    }

    public func setOpenOnCard(_ on: Bool) {
        openOnCard = false
    }

    /// A card picked: first, whose is it.
    // MARK: Saving

    /// The rows Save photos would save: ticked and placed, or let through.
    public var readyToSave: [ImportRow] {
        // Every photo selected, those whose camera has no time offset too: the panel
        // before saving says they go without a location, and the choice is the
        // person's (0.31.8, David: "i always want the choice"; 0.31.4 held them).
        rows.filter(\.willImport)
    }

    /// "Hide already saved" (0.34.4, David), on to start and kept: what is
    /// already saved is hidden and cannot be selected or saved. Off, it shows,
    /// and saving it copies it again.
    @Published public var hideSaved: Bool = UserDefaults.standard.object(forKey: "hideSaved") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(hideSaved, forKey: "hideSaved")
            if hideSaved { setTicked(Set(rows.filter { isSaved($0) }.map(\.id)), false) }
        }
    }

    /// The rows that can be chosen now: all of them, or only those not saved yet.
    public var choosable: [ImportRow] { hideSaved ? rows.filter { !isSaved($0) } : rows }

    /// Every photo on the card that can be chosen, whatever is selected (0.32.1, David: "Save all").
    public func saveAll() {
        guard !saving, !photosBusy else { return }
        setTicked(Set(choosable.map(\.id)), true)
        Task { await checkTracksBeforeSave() }
    }

    /// Copies every ready photo into the person's folder with its location,
    /// one at a time, checking each; records them in History and puts them on
    /// the upload queue. Stop, or Eject, ends it after the current photo.
    /// `hold`: the track service could not be reached, so photos without a
    /// track wait on this Mac until the tracks have been checked again.
    public func savePhotos(hold: Bool = false, only: Set<String>? = nil) async {
        guard !saving else { return }
        guard let source else {
            photosLine = rows.isEmpty ? Words.t("Insert a card.") : Self.cardOut
            return
        }
        guard let personId = importPerson, let person = book.person(personId) else {
            say(Words.t("Choose whose card {0} is.", source.name), fix: .chooseWhose)
            return
        }
        guard let folder = saveFolder(of: person), !folder.isEmpty else {
            say(Words.t("{0} has no save folder yet.", person.name), fix: .chooseFolder(personId))
            return
        }
        guard let engine else {
            photosLine = Words.t("ExifTool is missing from Squeaky. Install Squeaky again.")
            return
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            say(Words.t("{0}'s save folder can't be found: {1}. If it is on a drive, plug the drive in, or choose another folder.", person.name, folder),
                fix: .chooseFolder(personId))
            return
        }
        // "Save only those with a track": the others stay selected for later (0.34.5, David).
        var todo = only.map { ids in readyToSave.filter { ids.contains($0.id) } } ?? readyToSave
        // No duplicates (0.31.8, David): just before copying, every photo selected
        // is checked against everything known to be copied, from any device, and
        // those are left out.
        // Unless "Include previously saved" is on (0.32.1, David).
        let again = !hideSaved
        let copiedBefore = again ? [] : alreadyCopied(personId)
        let skipped = again ? [] : todo.filter { copiedBefore.contains($0.photo.key) || isSaved($0) }
        if !skipped.isEmpty {
            let left = Set(skipped.map(\.id))
            todo.removeAll { left.contains($0.id) }
            var unticked = rows
            for i in unticked.indices where left.contains(unticked[i].id) {
                unticked[i].ticked = false
                if results[unticked[i].id] == nil { unticked[i].status = .alreadyImported }
            }
            rows = unticked
        }
        let skippedLine = skipped.isEmpty ? "" : Words.t("{0} photos already copied, not copied again.", skipped.count)
        guard !todo.isEmpty else {
            photosLine = !skipped.isEmpty ? skippedLine
                : rows.isEmpty ? Words.t("There are no photos on {0}.", source.name) : Words.t("Every photo on {0} is already saved.", source.name)
            return
        }
        // Earlier photos being placed write the same records: wait for them.
        while placingLater { try? await Task.sleep(for: .milliseconds(200)) }
        var later = (try? unplaced.load()) ?? []
        let saver = Saver(engine: engine, folder: URL(fileURLWithPath: folder, isDirectory: true))
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
        // Videos whose file has no room for a location, saved without one (0.33.0).
        var videosWithoutRoom = 0
        // Already in Photos, by name and moment: not added again (0.34.4, David).
        var alreadyInPhotos = 0
        var photosIndex: PhoneLibrary.Index?
        var photosIndexRead = false
        func inPhotos(_ row: ImportRow, shift: Int) async -> Bool {
            let zone = Moments.zoneSeconds(row.photo.zone ?? "")
            let moment = Moments.clockReading(row.photo).map { $0.addingTimeInterval(Double(shift) - Double(zone ?? 0)) }
            if !photosIndexRead {
                photosIndexRead = true
                let times = todo.compactMap { Moments.clockReading($0.photo) }
                if let first = times.min(), let last = times.max() {
                    photosLine = Words.t("Checking Photos for copies already there")
                    photosIndex = await PhoneLibrary.index(around: first.addingTimeInterval(-2 * 86_400)...last.addingTimeInterval(2 * 86_400))
                }
            }
            guard let photosIndex,
                  photosIndex.contains(name: row.photo.fileName, moment: moment, zoneKnown: zone != nil) else { return false }
            alreadyInPhotos += 1
            return true
        }
        var cardGone: String?
        var libraryFailed = 0
        var libraryProblem: String?
        backgroundedDuringSave = false
        // Every photo's place first, for its folder: the lookups still going
        // are waited for, so none is asked twice.
        photosLine = Words.t("Looking up places")
        await lookUpRowPlaces()
        while lookingUpPlaces { try? await Task.sleep(for: .milliseconds(100)) }
        let began = Date()
        var warnedPower = false
        // Bursts, each to its own folder, numbered on from those already in its day folder.
        var burstOf: [String: Int] = [:]
        for (n, ids) in Bursts.find(todo.map(\.photo)).enumerated() { for id in ids { burstOf[id] = n } }
        var burstName: [Int: String] = [:]
        var namedIn: [String: Set<String>] = [:]
        for row in todo {
            if stopAsked || readingRound != round || self.source?.id != source.id { break }
            // How long is left at the pace so far, and whether the battery lasts that long.
            let left = Remaining.estimate(done: saveDone, total: saveTotal, since: began)
            let said = Self.savingLine(done: saveDone, total: saveTotal, left: left, battery: left == nil ? nil : power.batteryLeft())
            if let warning = said.warning, !warnedPower {
                warnedPower = true
                notifier.post(warning, kind: "power")
            }
            photosLine = said.line
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
            // A camera whose clock was far out: the copy gets the right dates.
            item.shift = dateShift(row.photo, personId: personId)
            if let n = burstOf[row.id] {
                if burstName[n] == nil {
                    let dayPath = URL(fileURLWithPath: folder, isDirectory: true)
                        .appendingPathComponent(Saver.folderName(item.photo, place: item.place, shift: item.shift), isDirectory: true)
                    let name = Bursts.nextName(in: dayPath, taken: namedIn[dayPath.path] ?? [])
                    burstName[n] = name
                    namedIn[dayPath.path, default: []].insert(name)
                }
                item.burst = burstName[n]
            }
            // HIF (HDR) photos: added to Photos as they are, with their place given to Photos,
            // never saved as a copy, sent or listed (0.29.28, David: "copy the hif ... not saved on the server").
            if NativeMetadata.isHEIF(row.photo.url) {
                if libraryAllowed == nil {
                    photosLine = Words.t("Waiting for permission to add to Photos")
                    libraryAllowed = await PhoneLibrary.allowed()
                }
                var outcome: SaveResult = .saved(row.photo.url)
                if await inPhotos(row, shift: item.shift) {
                    var added = defaults.stringArray(forKey: "heifAdded") ?? []
                    added.append(row.photo.key)
                    defaults.set(added, forKey: "heifAdded")
                    savedCount += 1
                } else if libraryAllowed == true {
                    do {
                        try await PhoneLibrary.add(row.photo.url, at: item.position,
                                                   taken: item.position?.moment ?? Moments.clockReading(row.photo).map {
                                                       $0.addingTimeInterval(-Double(Moments.zoneSeconds(row.photo.zone ?? "") ?? 0)) })
                        var added = defaults.stringArray(forKey: "heifAdded") ?? []
                        added.append(row.photo.key)
                        defaults.set(added, forKey: "heifAdded")
                        savedCount += 1
                    } catch {
                        outcome = .failed(Words.t("It could not be added to Photos: {0}", error.localizedDescription))
                        failedCount += 1
                    }
                } else {
                    outcome = .failed(Words.t("Squeaky isn't allowed to add photos: allow it in the phone's Settings, Privacy, Photos, Squeaky."))
                    failedCount += 1
                }
                results[row.id] = outcome
                saveDone += 1
                continue
            }
            let named = item
            let result = await Task.detached { saver.save(named) }.value
            // The card gone mid-save (pulled, or the phone stopped letting Squeaky in): stop at
            // once, the rest left to be saved, not marked as failed (0.29.13, David, 16 November 2026).
            if case .failed(let why) = result, !FileManager.default.fileExists(atPath: row.photo.url.path) {
                cardGone = Words.t("The card stopped answering after {0} photos:", savedCount) + " " + Words.t(why)
                break
            }
            results[row.id] = result
            saveDone += 1
            switch result {
            case .saved(let url):
                savedCount += 1
                remember(row.photo)
                if row.photo.isVideo, named.position != nil, (try? NativeMetadata.read(url))?.lat == nil { videosWithoutRoom += 1 }
                // A video into Photos with its place and moment given to Photos; a RAW video never (0.33.0).
                if row.photo.isVideo, !PhotoKinds.isRawVideo(url), await inPhotos(row, shift: named.shift) {
                    if !goesToServer(personId) { try? FileManager.default.removeItem(at: url) }
                } else if row.photo.isVideo, !PhotoKinds.isRawVideo(url) {
                    if libraryAllowed == nil {
                        photosLine = Words.t("Waiting for permission to add to Photos")
                        libraryAllowed = await PhoneLibrary.allowed()
                    }
                    if libraryAllowed == true {
                        do {
                            let zone = Double(Moments.zoneSeconds(row.photo.zone ?? "") ?? 0)
                            let taken = Moments.clockReading(row.photo).map { $0.addingTimeInterval(Double(named.shift) - zone) }
                            try await PhoneLibrary.add(url, at: named.position, taken: named.position?.moment ?? taken, video: true)
                            if !goesToServer(personId) { try? FileManager.default.removeItem(at: url) }
                        } catch {
                            libraryFailed += 1
                            libraryProblem = error.localizedDescription
                        }
                    } else {
                        libraryFailed += 1
                        libraryProblem = Words.t("Squeaky isn't allowed to add photos: allow it in the phone's Settings, Privacy, Photos, Squeaky.")
                    }
                }
                // Into the Photos library, then the working copy of someone else's photo is no longer needed (0.29.15).
                if PhoneLibrary.isJPG(url), await inPhotos(row, shift: named.shift) {
                    if !goesToServer(personId) { try? FileManager.default.removeItem(at: url) }
                } else if PhoneLibrary.isJPG(url) {
                    if libraryAllowed == nil {
                        photosLine = Words.t("Waiting for permission to add to Photos")
                        libraryAllowed = await PhoneLibrary.allowed()
                    }

                    if libraryAllowed == true {
                        do {
                            try await PhoneLibrary.add(url)
                            if !goesToServer(personId) { try? FileManager.default.removeItem(at: url) }
                        } catch {
                            libraryFailed += 1
                            libraryProblem = error.localizedDescription
                        }
                    } else {
                        libraryFailed += 1
                        libraryProblem = Words.t("Squeaky isn't allowed to add photos: allow it in the phone's Settings, Privacy, Photos, Squeaky.")
                    }
                }
                // Saved without a location: kept on the list to be placed later,
                // unless it has no time at all and never can be.
                if case .review(let reason)? = row.placement, reason != .noTime,
                   !later.contains(where: { $0.localPath == url.path }) {
                    later.append(UnplacedEntry(personId: personId, localPath: url.path, photo: row.photo, shifted: named.shift))
                }
                let held = hold && row.placement == .review(.noTrack)
                if goesToServer(personId) {
                    changeQueue { $0.append(QueueEntry(personId: personId, localPath: url.path, relativePath: Self.relative(url), held: held)) }
                }
            case .alreadyThere(let url):
                savedCount += 1
                remember(row.photo)
                // Its first save put it on the queue; should that be lost, it goes on again.
                if queueIndex[url.path] == nil, goesToServer(personId) {
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
        // Changed as one list: row by row, a card of thousands copies the whole
        // list for every photo and redraws the table as many times.
        let seen = Set(past.map(\.key))
        var marked = rows
        for i in marked.indices where seen.contains(marked[i].photo.key) {
            marked[i].status = .alreadyImported
            marked[i].ticked = false
        }
        rows = marked
        if historyPerson == personId { historyEntries = past }
        Task { await shareWithServer() }
        // Ejected or another card chosen meanwhile: that line stands.
        guard readingRound == round else { return }
        let stopped = saveDone < saveTotal
        var line = stopped ? Words.t("Stopped after {0} of {1}.", saveDone, saveTotal) : Words.t("{0} saved.", savedCount)
        if stopped { line += Words.t(" {0} saved.", savedCount) }
        let unplaced = todo.filter { $0.needsReview && results[$0.id]?.url != nil }.count
        // The phone has no Status column: the reasons themselves, with how many each (0.29.13).
        if unplaced > 0 { line += Words.t(" {0} of them without a location.", unplaced) }
        var reasons: [String: Int] = [:]
        var order: [String] = []
        for row in todo {
            guard case .failed(let why)? = results[row.id] else { continue }
            let said = Words.t(why)
            if reasons[said] == nil { order.append(said) }
            reasons[said, default: 0] += 1
        }
        for said in order { line += " " + Words.t("{0} not saved: {1}", reasons[said]!, said) }
        if libraryFailed > 0, let libraryProblem { line += " " + Words.t("{0} not added to Photos: {1}", libraryFailed, libraryProblem) }
        if let cardGone {
            line = cardGone + " " + Words.t("{0} saved; the rest are still to save, and are saved when the card is opened again.", savedCount)
            if backgroundedDuringSave { line += " " + Words.t("Squeaky was in the background meanwhile, which can stop the card.") }
        }
        if results.values.contains(.failed(Saver.diskFull)) { line = Words.t("Stopped: {0}. {1} saved before that.", Words.t(Saver.diskFull).lowercased(), savedCount) }
        if !skippedLine.isEmpty { line += " " + skippedLine }
        if alreadyInPhotos > 0 { line += " " + Words.t("{0} already in Photos, not added again.", alreadyInPhotos) }
        if videosWithoutRoom > 0 {
            line += " " + (videosWithoutRoom == 1 ? Words.t("1 video saved without a location: its file has no room for one.")
                                                   : Words.t("{0} videos saved without a location: their files have no room for one.", videosWithoutRoom))
        }
        // Done before the last line is said, so the menu bar never shows it.
        saving = false
        photosLine = line
        // The card gone: let go of, so it is read again as soon as it is back.
        if cardGone != nil, let gone = self.source {
            PhoneFolders.release(gone.url)
            self.source = nil
        }
        // Every photo is on this Mac: the NAS copies go from there, so the
        // card is not needed any more (David, 1 November 2026).
        // No eject on the phone: the card is let go of, and can come out.
        // Only once every photo on the card is saved: with some left, the card stays
        // open to choose more (0.32.1, David).
        if !stopped, failedCount == 0, savedCount > 0, source.isCard, self.source?.id == source.id,
           rows.allSatisfy({ isSaved($0) }) {
            let onPhone = Words.t("{0} {1} on this iPhone; the NAS copies go from there.", savedCount.formatted(), savedCount == 1 ? Words.t("photo is") : Words.t("photos are"))
            letGo(done: onPhone)
        }
    }

    /// Set by the phone's app when it goes to the background during a save (0.29.13).
    public var backgroundedDuringSave = false
    /// Whether the phone lets Squeaky add photos to the library; asked once a launch.
    private var libraryAllowed: Bool?

    /// Once (0.29.15): the copies in Files moved to Squeaky's hidden storage,
    /// every JPG among them added to the Photos library, the records moved
    /// with them. Done again next launch until every JPG is in; nothing is
    /// deleted on the way.
    /// True while photos are moved out of Files and into Photos: the wheel shows (0.29.26).
    @Published public private(set) var movingOutOfFiles = false

    func moveOutOfFiles() async {
        guard !defaults.bool(forKey: "movedToLibrary") else { return }
        movingOutOfFiles = true
        defer { movingOutOfFiles = false }
        let fm = FileManager.default
        let old = PhoneFolders.documents, new = PhoneFolders.copies
        // Every step said as it happens (0.29.16, David: "it's really exhausting to have to ask for basic things like this").
        if !((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty {
            photosLine = Words.t("Moving photos out of Files")
        }
        // The folders moved first, and every path kept with them.
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where !name.hasPrefix(".") {
            let from = old.appendingPathComponent(name), to = new.appendingPathComponent(name)
            if fm.fileExists(atPath: to.path) {
                for item in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] {
                    try? fm.moveItem(at: from.appendingPathComponent(item), to: to.appendingPathComponent(item))
                }
                try? fm.removeItem(at: from)
            } else {
                try? fm.moveItem(at: from, to: to)
            }
        }
        let move = { (path: String) -> String in path.hasPrefix(old.path + "/") ? new.path + path.dropFirst(old.path.count) : path }
        changeQueue { all in for i in all.indices { all[i].localPath = move(all[i].localPath) } }
        if var list = try? unplaced.load() {
            for i in list.indices { list[i].localPath = move(list[i].localPath) }
            try? unplaced.save(list)
        }
        for i in sentRecords.indices { sentRecords[i].localPath = move(sentRecords[i].localPath) }
        try? sentLog.save(sentRecords)
        for (id, result) in results {
            if case .saved(let url) = result { results[id] = .saved(URL(fileURLWithPath: move(url.path))) }
            if case .alreadyThere(let url) = result { results[id] = .alreadyThere(URL(fileURLWithPath: move(url.path))) }
        }
        // Then every JPG into the library.
        photosLine = Words.t("Waiting for permission to add to Photos")
        guard await PhoneLibrary.allowed() else {
            photosLine = Words.t("Squeaky isn't allowed to add photos: allow it in the phone's Settings, Privacy, Photos, Squeaky.")
            return
        }
        var added = defaults.stringArray(forKey: "addedToLibrary").map(Set.init) ?? []
        var failed = 0
        var problem: String?
        let jpgs = (fm.enumerator(at: new, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter(PhoneLibrary.isJPG)
        let todo = jpgs.filter { !added.contains($0.path) }
        if todo.isEmpty { photosLine = "" }
        for (n, url) in todo.enumerated() {
            photosLine = Words.t("Adding photos from Files to Photos: {0} of {1}", n + 1, todo.count)
            do {
                try await PhoneLibrary.add(url)
                added.insert(url.path)
                defaults.set(Array(added), forKey: "addedToLibrary")
            } catch {
                failed += 1
                problem = error.localizedDescription
            }
        }
        if failed > 0, let problem {
            photosLine = Words.t("{0} not added to Photos: {1}", failed, problem)
        } else {
            defaults.set(true, forKey: "movedToLibrary")
            defaults.removeObject(forKey: "addedToLibrary")
            if !jpgs.isEmpty { photosLine = Words.t("{0} photos from Files are now in Photos.", jpgs.count) }
        }
    }

    /// "Saving 341 of 3,630, about 12 min left", and the warning to connect
    /// to power when the battery would run out first.
    nonisolated public static func savingLine(done: Int, total: Int, left: TimeInterval?, battery: TimeInterval?) -> (line: String, warning: String?) {
        // Two fixed lines on the phone, so nothing below moves (0.29.28).
        let first = Words.t("Saving {0} of {1}", (done + 1).formatted(), total.formatted())
        return (first + "\n" + (left.map { Words.t("{0} left", Remaining.text($0)) } ?? " "), nil)
        var line = Words.t("Saving {0} of {1}", (done + 1).formatted(), total.formatted())
        guard let left else { return (line, nil) }
        line += Words.t(", {0} left", Remaining.text(left))
        guard let battery, battery < left else { return (line, nil) }
        let warning = Words.t("Connect to power: {0} of saving left, the battery has {1}.", Remaining.text(left), Remaining.text(battery))
        return (line + ". " + warning, warning)
    }

    public func stopSaving() {
        stopAsked = true
    }

    /// A line for the Photos page, with the way to what it says is missing.
    private func say(_ line: String, fix: PhotosFix?) {
        photosLine = line
        photosFix = fix
    }

    /// A line for the Photos page from one of its buttons.
    public func tell(_ line: String) {
        photosLine = line
    }

    /// A folder opened as a card that is not one (a NAS folder, before 0.34.14):
    /// no longer read, its photos off the page, its name off the list of cards.
    /// Silent: the clean-up of a bug (David: "no need to specify").
    public func forgetNotACard(id: String) {
        if source?.id == id, !saving {
            readingRound += 1
            source = nil
            forgetCard()
            photosLine = ""
        }
        var owners = defaults.dictionary(forKey: "cardPeople") as? [String: String] ?? [:]
        owners[id] = nil
        defaults.set(owners, forKey: "cardPeople")
        var names = defaults.dictionary(forKey: "cardNames") as? [String: String] ?? [:]
        names[id] = nil
        defaults.set(names, forKey: "cardNames")
        objectWillChange.send()
    }

    /// Once (0.34.14): every camera with no time offset is removed, most of them
    /// added from a folder that was not a card. A real one comes back with the
    /// next card that has its photos.
    func removeCamerasWithoutOffset() {
        guard !defaults.bool(forKey: "offsetlessCamerasRemoved") else { return }
        defaults.set(true, forKey: "offsetlessCamerasRemoved")
        let gone = book.people.flatMap { book.cameras(of: $0.id) }.filter { $0.offsetSeconds == nil }
        guard !gone.isEmpty else { return }
        store { book in for camera in gone { book.remove(camera: camera.id) } }
        rematch()
    }

    /// Settings opens on this camera's details, from the Photos page.
    @Published public var cameraToEdit: UUID?

    /// The fix offered beside the Photos line, taken.
    public func take(_ fix: PhotosFix) {
        switch fix {
        case .chooseWhose:
            if let source { askingWhose = source }
        case .chooseFolder(let id):
            _ = id
        case .trackService, .cameras:
            screen = .settings
        case .camera(let id):
            screen = .settings
            cameraToEdit = id
        case .openTailscale:
            Tailscale.open()
        }
    }

    /// "See photos on the map": dimmed when there is nothing to show
    /// (0.26.0, David, 6 November 2026), so it only ever opens the map.
    public func openMap() {
        guard canMap else { return }
        aligning = true
    }

    /// Something to show on the map: photos in the list, card in or out,
    /// placed by their own location or by their time along the tracks.
    public var canMap: Bool {
        let shown = mappable
        guard !shown.isEmpty else { return false }
        return !tracks.isEmpty || shown.contains { $0.photo.hasLocation }
    }

    /// Why Save photos is dimmed although there are photos to save, and the
    /// way to fix it: no save folder, or one that can't be found.
    public var saveBlock: (line: String, fix: PhotosFix)? {
        guard let personId = importPerson, let person = book.person(personId) else { return nil }
        guard let folder = saveFolder(of: person), !folder.isEmpty else {
            return (Words.t("{0} has no save folder yet.", person.name), .chooseFolder(personId))
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            return (Words.t("{0}'s save folder can't be found: {1}. If it is on a drive, plug the drive in, or choose another folder.", person.name, folder),
                    .chooseFolder(personId))
        }
        return nil
    }

    /// Save photos can do something now: a card in, whose it is known, a
    /// save folder there, and photos not saved yet.
    public var canSave: Bool {
        source != nil && importPerson != nil && engine != nil && saveBlock == nil && !readyToSave.isEmpty && !photosBusy && !saving
    }

    /// Where a photo is, for naming its folder: the track's position written
    /// into it, or its own; nil for one saved without a location.
    static func spot(_ item: SaveItem) -> (lat: Double, lon: Double)? {
        if let p = item.position { return (p.lat, p.lon) }
        if case .ownLocation = item.placement, let lat = item.photo.ownLat, let lon = item.photo.ownLon { return (lat, lon) }
        return nil
    }

    /// A card picked. One Squeaky has seen before is read straight away for
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

    public static let cardOut = Words.t("The card is out. Insert it again to save these photos.")

    /// Writes the list a second after it changes, so a save of thousands of
    /// photos writes it once a second, not once a photo.
    private func keepListSoon() {
        guard photoList != nil, keeping == nil else { return }
        keeping = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.keepList()
        }
    }

    /// The list as it stands now, written; an empty one removes the file.
    public func keepList() {
        keeping?.cancel()
        keeping = nil
        try? photoList?.save(KeptPhotoList(personId: importPerson, rows: rows, results: results))
    }

    /// The phone's card no longer answers while nothing is reading or saving it
    /// (0.29.37): let go of, the list and whose it is kept, as on the Mac.
    public func cardTakenOut() {
        guard let gone = source, !saving, !photosBusy else { return }
        readingRound += 1
        source = nil
        forgetCard()
        photosLine = Words.t("{0} was taken out.", gone.name)
    }

    /// The card's photos, counts and owner gone from the page once it is out:
    /// everything is read again when it goes back in (0.34.9, David).
    func forgetCard() {
        guard source == nil, !saving else { return }
        rows = []
        results = [:]
        importPerson = nil
        clearPlaces()
    }

    /// The card gone as if taken out, for the self-test: scratch cards have no disk.
    public func cardOutForTest() {
        readingRound += 1
        source = nil
    }

    /// Empties the Photos list once its card is out; the next card does it too.
    public func clearPhotos() {
        guard source == nil, !saving else { return }
        rows = []
        results = [:]
        importPerson = nil
        clearPlaces()
        photosLine = ""
    }

    /// The picture of a photo: from the card while it is in, else from the
    /// copy saved on this Mac; nil for a photo not saved once the card is out.
    public func pictureURL(_ row: ImportRow) -> URL? {
        source != nil ? row.photo.url : results[row.id]?.url
    }

    /// Stops reading, forces the card off now and says when it can come out.
    /// `done` is said after "can come out" once the card is off, in place of
    /// the usual line, and as a notification.
    /// The phone holds nothing to eject: the card is let go of and can come out.
    /// A card let go of is still plugged in: set here and by the phone's card watch (0.29.40).
    @Published public var cardStillIn = false {
        // A card let go of, now taken out: the page empties (0.34.9, David).
        didSet { if oldValue, !cardStillIn, source == nil { forgetCard() } }
    }

    public func letGo(done: String? = nil) {
        guard let card = source else { return }
        cardStillIn = true
        readingRound += 1
        askingWhose = nil
        aligning = false
        PhoneFolders.release(card.url)
        source = nil
        photosLine = Words.t("{0} can come out.", card.name) + (done.map { " \($0)" } ?? "")
    }

    public func eject(done: String? = nil) { letGo(done: done) }

    /// Whether a person's copies go to the server. On the phone, the photos
    /// from someone else's card stay on the phone (David, 15 November 2026).
    func goesToServer(_ personId: UUID) -> Bool {
        return personId != PhoneFolders.othersId
    }

    /// Where a person's copies are saved: the folder chosen in People on the
    /// Mac; on the iPhone, Squeaky's own folder for them, made when needed.
    public func saveFolder(of person: Person) -> String? {
        return PhoneFolders.saveFolder(for: person).path
    }

    /// Whoever this card belonged to last time.
    /// Every SD card Squeaky has read, with its name and who it belongs to (0.29.19).
    public struct KnownCard: Identifiable, Equatable {
        public var id: String
        public var name: String
        public var personId: UUID
    }

    public var knownCards: [KnownCard] {
        let owners = defaults.dictionary(forKey: "cardPeople") as? [String: String] ?? [:]
        let names = defaults.dictionary(forKey: "cardNames") as? [String: String] ?? [:]
        return owners.compactMap { id, person in
            guard let person = UUID(uuidString: person), book.person(person) != nil else { return nil }
            return KnownCard(id: id, name: names[id] ?? Words.t("Card"), personId: person)
        }.sorted { $0.name < $1.name }
    }


    /// Who a card belongs to, changed in Settings; the card in now is read again for them.
    public func setOwner(of card: String, to personId: UUID) {
        var owners = defaults.dictionary(forKey: "cardPeople") as? [String: String] ?? [:]
        owners[card] = personId.uuidString
        defaults.set(owners, forKey: "cardPeople")
        objectWillChange.send()
        if let source, source.id == card, !saving { Task { await read(source, for: personId) } }
    }

    /// The photos not saved, tried again (0.29.31, David, 17 November 2026):
    /// the card read again, so a photo this version can now handle (a HIF)
    /// is read afresh, then saved as Save photos would.
    public func tryUnsavedAgain() async {
        guard let source, let person = importPerson, !saving, !photosBusy else { return }
        await read(source, for: person, fresh: true)
        while photosBusy { try? await Task.sleep(for: .milliseconds(200)) }
        if !saving, trackCheck == nil, canSave { await checkTracksBeforeSave() }
    }

    /// The card now in, read again for whoever it belongs to.
    public func checkAgain() {
        guard let source, let person = importPerson, !saving, !photosBusy else { return }
        Task { await read(source, for: person) }
    }

    public func lastPerson(for source: PhotoSource) -> UUID? {
        let saved = defaults.dictionary(forKey: "cardPeople") as? [String: String] ?? [:]
        return saved[source.id].flatMap(UUID.init(uuidString:)).flatMap { id in book.person(id) != nil ? id : nil }
    }

    /// Where what was read from each card's photos is kept (0.34.12).
    private var cardReadFolder: URL {
        (peopleStore as? PeopleStoreFile)?.url.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Squeaky")
    }

    /// `fresh` reads every photo again, whatever was read from it before.
    public func read(_ source: PhotoSource, for personId: UUID, fresh: Bool = false) async {
        var saved = defaults.dictionary(forKey: "cardPeople") as? [String: String] ?? [:]
        saved[source.id] = personId.uuidString
        defaults.set(saved, forKey: "cardPeople")
        // The card's own name, for the list of SD cards in Settings (0.29.19).
        var names = defaults.dictionary(forKey: "cardNames") as? [String: String] ?? [:]
        names[source.id] = source.name
        defaults.set(names, forKey: "cardNames")
        askingWhose = nil
        importPerson = personId
        guard let engine else {
            photosLine = Words.t("ExifTool is missing from Squeaky.")
            return
        }
        readingRound += 1
        let round = readingRound
        photosBusy = true
        defer { photosBusy = false }
        photosLine = Words.t("Looking for photos")
        let url = source.url
        var files = await Task.detached { PhotoScanner.files(in: url) }.value
        // Every file on the card, before any are left out, so the memory of
        // what was read keeps the ones not read this time (0.34.12).
        let present = Set(files.map { CardReadMemory.place($0, root: url) })
        // Someone else's card: its JPGs only, the raws left on the card (0.29.5).
        // Its videos too, not its RAW videos (0.33.0).
        if personId == PhoneFolders.othersId { files = files.filter { ["jpg", "jpeg", "mp4", "mov"].contains($0.pathExtension.lowercased()) } }
        // Only the photos not read before are opened (0.34.12, David: "only 20
        // are new"); the rest come from what was read from them last time.
        let memory = CardReadMemory(folder: cardReadFolder, card: source.id)
        let allFiles = files
        let (known, toRead, stamps) = await Task.detached { memory.remembered(allFiles, root: url, ignoring: fresh) }.value
        guard readingRound == round else { return }
        files = toRead
        let total = files.count
        readProgress = (0, total)
        defer { readProgress = nil }
        photosLine = Words.t("Reading 0 of {0}", total)
        do {
            let justRead = try await Task.detached {
                let progress: @Sendable (Int) -> Void = { done in
                    Task { @MainActor [weak self] in
                        guard let self, self.readingRound == round else { return }
                        self.readProgress = (done, total)
                        self.photosLine = Words.t("Reading {0} of {1}", done, total)
                    }
                }
                switch engine {
                case .native: return NativeMetadata.scan(files, progress: progress)
                }
            }.value
            await Task.detached { memory.keep(justRead, stamps: stamps, root: url, present: present) }.value
            // Back in the card's order, remembered and newly read together.
            let readNow = Dictionary(justRead.map { (CardReadMemory.place($0.url, root: url), $0) }, uniquingKeysWith: { a, _ in a })
            let photos = allFiles.compactMap { f -> ScannedPhoto? in
                let place = CardReadMemory.place(f, root: url)
                return readNow[place] ?? known[place]
            }
            // The camera offsets set on the person's other devices, then what
            // any Mac or phone saved before, from the lists on the server.
            // HIF photos already added to Photos count as saved, on this phone only.
            let heif = Set(defaults.stringArray(forKey: "heifAdded") ?? [])
            // What the sync files held when last read, kept here: reading a card never
            // waits for the server (0.34.13, David: "don't block the flow by reading
            // it"). The list is kept up to date in the background, as Squeaky opens
            // and after each save. Only an empty copy, a phone starting afresh, is
            // read now, behind the photos, and their ticks follow when it comes.
            let copy = loadServerCopy(personId)
            savedListProblem = nil
            let restore = goesToServer(personId) && (copy?.entries.isEmpty ?? true)
            if let cameras = copy?.cameras { applyCameras(cameras, personId: personId) }
            let past = ((try? history.load(personId)) ?? []) + (copy?.entries ?? [])
            guard readingRound == round, self.source?.id == source.id else { return }
            addCameras(photos, personId: personId)
            var known = past
            known += photos.filter { heif.contains($0.key) }.map {
                HistoryEntry(fileName: $0.fileName, size: $0.size, taken: $0.taken, subSeconds: $0.subSeconds, imported: Date())
            }
            var listed = ImportList.rows(photos, history: known, book: book, personId: personId)
            // On the phone nothing is selected to start with: chosen by hand (0.31.3, David).
            for i in listed.indices { listed[i].ticked = false }
            rows = listed
            refreshBreaks()
            if restore { Task { await self.restoreSavedList(personId) } }
            Task { await chooseSidebarPhoto(photos) }
            noteFirmware(photos, personId: personId)
            noteLenses(photos, personId: personId)
            let codes = await readOffsetCodes(photos, personId: personId, round: round)
            guard readingRound == round, self.source?.id == source.id else { return }
            if rows.contains(where: { offsetCodeFrames.contains(Self.frameKey($0.photo)) }) {
                rows = rows.filter { !offsetCodeFrames.contains(Self.frameKey($0.photo)) }
            }
            photosLine = Words.t("Loading tracks")
            await loadTimeline()
            guard readingRound == round else { return }
            photosLine = Words.t("Matching photos to tracks")
            await Task.yield()
            rematch()
            photosLine = rows.isEmpty ? Words.t("No photos on {0}.", source.name) : codes
            // Every camera set: nothing to line up, so the photos are saved straight
            // away, and the card comes out once they are on the Mac (David, 1 November 2026).
            if camerasReady, saveWhenReady, saveBlock == nil {
                let ask = true
                if ask {
                    await checkTracksBeforeSave()
                } else {
                    await savePhotos()
                }
            } else if let block = saveBlock, readyToSave.count > 0 {
                // Save photos is dimmed until this is fixed: said on its own, with the way to it.
                say(block.line, fix: block.fix)
            }
        } catch {
            if readingRound == round { photosLine = Words.t("The photos could not be read: {0}", error.localizedDescription) }
        }
    }

    /// One photo per card inserted goes behind the sidebar; a card with no
    /// JPEG leaves the last one. The card is only read.
    public func chooseSidebarPhoto(_ photos: [ScannedPhoto]) async {
        guard let file = sidebarFile else { return }
        let kept: Bool = await Task.detached {
            guard let photo = SidebarPhoto.choose(photos) else { return false }
            return (try? SidebarPhoto.keep(photo, at: file)) != nil
        }.value
        if kept, let image = PlatformImage.load(file) { sidebarImage = image }
    }

    /// A card whose cameras are all set is saved as soon as it is read. Off
    /// only in the self-test, to name places before saving.
    public var saveWhenReady = true

    /// Every new photo's camera is on the list with its zone and offset set.
    public var camerasReady: Bool {
        guard let personId = importPerson else { return false }
        let fresh = rows.filter { $0.status != .alreadyImported }
        guard !fresh.isEmpty else { return false }
        return fresh.allSatisfy { row in
            row.photo.hasLocation || (row.photo.model.flatMap { book.camera(personId: personId, model: $0) }?.isReady ?? false)
        }
    }

    static func isJPG(_ photo: ScannedPhoto) -> Bool {
        ["jpg", "jpeg"].contains((photo.fileName as NSString).pathExtension.lowercased())
    }

    /// The town or area at a position, from OpenStreetMap, for showing; nil without an answer.
    public func placeName(lat: Double, lon: Double) async -> String? {
        if case .found(let name) = await places.place(lat: lat, lon: lon) { return name }
        return nil
    }

    /// The photos of the offset code found on cards read since Squeaky opened,
    /// by frame: left out of the list, so never shown, copied or sent (0.31.9).
    var offsetCodeFrames = Set<String>()
    /// "Offset updated for Canon EOS R5m2": shown inside Squeaky until closed (0.31.9).
    @Published public var offsetNotices: [String] = []

    /// A frame: its RAW and JPG together.
    static func frameKey(_ photo: ScannedPhoto) -> String {
        (photo.fileName as NSString).deletingPathExtension + "|" + (photo.taken ?? "") + (photo.subSeconds ?? "")
    }

    /// How many photos at each end of a camera's run are looked at for an offset code.
    static let codeEnds = 5

    /// Offset codes among the first and last photos of each camera on the
    /// card: each sets its camera's offset, to the hundredth, and adds a
    /// reading to its drift. Says what was set; empty when nothing was.
    func readOffsetCodes(_ photos: [ScannedPhoto], personId: UUID, round: Int? = nil) async -> String {
        var byModel: [String: [ScannedPhoto]] = [:]
        for photo in photos where photo.taken != nil {
            if let model = photo.model { byModel[model, default: []].append(photo) }
        }
        var candidates: [ScannedPhoto] = []
        for (_, list) in byModel {
            let sorted = list.sorted { (Moments.clockReading($0) ?? .distantPast) < (Moments.clockReading($1) ?? .distantPast) }
            // One file per frame: the JPG of a RAW+JPG pair, quicker to search (0.29.10).
            var frames: [String: ScannedPhoto] = [:]
            var order: [String] = []
            for photo in sorted {
                let frame = (photo.fileName as NSString).deletingPathExtension + "|" + (photo.taken ?? "") + (photo.subSeconds ?? "")
                if let known = frames[frame] {
                    if !Self.isJPG(known), Self.isJPG(photo) { frames[frame] = photo }
                } else {
                    frames[frame] = photo
                    order.append(frame)
                }
            }
            let each = order.compactMap { frames[$0] }
            candidates += each.count <= Self.codeEnds * 2 ? each : Array(each.prefix(Self.codeEnds) + each.suffix(Self.codeEnds))
        }
        // Each photo is looked at once (0.34.13, David): what it held is kept, so
        // a card with no new photos is not looked through again. A code found
        // before was added to its camera then; its photo is only left out again.
        let codeMemory = OffsetCodeMemory(folder: cardReadFolder)
        let looked = await Task.detached { codeMemory.load() }.value
        for photo in candidates where looked[photo.key] != nil {
            if case .some(.some) = looked[photo.key] { offsetCodeFrames.insert(Self.frameKey(photo)) }
        }
        let fresh = candidates.filter { looked[$0.key] == nil }
        var found: [(ScannedPhoto, Date)] = []
        var seen: [String: Double?] = [:]
        for (i, photo) in fresh.enumerated() {
            if let round, readingRound != round { break }
            photosLine = Words.t("Looking for offset codes: {0} of {1} photos", i + 1, fresh.count)
            let moment = await Task.detached(operation: { OffsetCode.find(in: photo.url) }).value
            seen[photo.key] = .some(moment?.timeIntervalSince1970)
            if let moment { found.append((photo, moment)) }
        }
        let toKeep = seen
        await Task.detached { codeMemory.add(toKeep) }.value
        if let round, readingRound != round { return "" }
        var said: [String] = []
        var updated: [String] = []
        for (photo, moment) in found {
            // The photo of the code is left out: never shown, copied or sent (0.31.9, David).
            offsetCodeFrames.insert(Self.frameKey(photo))
            guard let model = photo.model, var camera = book.camera(personId: personId, model: model),
                  let offset = Moments.exactOffset(placing: photo, camera: camera, at: moment) else { continue }
            let known = camera.readings.contains { abs($0.at.timeIntervalSince(moment)) < 60 && abs($0.offset - offset) < 0.005 }
            camera.add(ClockReading(at: moment, offset: offset))
            save(camera)
            said.append(Words.t("{0}: clock {1}, set from the offset code.", camera.model, OffsetText.exact(offset)))
            if !known, !updated.contains(camera.model) { updated.append(camera.model) }
        }
        // Said inside Squeaky until closed, only when the record changed (0.31.9, David).
        for model in updated {
            let line = Words.t("Offset updated for {0}", model)
            if !offsetNotices.contains(line) { offsetNotices.append(line) }
        }
        return said.joined(separator: " ")
    }

    /// The temperature each camera recorded, a photo every quarter of an hour
    /// or so, with where it was taken when known.

    /// A week after a camera's last offset code photo, and each week after,
    /// one notification to take another (David, 1 November 2026).
    public func remindClocks(now: Date = Date()) {
        var reminded = defaults.dictionary(forKey: "clockReminders") as? [String: Double] ?? [:]
        for camera in book.cameras {
            guard let lastReading = camera.readings.last?.at else { continue }
            let since = max(lastReading.timeIntervalSince1970, reminded[camera.id.uuidString] ?? 0)
            guard now.timeIntervalSince1970 - since >= 7 * 86_400 else { continue }
            let owner = book.person(camera.personId).map { "\($0.name)'s " } ?? ""
            notifier.post(Words.t("Time to photograph the offset code with {0}{1}.", owner, camera.model), kind: "clock-\(camera.id.uuidString)")
            reminded[camera.id.uuidString] = now.timeIntervalSince1970
        }
        defaults.set(reminded, forKey: "clockReminders")
    }

    /// Photos selected or not for saving, as one change to the list: the
    /// phone's ticks, taps and slides (0.31.0, David, 18 November 2026).
    public func setTicked(_ ids: Set<String>, _ on: Bool) {
        guard !saving, !ids.isEmpty else { return }
        var changed = rows
        var any = false
        for i in changed.indices where ids.contains(changed[i].id) && changed[i].ticked != on {
            changed[i].ticked = on
            any = true
        }
        if any { rows = changed }
    }

    /// Saved now, or imported on an earlier card.
    /// Every photo known to be copied for this person, by any device: this
    /// device's own record, the sync lists kept here (from the NAS and the
    /// buffer server), and on the phone the HIF photos added to Photos.
    func alreadyCopied(_ personId: UUID) -> Set<String> {
        var keys = Set(((try? history.load(personId)) ?? []).map(\.key))
        keys.formUnion((loadServerCopy(personId)?.entries ?? []).map(\.key))
        let heif = Set(defaults.stringArray(forKey: "heifAdded") ?? [])
        keys.formUnion(rows.map(\.photo).filter { heif.contains($0.key) }.map(\.key))
        return keys
    }

    public func isSaved(_ row: ImportRow) -> Bool {
        if let result = results[row.id] { return result.url != nil }
        return row.status == .alreadyImported
    }

    /// Deletes these files from the card, and their rows (0.34.2, David: the
    /// only thing Squeaky changes on a card). Copies already saved stay.
    /// Nil when done; else why not, with what was deleted gone from the list.
    public func deleteFromCard(_ ids: Set<String>) -> String? {
        guard let source, !saving, !ids.isEmpty else { return Words.t("The card is not open.") }
        var gone = Set<String>()
        var problem: String?
        for row in rows where ids.contains(row.id) && row.photo.url.path.hasPrefix(source.url.path) {
            do {
                try FileManager.default.removeItem(at: row.photo.url)
                gone.insert(row.id)
            } catch {
                problem = Words.t("{0} could not be deleted from the card: {1}", row.photo.fileName, error.localizedDescription)
            }
        }
        if !gone.isEmpty {
            rows.removeAll { gone.contains($0.id) }
            for id in gone { results[id] = nil }
            keepList()
        }
        return problem
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

    /// A clock out by this much or more is wrong, not drifting: the copies'
    /// dates are corrected (a setting; David, 18 October 2026).
    public func setClockFixMinutes(_ minutes: Int) {
        clockFixMinutes = min(max(minutes, 1), 10_080)
        defaults.set(clockFixMinutes, forKey: "clockFixMinutes")
    }

    /// Seconds to move a photo's dates by: the camera's error, when its clock
    /// is out by at least the setting; else 0, and the photo's dates stay.
    public func dateShift(_ photo: ScannedPhoto, personId: UUID) -> Int {
        guard let offset = photo.model.flatMap({ book.camera(personId: personId, model: $0) })?.offsetSeconds,
              abs(offset) >= clockFixMinutes * 60 else { return 0 }
        return -offset
    }

    /// The cameras on this card whose clocks are far out, and by how much.
    public var wrongClocks: [(camera: Camera, offset: Int)] {
        guard let personId = importPerson else { return [] }
        var seen = Set<UUID>()
        var out: [(Camera, Int)] = []
        for row in rows {
            guard let camera = row.photo.model.flatMap({ book.camera(personId: personId, model: $0) }), !seen.contains(camera.id),
                  let offset = camera.offsetSeconds, abs(offset) >= clockFixMinutes * 60 else { continue }
            seen.insert(camera.id)
            out.append((camera, offset))
        }
        return out
    }

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

    /// Every photo on the card placed again: after a card is read, a camera
    /// changes, the gap changes, or new tracks arrive. Photos saved earlier
    /// are not: only held ones, and a track card's Recheck (0.27.0).
    public func rematch() {
        guard let personId = importPerson, !rows.isEmpty else { return }
        // One change to the list, not one per photo (see savePhotos).
        var placed = rows
        for i in placed.indices {
            let photo = placed[i].photo
            let camera = photo.model.flatMap { book.camera(personId: personId, model: $0) }
            placed[i].placement = Matcher.place(photo, camera: camera, timeline: timeline, gap: maxGapSeconds)
        }
        rows = placed
        // Placed photos may have moved: their places are asked again.
        Task { await lookUpRowPlaces() }
    }

    // MARK: Firmware

    /// Each camera's newest software version on this card, kept with the day
    /// of the latest photo that showed it (David, 18 October 2026).
    func noteFirmware(_ photos: [ScannedPhoto], personId: UUID) {
        var newest: [UUID: (version: String, seen: Date?)] = [:]
        for photo in photos {
            guard let version = photo.firmware, let model = photo.model,
                  let camera = book.camera(personId: personId, model: model) else { continue }
            let seen = Moments.clockReading(photo)
            if let known = newest[camera.id] {
                let later = (seen ?? .distantPast) > (known.seen ?? .distantPast)
                if Firmware.isNewer(version, than: known.version) || (version == known.version && later) {
                    newest[camera.id] = (version, seen)
                }
            } else {
                newest[camera.id] = (version, seen)
            }
        }
        var changed: [Camera] = []
        for (id, found) in newest {
            guard var camera = book.cameras.first(where: { $0.id == id }) else { continue }
            let kept = camera.firmware
            let newer = kept.map { Firmware.isNewer(found.version, than: $0) } ?? true
            let sameLater = kept == found.version && (found.seen ?? .distantPast) > (camera.firmwareSeen ?? .distantPast)
            guard newer || sameLater else { continue }
            camera.firmware = found.version
            camera.firmwareSeen = found.seen
            changed.append(camera)
        }
        if !changed.isEmpty { store { book in changed.forEach { book.save($0) } } }
    }

    /// Every lens the card's photos name, with the camera it was on and the
    /// day of its latest photo (David, 18 October 2026).
    func noteLenses(_ photos: [ScannedPhoto], personId: UUID) {
        let next = Lenses.noting(photos, personId: personId, into: book.lenses)
        if next != book.lenses { store { $0.lenses = next } }
    }

    /// A lens's firmware version as typed in, kept with the day it was typed;
    /// an empty one takes it away. The same version again changes nothing.
    public func setFirmware(_ text: String, lens id: String) {
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = book.lenses.firstIndex(where: { $0.id == id }),
              book.lenses[i].firmware != (version.isEmpty ? nil : version) else { return }
        store {
            $0.lenses[i].firmware = version.isEmpty ? nil : version
            $0.lenses[i].firmwareSet = version.isEmpty ? nil : Date()
        }
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

    /// Photos saved earlier without a location, tried again against the
    /// tracks: those in `paths`, or those taken `within` a track's time, or
    /// all. Each that can now be placed gets the location written into its
    /// copy on this Mac, checked like any save, and goes on the upload queue
    /// again. Nil when it could not run; else how many were placed of how
    /// many tried.
    @discardableResult
    public func placeLater(paths: Set<String>? = nil, within: ClosedRange<Date>? = nil) async -> (placed: Int, tried: Int)? {
        guard !placingLater, !saving, let engine else { return nil }
        let entries = (try? unplaced.load()) ?? []
        guard !entries.isEmpty else { return (0, 0) }
        placingLater = true
        defer { placingLater = false }
        await loadTimeline()
        var keep: [UnplacedEntry] = []
        var placed = 0, tried = 0
        var problems: [String] = []
        for entry in entries {
            // Moved or removed since, by its owner or after 30 days on the NAS: nothing to place.
            guard FileManager.default.fileExists(atPath: entry.localPath) else { continue }
            let camera = entry.model.flatMap { book.camera(personId: entry.personId, model: $0) }
            let wanted: Bool
            if let paths {
                wanted = paths.contains(entry.localPath)
            } else if let within {
                wanted = (try? Moments.moment(entry.photo, camera: camera).get()).map { within.contains($0) } ?? false
            } else {
                wanted = true
            }
            guard wanted else {
                keep.append(entry)
                continue
            }
            tried += 1
            guard case .matched(let position) = Matcher.place(entry.photo, camera: camera, timeline: timeline, gap: maxGapSeconds) else {
                keep.append(entry)
                continue
            }
            let url = URL(fileURLWithPath: entry.localPath)
            let saver = Saver(engine: engine, folder: url.deletingLastPathComponent().deletingLastPathComponent())
            // Dates still to correct: what the camera's error now calls for, less what was done at saving.
            let shift = dateShift(entry.photo, personId: entry.personId) - entry.shifted
            if let problem = await Task.detached(operation: { saver.addLocation(to: url, position, shift: shift) }).value {
                problems.append("\(entry.fileName): \(problem)")
                keep.append(entry)
                continue
            }
            placed += 1
            guard goesToServer(entry.personId) else { continue }
            changeQueue { all in
                // Not sent yet: what goes is the copy as it is now. Sent, or on
                // its way: it goes again and replaces Squeaky's earlier copy.
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
        guard placed > 0 || !problems.isEmpty, !photosBusy, !saving else { return (placed, tried) }
        var line = placed == 0 ? "" : placed == 1 ? Words.t("1 photo saved earlier now has its location.") : Words.t("{0} photos saved earlier now have their location.", placed)
        if let first = problems.first { line += (line.isEmpty ? "" : " ") + Words.t("Not placed: {0}", first) }
        photosLine = line
        return (placed, tried)
    }

    // MARK: Checking for tracks before saving (0.27.0, David, 12 November 2026)

    /// Photos on the card that would be saved without a location for want of a track.
    public var noTrackCount: Int {
        readyToSave.filter { $0.placement == .review(.noTrack) }.count
    }

    /// The tracks loaded again from the track service; the card is saved at
    /// once if every photo then has its track, else the choice is laid over
    /// the window and nothing is saved until one is made.
    public func checkTracksBeforeSave() async {
        trackCheck = .checking
        while tracksBusy { try? await Task.sleep(for: .milliseconds(200)) }
        let answered = await refresh(pullStrava: true)
        guard trackCheck != nil else { return }
        let missing = noTrackCount
        if missing == 0 {
            // The phone shows the latest track before every save (0.29.5, David, 16 November 2026).
            trackCheck = .ready
        } else {
            trackCheck = answered ? .noTrack(missing) : .offline(missing)
        }
    }

    public func dontSave() {
        trackCheck = nil
    }

    public func checkTracksAgain() {
        Task { await checkTracksBeforeSave() }
    }

    /// Saved as they are. With the track service away, those without a track
    /// stay on this Mac until the tracks can be checked again.
    /// The selected photos that have a track, saved; those without stay selected (0.34.5, David).
    public func saveOnlyTracked() {
        trackCheck = nil
        let ids = Set(readyToSave.filter { $0.placement != .review(.noTrack) }.map(\.id))
        Task { await savePhotos(only: ids) }
    }

    public func saveAnyway() {
        let hold: Bool
        if case .offline? = trackCheck { hold = true } else { hold = false }
        trackCheck = nil
        Task { await savePhotos(hold: hold) }
    }

    /// Photos held for want of the track service: once it answers, tried
    /// once against the tracks, then let go to the NAS, placed or not.
    public func releaseHeld() async {
        let held = Set(queueEntries.filter(\.held).map(\.localPath))
        guard !held.isEmpty else { return }
        while placingLater || saving { try? await Task.sleep(for: .milliseconds(200)) }
        await placeLater(paths: held)
        changeQueue { all in
            for i in all.indices where all[i].held { all[i].held = false }
        }
    }

    /// A track card's Recheck: photos saved without a location and taken
    /// during the track, placed where they now can be.
    public func recheckPhotos(for track: Track) async {
        guard !tracksBusy, !saving, !placingLater else { return }
        guard let done = await placeLater(within: track.start...track.end) else { return }
        tracksLine = done.tried == 0 ? Words.t("No photos without a location from {0}.", track.name)
            : Words.t("{0} of {1} photos from {2} now have their location.", done.placed, done.tried, track.name)
    }

    /// The photos the map can show: those with a location of their own, and
    /// those whose camera is known with its zone, placed by their time.
    public var mappable: [ImportRow] {
        guard let personId = importPerson else { return [] }
        return rows.filter { row in
            if row.photo.hasLocation, row.photo.ownLat != nil, row.photo.ownLon != nil { return true }
            guard row.photo.taken != nil, let model = row.photo.model,
                  let camera = book.camera(personId: personId, model: model) else { return false }
            return camera.zone != .notSet
        }
    }

    // MARK: The NAS

    /// "2027.01.12/IMG_0001.jpg": a saved copy's place under its person's folder.
    static func relative(_ url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        // A burst's folder sits inside its day folder (0.29.6).
        if folder.lastPathComponent.hasPrefix("burst_") {
            return "\(folder.deletingLastPathComponent().lastPathComponent)/\(folder.lastPathComponent)/\(url.lastPathComponent)"
        }
        return "\(folder.lastPathComponent)/\(url.lastPathComponent)"
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
        // Photos added or gone while one goes up: the line keeps up.
        if sendingThrough != nil, meter.count > 0 { sayGoing() }
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

    // MARK: The list of photos saved, on the server (0.29.0, David, 16 November 2026)

    /// This Mac or phone, for its own list on the server.
    var deviceId: String {
        if let id = defaults.string(forKey: "deviceId") { return id }
        let id = "iphone-" + UUID().uuidString
        defaults.set(id, forKey: "deviceId")
        return id
    }

    /// The person's folder on the server, open; nil when it has none or cannot be had.
    private func serverFolder(_ personId: UUID) async -> URL? {
        try? await openServerFolder(personId).get()
    }

    /// The person's folder on the server, or why not, in words to show
    /// (0.29.11, David: "dont fail silently").
    private func openServerFolder(_ personId: UUID) async -> Result<URL, NASError> {
        guard goesToServer(personId), let place = NASFolder(book.person(personId)?.nasFolder) else {
            return .failure(.failed(Words.t("No NAS folder chosen.")))
        }
        // Known not to answer just now: no wait for it while a card is read.
        guard nasReach != .unreachable else { return .failure(.offline(Words.t("The NAS isn't answering."))) }
        let port = nas
        let outcome = await withTaskGroup(of: Result<NASConnection, NASError>?.self) { group in
            group.addTask {
                do {
                    return .success(try await port.connect(share: place.share))
                } catch {
                    return .failure(error as? NASError ?? .failed(error.localizedDescription))
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(15)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(.offline(Words.t("No answer from the NAS within 15 seconds.")))
        }
        switch outcome {
        case .success(let connection):
            if connection.ours { ourMounts[connection.folder.path] = connection }
            return .success(place.folder(in: connection.folder))
        case .failure(let why):
            return .failure(why)
        }
    }

    /// Why the list of photos already saved could not be read for the card now
    /// read; shown before saving, since photos saved elsewhere may then be saved again.
    @Published public private(set) var savedListProblem: String?

    /// Said on the sync line: "Sync file not saved:" and why.
    private func syncFailed(_ why: String) {
        sharedProblem = why
    }

    /// The photos any device saved for this person, as listed on the server.
    public func serverHistory(_ personId: UUID) async -> [HistoryEntry] {
        if case .success(let folder) = await openServerFolder(personId), let problem = await refreshServerCopy(personId, folder: folder) {
            syncFailed(problem)
        }
        return loadServerCopy(personId)?.entries ?? []
    }


    /// This device's list of photos saved for a person, put on the server.
    public func publishHistory(_ personId: UUID) async {
        await shareWithServer()
    }


    /// Everyone's lists, as Squeaky opens: the photos saved before this
    /// version count on the other devices straight away.
    func publishAllHistory() async {
        await shareWithServer()
    }

    /// When the lists were last written to the server, and why not, when the
    /// last try failed: shown on the Queue page (0.29.2, David, 16 November 2026).
    @Published public private(set) var sharedAt: Date?
    @Published public private(set) var sharedProblem: String?
    /// What is being done with the sync files right now, said in place of the sync line (0.29.16).
    @Published public private(set) var syncActivity: String?
    /// Who wrote into the server folder last, and when, any device (0.29.3);
    /// remembered between launches (0.29.10).
    @Published public private(set) var lastSave: ServerList.LastSave? = {
        let d = UserDefaults.standard
        guard let at = d.object(forKey: "lastSaveAt") as? Date else { return nil }
        return ServerList.LastSave(byPhone: d.bool(forKey: "lastSaveByPhone"), at: at, count: d.integer(forKey: "lastSaveCount"))
    }() {
        didSet {
            guard let lastSave else { return }
            UserDefaults.standard.set(lastSave.at, forKey: "lastSaveAt")
            UserDefaults.standard.set(lastSave.byPhone, forKey: "lastSaveByPhone")
            UserDefaults.standard.set(lastSave.count, forKey: "lastSaveCount")
        }
    }


    private var sharing = false

    /// Every person's lists, read and written: as Squeaky opens, whenever the
    /// server answers and they were not written since, and after each batch sent.
    /// A phone with no copy of the list of saved photos (deleted and installed
    /// again, or new) reads it from the buffer server, else the NAS, behind the
    /// card's photos (0.34.13): the list is the backup of what was saved.
    func restoreSavedList(_ personId: UUID) async {
        if bufferClient != nil { _ = await syncThroughBuffer(personId) }
        if loadServerCopy(personId)?.entries.isEmpty ?? true, NASFolder(book.person(personId)?.nasFolder) != nil {
            switch await openServerFolder(personId) {
            case .success(let folder):
                await Task.detached { ServerList.moveFromHidden(in: folder) }.value
                if let problem = await refreshServerCopy(personId, folder: folder) { savedListProblem = problem }
                if loadServerCopy(personId)?.entries.isEmpty ?? true { savedListProblem = savedListProblem ?? Words.t("No sync files found on the server.") }
            case .failure(let why):
                savedListProblem = why.localizedDescription
            }
        }
        applySavedList(personId)
    }

    /// Photos on the card now on the list of saved photos get their tick
    /// (0.34.13): the list may come in after the card's photos are shown.
    func applySavedList(_ personId: UUID) {
        guard importPerson == personId, !rows.isEmpty, !saving else { return }
        let keys = Set((((try? history.load(personId)) ?? []) + (loadServerCopy(personId)?.entries ?? [])).map(\.key))
        var changed = rows
        var any = false
        for i in changed.indices where results[changed[i].id] == nil && changed[i].status != .alreadyImported && keys.contains(changed[i].photo.key) {
            changed[i].status = .alreadyImported
            changed[i].ticked = false
            any = true
        }
        if any { rows = changed }
    }

    public func shareWithServer() async {
        guard !sharing else { return }
        let people = book.people.filter { goesToServer($0.id) && NASFolder($0.nasFolder) != nil }
        guard !people.isEmpty else { return }
        sharing = true
        defer { sharing = false }
        // Whatever the list brought, the card's photos on it get their tick (0.34.13).
        defer { if let person = importPerson { applySavedList(person) } }
        var problem: String?
        // The buffer server first: quick from anywhere (0.31.8). Reached, it
        // stands for the sync even while the NAS can't be.
        var bufferSynced = false
        if bufferClient != nil {
            syncActivity = Words.t("Reading the sync list from the buffer server")
            var failed: String?
            for person in people { if let why = await syncThroughBuffer(person.id) { failed = why } }
            syncActivity = nil
            bufferSynced = failed == nil
        }
        for person in people {
            // Reaching the NAS can take seconds: said, with the wheel (0.29.26).
            syncActivity = Words.t("Reaching the NAS")
            let folder: URL
            switch await openServerFolder(person.id) {
            case .success(let found): folder = found
            case .failure(let why):
                syncActivity = nil
                problem = why.localizedDescription
                continue
            }
            await Task.detached { ServerList.moveFromHidden(in: folder) }.value
            // One list per person, merged and written back (0.29.27, David: "i want a synced list").
            let (readProblem, shared) = await readAndKeep(person.id, folder: folder)
            if let readProblem { problem = readProblem }
            guard let shared else { continue }
            let own = (try? history.load(person.id)) ?? []
            let ownCameras = book.cameras(of: person.id).filter { $0.offsetSeconds != nil }
            // What the buffer server's list added is passed on to the NAS too.
            let kept = loadServerCopy(person.id)
            let entries = ServerList.union(ServerList.union(shared.allEntries, own), kept?.entries ?? [])
            let cameras = ServerList.newest(shared.allCameras + ownCameras + (kept?.cameras ?? []))
            let camerasBefore = shared.cameras?.cameras.map { "\($0.model)=\($0.offsetDate.timeIntervalSince1970)" }.sorted() ?? []
            let camerasAfter = cameras.map { "\($0.model)=\($0.offsetDate.timeIntervalSince1970)" }.sorted()
            // Written only when something is new: an entry or an offset not yet listed, or old files to fold in.
            guard entries.count != (shared.saved?.entries.count ?? -1) || camerasBefore != camerasAfter || !shared.oldFiles.isEmpty else {
                syncActivity = nil
                continue
            }
            syncActivity = Words.t("Saving the sync list to the NAS")
            let now = Date()
            let by = Self.deviceKind
            let oldFiles = shared.oldFiles
            // Given up after 30 seconds rather than hanging (0.29.18).
            let failure: String? = await withTaskGroup(of: String??.self) { group in
                group.addTask {
                    await Task.detached { () -> String? in
                        do {
                            try ServerList.writeShared(.init(entries: entries, updatedAt: now, updatedBy: by),
                                                       .init(cameras: cameras, updatedAt: now, updatedBy: by), into: folder)
                            ServerList.removeOld(oldFiles, in: folder)
                            return nil
                        } catch {
                            return error.localizedDescription
                        }
                    }.value
                }
                group.addTask { try? await Task.sleep(for: .seconds(30)); return .some(Words.t("no answer within 30 seconds.")) }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? nil
            }
            syncActivity = nil
            if let failure {
                problem = Words.t("it couldn't be written:") + " " + failure
            } else if person.id == linePerson {
                lastSave = ServerList.LastSave(byPhone: by == "iphone", at: now, count: entries.count)
            }
        }
        syncActivity = nil
        // No sync file seen at all, not even this device's own: a problem, said (0.29.23).
        if problem == nil, lastSave == nil { problem = Words.t("No sync files found on the server.") }
        if bufferSynced { problem = nil }
        if let problem {
            sharedProblem = problem
        } else {
            sharedAt = Date()
            sharedProblem = nil
        }
    }

    /// This device's cameras for a person, with their offsets, put on the server.
    public func publishCameras(_ personId: UUID) async {
        await shareWithServer()
    }


    /// Offsets set more recently on another device taken here; a camera
    /// another device knows and this one not yet, added.
    public func pullCameras(_ personId: UUID) async {
        guard case .success(let folder) = await openServerFolder(personId) else { return }
        _ = await refreshServerCopy(personId, folder: folder)
    }

    // MARK: The server's sync files, kept here (0.29.12, David: "whats the point of having
    // it locally if it's going to check the server everytime")

    /// What the sync files on the server held when last read: every device's
    /// photos saved and the newest offset of each camera.
    struct ServerCopy: Codable {
        var entries: [HistoryEntry]
        var cameras: [Camera]
    }

    private func copyFile(_ personId: UUID) -> URL {
        let folder = (peopleStore as? PeopleStoreFile)?.url.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Squeaky")
        return folder.appendingPathComponent("servercopy-\(personId.uuidString).json")
    }

    /// What is kept here, with these entries and offsets added; written back and returned.
    @discardableResult
    func keepServerCopy(_ personId: UUID, entries: [HistoryEntry], cameras: [Camera]) -> ServerCopy {
        let before = loadServerCopy(personId)
        let copy = ServerCopy(entries: ServerList.union(before?.entries ?? [], entries),
                              cameras: ServerList.newest((before?.cameras ?? []) + cameras))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(copy) {
            try? FileManager.default.createDirectory(at: copyFile(personId).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: copyFile(personId), options: .atomic)
        }
        return copy
    }

    /// The person's lists at the buffer server (0.31.8, David, 18 November 2026:
    /// a phone away from home did not know what was copied): read, added to what
    /// is kept here, and written back with what this device knows when something
    /// is new. Nil when it went well or there is no buffer server; else why not.
    @discardableResult
    func syncThroughBuffer(_ personId: UUID) async -> String? {
        guard goesToServer(personId), let client = bufferClient,
              let base = bufferBase(book.person(personId)?.nasFolder), !base.isEmpty else { return nil }
        let folder = base.split(separator: "/").joined(separator: "/") + "/" + ServerList.folderName + "/"
        let savedPath = folder + "saved.json", camerasPath = folder + "cameras.json"
        let theirs: ServerList.SavedFile?
        let theirCameras: ServerList.CamerasFile?
        do {
            theirs = try await client.readList(savedPath).map(ServerList.decodeSaved)
            theirCameras = try await client.readList(camerasPath).map(ServerList.decodeCameras)
        } catch {
            return error.localizedDescription
        }
        let copy = keepServerCopy(personId, entries: theirs?.entries ?? [], cameras: theirCameras?.cameras ?? [])
        applyCameras(copy.cameras, personId: personId)
        let own = (try? history.load(personId)) ?? []
        let entries = ServerList.union(copy.entries, own)
        let cameras = ServerList.newest(copy.cameras + book.cameras(of: personId).filter { $0.offsetSeconds != nil })
        func stamp(_ list: [Camera]) -> [String] { list.map { "\($0.model)=\($0.offsetDate.timeIntervalSince1970)" }.sorted() }
        if personId == linePerson, let theirs, theirs.updatedAt > (lastSave?.at ?? .distantPast) {
            lastSave = ServerList.LastSave(byPhone: theirs.updatedBy == "iphone", at: theirs.updatedAt, count: theirs.entries.count)
        }
        guard entries.count != (theirs?.entries.count ?? -1) || stamp(cameras) != stamp(theirCameras?.cameras ?? []) else { return nil }
        let now = Date()
        do {
            try await client.writeList(savedPath, ServerList.encode(.init(entries: entries, updatedAt: now, updatedBy: Self.deviceKind)))
            try await client.writeList(camerasPath, ServerList.encode(.init(cameras: cameras, updatedAt: now, updatedBy: Self.deviceKind)))
        } catch {
            return error.localizedDescription
        }
        keepServerCopy(personId, entries: entries, cameras: cameras)
        if personId == linePerson {
            lastSave = ServerList.LastSave(byPhone: Self.deviceKind == "iphone", at: now, count: entries.count)
        }
        return nil
    }

    func loadServerCopy(_ personId: UUID) -> ServerCopy? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? Data(contentsOf: copyFile(personId))).flatMap { try? decoder.decode(ServerCopy.self, from: $0) }
    }

    /// Both sync files read in one visit, kept here, the offsets taken; nil
    /// when all went well, else why not.
    func refreshServerCopy(_ personId: UUID, folder: URL) async -> String? {
        await readAndKeep(personId, folder: folder).0
    }

    /// The person whose list the sync line reports: the phone's, or this Mac's owner, or the first.
    var linePerson: UUID? {
        macOwner ?? book.people.first(where: { goesToServer($0.id) && NASFolder($0.nasFolder) != nil })?.id
    }

    static var deviceKind: String {
        return "iphone"
    }

    /// The person's list read in one visit, within 30 seconds, kept here, the
    /// offsets taken; why not, when it could not be read.
    func readAndKeep(_ personId: UUID, folder: URL) async -> (String?, ServerList.Shared?) {
        syncActivity = Words.t("Reading the sync list")
        let shared = await withTaskGroup(of: ServerList.Shared?.self) { group in
            group.addTask { await Task.detached { ServerList.readShared(from: folder) }.value }
            group.addTask { try? await Task.sleep(for: .seconds(30)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        syncActivity = nil
        guard let shared else { return (Words.t("reading the sync files took more than 30 seconds: {0}", ServerList.folderName), nil) }
        // Added to what is kept here, never in place of it: the buffer server's
        // list may know photos the NAS has not heard of yet (0.31.8).
        let copy = keepServerCopy(personId, entries: shared.allEntries, cameras: shared.allCameras)
        applyCameras(copy.cameras, personId: personId)
        if personId == linePerson, let saved = shared.saved {
            lastSave = ServerList.LastSave(byPhone: saved.updatedBy == "iphone", at: saved.updatedAt, count: saved.entries.count)
            sharedProblem = nil
        }
        return (shared.problem.map { Words.t("the other devices' sync files couldn't be read:") + " " + $0 }, shared)
    }


    /// Offsets set more recently on another device taken here; a camera
    /// another device knows and this one not yet, added.
    func applyCameras(_ shared: [Camera], personId: UUID) {
        var taken = false
        var next = book
        for theirs in shared {
            if var mine = next.camera(personId: personId, model: theirs.model) {
                guard mine.offsetSeconds == nil || theirs.offsetDate > mine.offsetDate else { continue }
                mine.offsetSeconds = theirs.offsetSeconds
                mine.readings = theirs.readings
                mine.offsetSet = theirs.offsetDate
                if mine.zone == .notSet { mine.zone = theirs.zone }
                next.save(mine)
            } else {
                var added = Camera(personId: personId, model: theirs.model, zone: theirs.zone, offsetSeconds: theirs.offsetSeconds)
                added.readings = theirs.readings
                added.offsetSet = theirs.offsetDate
                next.save(added)
            }
            taken = true
        }
        guard taken else { return }
        store { $0 = next }
        rematch()
    }


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
        await testNAS(saying: Words.t("Saved. "))
    }

    /// Opens the shared folder of every NAS folder in People with the settings
    /// on screen, saved or not, and says how it went.
    public func testNAS(saying prefix: String = "") async {
        let shares = Set(book.people.compactMap { NASFolder($0.nasFolder)?.share }).sorted()
        guard !shares.isEmpty else {
            nasLine = prefix + Words.t("Nobody has a NAS folder yet. Choose one in People.")
            return
        }
        nasBusy = true
        defer { nasBusy = false }
        nasLine = prefix + Words.t("Checking the NAS")
        let port = nasPort ?? nasFields.port
        var lines: [String] = []
        var answered = false
        for share in shares {
            do {
                let connection = try await port.connect(share: share)
                if connection.ours { ourMounts[connection.folder.path] = connection }
                nasReach = .through(connection.address)
                answered = true
                let host = Self.host(connection.address)
                lines.append(shares.count == 1 ? Words.t("Connected through {0}.", host) : Words.t("{0}: connected through {1}.", share, host))
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
        if sent > 0 { parts.append(sent == 1 ? Words.t("1 photo is on the NAS.") : Words.t("{0} photos are on the NAS.", sent.formatted())) }
        if failed > 0 {
            if sent > 0 {
                parts.append(failed == 1 ? Words.t("1 was not sent.") : Words.t("{0} were not sent.", failed.formatted()))
            } else {
                parts.append(failed == 1 ? Words.t("1 photo was not sent.") : Words.t("{0} photos were not sent.", failed.formatted()))
            }
        }
        return parts.joined(separator: " ")
    }

    /// Whether the NAS answers now, for the NAS box on the Queue page: asked
    /// as Squeaky opens and whenever the Queue page is shown, with the saved
    /// settings. Every shared folder in People must answer.
    public func checkNAS() async {
        guard !checkingNAS else { return }
        // Photos going up: the box names the address they go through.
        if let address = sendingThrough {
            if nasReach != .through(address) { nasReach = .through(address) }
            return
        }
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
                // Opened only to ask: closed again with Squeaky's other openings once nothing is waiting.
                if connection.ours { ourMounts[connection.folder.path] = connection }
                answered = .through(connection.address)
            } catch {
                answered = .unreachable
                break
            }
        }
        let wasAway = nasReach == .unreachable
        if nasReach != answered { nasReach = answered }
        // The server answers and the lists were not written since Squeaky opened.
        // The server answers, and the files were not read since Squeaky opened, or it was away.
        if case .through = answered, sharedAt == nil || wasAway { Task { await shareWithServer() } }
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
        if on, sendRoute == .buffer { bufferUploads.cancelAll() }
        if on {
            say(meter.count == 0 ? Words.t("Paused.") : meter.count == 1 ? Words.t("Pausing after this photo.") : Words.t("Pausing after these {0} photos.", meter.count))
        } else {
            nextTry = nil
            say("")
        }
    }

    public func setSendAtOnce(_ count: Int) {
        sendAtOnce = min(max(count, 1), 6)
        defaults.set(sendAtOnce, forKey: "sendAtOnce")
    }


    static var deviceName: String {
        return UIDevice.current.name
    }

    /// The phone's one person (David, 15 November 2026): made the first time,
    /// changed after; anyone else on the phone, and their cameras, removed.
    public func setPhonePerson(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var person = macOwner.flatMap { book.person($0) } ?? Person(name: name)
        person.name = name
        // The server is the folder chosen in Settings, whatever it is (David,
        // 15 November 2026): the person's own NAS folder is no longer asked.
        person.nasFolder = NASThroughFiles.share
        let keep = person
        store { book in
            for other in book.people where other.id != keep.id && other.id != PhoneFolders.othersId { book.remove(person: other.id) }
            book.save(keep)
            // Someone else's cards, saved on the phone and never sent.
            if book.person(PhoneFolders.othersId) == nil { book.save(Person(id: PhoneFolders.othersId, name: "Others")) }
        }
        setMacOwner(person.id)
        rematch()
    }

    /// Each camera on a card the phone has not seen, added for its person,
    /// its zone from the photos; its offset comes from the offset code.
    func addCameras(_ photos: [ScannedPhoto], personId: UUID) {
        let models = Set(photos.compactMap(\.model)).sorted()
        for model in models where book.camera(personId: personId, model: model) == nil {
            save(Camera(personId: personId, model: model, zone: .fromPhoto))
        }
    }

    /// No NAS folder any more: sending waits until one is chosen.
    public func forgetNASFolder() async {
        PhoneFolders.forget(PhoneFolders.nasKey)
        nasLine = ""
        await checkNAS()
    }

    /// The NAS folder chosen in Settings on the phone: tried at once.
    public func useNASFolder() async {
        nextTry = nil
        await testNAS()
        await checkNAS()
    }


    public func setKeepOnMac(_ keep: KeepOnMac) {
        keepOnMac = keep
        defaults.set(keep.rawValue, forKey: "keepOnMac")
        tidyMac()
    }

    /// Space freed on this Mac by removing copies that are on the NAS.
    public var freedOnMac: Int64 { sentRecords.compactMap(\.freed).reduce(0, +) }

    /// "2026.10.29/IMG_0001_2.jpg": where a sent photo landed under its person's folder.
    static func landed(_ e: QueueEntry) -> String {
        guard let name = e.sentAs else { return e.relativePath }
        let day = (e.relativePath as NSString).deletingLastPathComponent
        return day.isEmpty ? name : "\(day)/\(name)"
    }

    /// Removes the copies on this Mac that have been on the NAS long enough,
    /// going by the record alone, with a location or without (0.27.0). Never
    /// one still to send or changed since it went. An emptied day folder goes too.
    public func tidyMac(now: Date = Date()) {
        lastTidy = now
        sentSinceTidy = false
        let busy = Set(queueEntries.filter { $0.state != .sent }.map(\.localPath))
        var plan = MacTidy.plan(sentRecords, keep: keepOnMac, busy: busy, now: now)
        // Every working copy leaves once it is on the server: raws (0.29.5), and JPGs too,
        // now that they are in the Photos library (0.29.15).
        let onServer = MacTidy.plan(sentRecords, keep: .untilOnNAS, busy: busy, now: now)
        plan.remove = Array(Set(plan.remove + onServer.remove)).sorted()
        plan.gone = Array(Set(plan.gone + onServer.gone)).sorted()
        guard !plan.remove.isEmpty || !plan.gone.isEmpty else { return }
        let fm = FileManager.default
        let roots = Set(book.people.compactMap { saveFolder(of: $0).map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
        var records = sentRecords
        var folders: Set<String> = []
        for i in plan.remove {
            let url = URL(fileURLWithPath: records[i].localPath)
            guard (try? fm.removeItem(at: url)) != nil else { continue }
            records[i].removed = now
            records[i].freed = records[i].size
            folders.insert(url.deletingLastPathComponent().standardizedFileURL.path)
        }
        for i in plan.gone { records[i].removed = now }
        for folder in folders where !roots.contains(folder) {
            let left = ((try? fm.contentsOfDirectory(atPath: folder)) ?? ["?"]).filter { $0 != ".DS_Store" }
            if left.isEmpty { try? fm.removeItem(atPath: folder) }
        }
        sentRecords = records
        try? sentLog.save(records)
        // Removed copies come off the list of photos without a location.
        if !saving, !placingLater, let list = try? unplaced.load() {
            let left = list.filter { fm.fileExists(atPath: $0.localPath) }
            if left.count != list.count { try? unplaced.save(left) }
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

    /// The oldest photo that can go now: its person has a NAS folder, it is
    /// not resting after a try that broke off, and no photo of the same name
    /// is going up into the same folder, where the two would race for it.
    private func nextToSend() -> QueueEntry? {
        let now = Date()
        let place: (QueueEntry) -> String? = { [book] in book.person($0.personId)?.nasFolder }
        let going = Set(queueEntries.filter { $0.state == .sending }.map { "\(place($0) ?? "")/\($0.relativePath)" })
        return queueEntries
            .filter { $0.state == .waiting && !$0.held && ($0.notBefore ?? .distantPast) <= now && NASFolder(place($0)) != nil
                && !going.contains("\(place($0) ?? "")/\($0.relativePath)") }
            .min { $0.added < $1.added }
    }

    /// Sends waiting photos to the NAS, oldest first and `sendAtOnce` at a
    /// time, until nothing more can go now, the NAS can't be reached, or
    /// sending is paused. Called every few seconds from launch; the queue is
    /// on disk, so it carries on after a restart.
    /// Mobile data switched off for Squeaky in the iPhone's Settings, and no
    /// Wi-Fi: sending waits (0.29.38; Squeaky's own switch is removed, David).
    public var mobileDataBlocked = false

    /// Each photo sent with the time of its four steps, for the phone's record (0.29.45).
    public var onPhotoTimed: ((String, Int64, [Double]) -> Void)?

    public func sendWaiting() async {
        guard !sendingNow, !sendPaused else { return }
        if mobileDataBlocked {
            if queueEntries.contains(where: { $0.state == .waiting && !$0.held }) { say(Words.t("Waiting for Wi-Fi to back up to the server")) }
            return
        }
        if let next = nextTry, Date() < next { return }
        // Away from home, through the buffer server (0.30.0).
        if await useBuffer() {
            await sendThroughBuffer()
            return
        }
        if sendRoute != .nas, queueEntries.contains(where: { $0.state == .waiting && !$0.held }) { sendRoute = .nas }
        sendingNow = true
        defer {
            sendingNow = false
            sendingBatch = false
        }
        nextTry = nil
        // Someone taken off the list: their photos can't go anywhere.
        if queueEntries.contains(where: { $0.state == .waiting && book.person($0.personId) == nil }) {
            changeQueue { all in
                for i in all.indices where all[i].state == .waiting && book.person(all[i].personId) == nil {
                    all[i].state = .failed
                    all[i].reason = Words.t("Their person was removed from People")
                    batchFailed += 1
                }
            }
        }
        // Set when the NAS can't take more for now: those going up finish,
        // no more begin, and the line says when it tries again.
        var halt: String?
        await withTaskGroup(of: Bool.self) { group in
            var running = 0
            while true {
                while halt == nil, !sendPaused, running < sendAtOnce, let entry = nextToSend() {
                    // Away from home with the buffer server set up since this batch began:
                    // no more go to the NAS; the next round sends through the buffer (0.30.1).
                    if bufferKeySaved, await useBuffer() { break }
                    guard let place = NASFolder(book.person(entry.personId)?.nasFolder) else { break }
                    let connection: NASConnection
                    do {
                        connection = try await nas.connect(share: place.share)
                    } catch {
                        nasReach = .unreachable
                        let retry = Date().addingTimeInterval(60)
                        nextTry = retry
                        halt = Words.t("{0} Trying again at {1}.", error.localizedDescription, When.current.time(retry))
                        break
                    }
                    if connection.ours { ourMounts[connection.folder.path] = connection }
                    sendingThrough = connection.address
                    if nasReach != .through(connection.address) { nasReach = .through(connection.address) }
                    let name = (entry.relativePath as NSString).lastPathComponent
                    changeEntry(entry.id) { $0.state = .sending }
                    meter.begin(entry.id, name: name, weights: stepTimes.weights(for: connection.address))
                    sendingBatch = true
                    sayGoing()
                    refreshWork()
                    running += 1
                    group.addTask { @MainActor [self] in
                        await sendOne(entry, as: name, into: place, on: connection)
                    }
                }
                guard running > 0, let full = await group.next() else { break }
                running -= 1
                if full {
                    let retry = Date().addingTimeInterval(300)
                    nextTry = retry
                    halt = Words.t("NAS full. Trying again at {0}.", When.current.time(retry))
                }
                if halt == nil, running > 0 { sayGoing() }
                refreshWork()
            }
        }
        sendingThrough = nil
        if let halt {
            say(halt)
            return
        }
        say(sendPaused ? Words.t("Paused.") : restingLine())
        let waiting = queueEntries.contains { $0.state == .waiting && NASFolder(book.person($0.personId)?.nasFolder) != nil }
        // All that can go has gone, and nothing is still being saved or placed:
        // one notification for the whole batch.
        if !sendPaused, !waiting, !saving, !placingLater, batchSent + batchFailed > 0 {
            notifier.post(Self.batchText(sent: batchSent, failed: batchFailed))
            await shareWithServer()
            batchSent = 0
            batchFailed = 0
        }
        if !sendPaused, !waiting { await closeOurMounts() }
        // Every ten minutes, and straight after a send when copies go as soon as they are on the NAS.
        let rawsGoAtOnce = true
        if lastTidy.map({ Date().timeIntervalSince($0) > 600 }) ?? true || (sentSinceTidy && (keepOnMac == .untilOnNAS || rawsGoAtOnce)) { tidyMac() }
    }

    /// "IMG_0001.JPG to nas, about 20 min left. Slow.", or with several
    /// going up, "3 photos to nas at once, ..." The Waiting box above has the
    /// count (David, 5 November 2026). Said again as photos move along and
    /// the queue changes, so it never goes stale.
    private func sayGoing() {
        guard let address = sendingThrough, meter.count > 0, !sendPaused else { return }
        let host = Self.host(address)
        let going = meter.only.map { Words.t("{0} to {1}", $0.name, host) } ?? Words.t("{0} photos to {1} at once", meter.count, host)
        // "DAVL4150.CR3 to Squeaky, ≈ 9 h 15 min left (speed: average)": no full stops, and
        // where it does not fit, the comma becomes a new line (0.29.29, David, 17 November 2026).
        var line = going
        if let seconds = sendingSeconds() { line += LineBreaks.soft + Words.t("{0} left", Remaining.approx(seconds)) }
        if let word = sendingSpeed() { line += " (" + Words.t("speed: " + word.rawValue.lowercased()) + ")" }
        say(line)
    }

    /// "10.0.10.10" from "smb://10.0.10.10"; on the phone, the NAS folder's name.
    nonisolated public static func host(_ address: String) -> String {
        return address
    }

    private func size(of entry: QueueEntry) -> Int64 {
        if let known = entrySizes[entry.id] { return known }
        let size = SentRecord.stamp(entry.localPath)?.size ?? 0
        entrySizes[entry.id] = size
        return size
    }

    /// Slow, average or fast: the latest photo through this address against
    /// every photo timed, home and away.
    public func sendingSpeed() -> SendSpeeds.Rating? {
        guard let address = sendingThrough, let speed = sendSpeeds.latest(for: address) else { return nil }
        return sendSpeeds.rating(of: speed)
    }

    /// One photo up to the NAS, and the queue told how it went. True when the
    /// NAS is full.
    private func sendOne(_ entry: QueueEntry, as name: String, into place: NASFolder, on connection: NASConnection) async -> Bool {
        let day = (entry.relativePath as NSString).deletingLastPathComponent
        var folder = place.folder(in: connection.folder)
        if !day.isEmpty { folder.appendPathComponent(day, isDirectory: true) }
        let clean = cleanedFolders.insert(folder.path).inserted
        let local = URL(fileURLWithPath: entry.localPath)
        let engine = self.engine, update = entry.update, meter = self.meter, id = entry.id
        let clock = StepClock()
        let before = SentRecord.stamp(entry.localPath)
        // On a thread of its own: a connection that hangs must not hold up
        // the threads the rest of Squeaky runs on.
        let outcome: Result<SendOutcome, NASError> = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                do {
                    done.resume(returning: .success(try NASSender.send(local, as: name, into: folder, update: update,
                                                                       clean: clean, engine: engine) { step in
                        clock.saw(step)
                        Task { @MainActor [weak self] in
                            meter.show(step, for: id)
                            self?.sayGoing()
                            self?.refreshWork()
                        }
                    }))
                } catch {
                    done.resume(returning: .failure(error as? NASError ?? .failed(error.localizedDescription)))
                }
            }
        }
        let fullSize = size(of: entry)
        meter.end(id)
        entrySizes[id] = nil
        switch outcome {
        case .success(let result):
            batchSent += 1
            // Only a photo that went through every step times them.
            if case .alreadyThere = result {} else if let seconds = clock.seconds() {
                stepTimes.add(seconds, for: connection.address)
                onPhotoTimed?(name, Int64(before?.size ?? fullSize), seconds)
                if let data = try? JSONEncoder().encode(stepTimes) { defaults.set(data, forKey: "stepTimes") }
                sendSpeeds.add(bytes: before?.size ?? fullSize, seconds: seconds.reduce(0, +), for: connection.address)
                if let data = try? JSONEncoder().encode(sendSpeeds) { defaults.set(data, forKey: "sendSpeeds") }
            }
            let landed = result.url.lastPathComponent
            if let before {
                var done = entry
                done.sentAs = landed == name ? nil : landed
                let record = SentRecord(personId: entry.personId, localPath: entry.localPath, nasPath: Self.landed(done),
                                        sent: Date(), size: before.size, modified: before.modified)
                try? sentLog.add([record])
                sentRecords.append(record)
                sentSinceTidy = true
            }
            changeEntry(id) { e in
                e.state = .sent
                e.sent = Date()
                e.sentAs = landed == name ? nil : landed
                e.reason = nil
                e.notBefore = nil
            }
        case .failure(.offline(let why)):
            // It rests a little longer after each break, so the others go first.
            changeEntry(id) { e in
                e.state = .waiting
                e.tries += 1
                e.reason = why
                e.notBefore = Date().addingTimeInterval(Double(min(e.tries, 10)) * 60)
            }
        case .failure(.full):
            changeEntry(id) { $0.state = .waiting }
            return true
        case .failure(.failed(let why)):
            batchFailed += 1
            changeEntry(id) { e in
                e.state = .failed
                e.reason = why
            }
        }
        return false
    }

    /// "about 20 min" of sending left: the bytes still to go, what is left of
    /// the photos going up included, at the recent pace through this address.
    /// Nil before a photo has been timed through it.
    public func sendingLeft() -> String? {
        sendingSeconds().map(Remaining.text)
    }

    /// Seconds still to go for every photo waiting, at this address's pace.
    public func sendingSeconds() -> TimeInterval? {
        guard let address = sendingThrough else { return nil }
        // Through the buffer server: the whole batch's pace, not one photo's (0.30.3).
        if sendRoute == .buffer, let pace = bufferUploads.pace(), pace > 0 {
            let ahead = queueEntries.filter { $0.state == .waiting && !$0.held && NASFolder(book.person($0.personId)?.nasFolder) != nil }
            var bytes = ahead.reduce(0.0) { $0 + Double(size(of: $1)) }
            for entry in queueEntries where entry.state == .sending {
                bytes += Double(size(of: entry)) * (1 - (meter.going[entry.id]?.fraction ?? 0))
            }
            return bytes / pace
        }
        let ahead = queueEntries.filter { $0.state == .waiting && NASFolder(book.person($0.personId)?.nasFolder) != nil }
        var bytes = ahead.reduce(0.0) { $0 + Double(size(of: $1)) }
        for entry in queueEntries where entry.state == .sending {
            bytes += Double(size(of: entry)) * (1 - (meter.going[entry.id]?.fraction ?? 0))
        }
        return sendSpeeds.seconds(for: bytes, through: address)
    }

    /// What the menu bar icon shows while Squeaky works: the Photos page's own
    /// line while a card is read or saved, the NAS's while photos go up, and
    /// how far the first of them has got (David, 18 October 2026). Photos
    /// only waiting for the NAS show nothing.
    func refreshWork() {
        var lines: [String] = []
        var fraction: Double?
        if photosBusy || saving, !photosLine.isEmpty {
            lines.append(photosLine)
            if saving {
                fraction = saveTotal > 0 ? Double(saveDone) / Double(saveTotal) : nil
            } else if let read = readProgress, read.total > 0 {
                fraction = Double(read.done) / Double(read.total)
            }
        }
        if sendingBatch {
            let done = batchSent + batchFailed
            let now = meter.count
            let ahead = queueEntries.filter { $0.state == .waiting && NASFolder(book.person($0.personId)?.nasFolder) != nil }.count
            let total = done + now + ahead
            lines.append(Words.t("Sending to the NAS: {0} of {1}", (done + now).formatted(), total.formatted()) + (sendingLeft().map { Words.t(", {0} left", $0) } ?? ""))
            for id in meter.order {
                if let going = meter.going[id] { lines.append("\(going.name): \(going.text)") }
            }
            if fraction == nil, total > 0 {
                fraction = (Double(done) + meter.done) / Double(total)
            }
        }
        work.set(lines: lines, fraction: fraction)
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
            parts.append(Words.t("{0} {1} no NAS folder. Choose one in Settings, People.", names.joined(separator: ", "), names.count == 1 ? Words.t("has") : Words.t("have")))
        }
        let resting = waiting.compactMap(\.notBefore).filter { $0 > Date() }
        if let soonest = resting.min() {
            parts.append(Words.t("{0} to try again at {1}.", resting.count, When.current.time(soonest)))
        }
        if failed > 0 { parts.append(Words.t("{0} not sent: see the list.", failed)) }
        if parts.isEmpty, waiting.isEmpty, !queueEntries.isEmpty { return Words.t("Everything is on the NAS.") }
        return parts.joined(separator: " ")
    }

    /// Shared folders Squeaky opened, closed again once nothing is waiting.
    private func closeOurMounts() async {
        // Never while the lists are being written into one of them.
        guard !ourMounts.isEmpty, !sharing else { return }
        let open = Array(ourMounts.values)
        ourMounts = [:]
        cleanedFolders = []
        for connection in open { await nas.disconnect(connection) }
    }

    // MARK: Download

    /// The Download menu: a disk image of this Squeaky, made now, put in the
    /// Downloads folder over one of the same name, and shown there in Finder.
    /// A disk image of this Squeaky for that kind of Mac, in Downloads,
    /// shown in Finder. What became of it is said on the Download page.

    // MARK: History

    public func showHistory(_ personId: UUID?) {
        historyPerson = personId
        historyEntries = personId.flatMap { try? history.load($0) } ?? []
    }

    // MARK: Tracks

    // MARK: Tracks from the watch (0.32.0, David, 19 November 2026)

    /// A track coming in from the watch: how many of its parts are here.
    @Published public var watchReceiving: (got: Int, of: Int)?
    /// Tracks a family phone passed on, each waiting for its OK.
    @Published public var trackNotices: [String] = []

    /// This phone's person, for "From David's fēnix watch".
    public var ownerName: String? {
        macOwner.flatMap { book.person($0)?.name }
    }

    /// A whole track from the watch into the library, used for matching at
    /// once; on the owner's phone it goes up to the track service when it can.
    public func addWatchTrack(trackId: Int, points: TrackPoints, watchModel: String?) async throws {
        let model = Self.shortModel(watchModel)
        let name = ownerName.map { Words.t("From {0}'s {1} watch", $0, model) } ?? Words.t("From the {0} watch", model)
        _ = try await library.importWatch(id: WatchInbox.libraryId(trackId), name: name, points: points, role: role)
        await tracksChanged()
        Task { await uploadWaitingTracks() }
    }

    /// A watch track a family phone passed on. Answers true when it was new here.
    public func addSharedTrack(_ track: Track, points: TrackPoints, from person: String) async -> Bool {
        guard !(await library.has(track.id)) else { return false }
        guard (try? await library.importWatch(id: track.id, name: track.name, points: points, role: role)) != nil else { return false }
        await tracksChanged()
        let when = When.current.dayAndTime(track.start)
        trackNotices.append(Words.t("Track received from {0}: {1}, {2}", person, when, Self.length(track.duration)))
        return true
    }

    private func tracksChanged() async {
        tracks = await library.listed()
        await loadTimeline()
        rematch()
    }

    /// Tracks waiting to go up are sent whenever the service can be reached;
    /// the phone calls this again until none wait.
    public func uploadWaitingTracks() async {
        guard role == .owner, await library.waitingCount > 0 else { return }
        await refresh()
    }

    public var hasWaitingTracks: Bool {
        get async { await library.waitingCount > 0 }
    }

    /// "fēnix" from "fēnix 9 Pro - inReach, 51mm".
    static func shortModel(_ model: String?) -> String {
        let words = (model ?? "").split(separator: " ")
        return words.first.map(String.init) ?? Words.t("Garmin")
    }

    static func length(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? Words.t("{0} h {1} min", h, m) : Words.t("{0} min", m)
    }

    /// True when the track service answered.
    @discardableResult
    public func refresh(pullStrava: Bool = false) async -> Bool {
        guard !tracksBusy else { return false }
        guard let service else {
            tracks = await library.listed()
            tracksLine = ServiceError.notSetUp.localizedDescription
            return false
        }
        tracksBusy = true
        defer { tracksBusy = false }
        // At once, so no line from before stays up while the tracks come in.
        tracksLine = Words.t("Loading tracks")
        if role == nil { await testService() }
        guard let role else {
            tracks = await library.listed()
            tracksLine = settingsLine
            return false
        }
        await loadMaps(service)
        if thumbnails.forgetFailures() { mapsRound += 1 }
        let report = await library.refresh(service: service, role: role, pullStrava: pullStrava) { @MainActor [weak self] done, total in
            self?.tracksLine = Words.t("Loading tracks: {0} of {1}", done.formatted(), total.formatted())
        }
        tracks = await library.listed()
        tracksLine = report.line
        if !rows.isEmpty || report.added > 0 {
            await loadTimeline()
            rematch()
        }
        let answered = !report.offline && report.problems.isEmpty
        if answered { Task { await releaseHeld() } }
        Task { await nameTracks() }
        return answered
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

    /// Each track not named yet, named by where it is, one question a second
    /// to OpenStreetMap; stops at the first that gets no answer. Only with the
    /// real place names: the self-test's never go online.
    func nameTracks() async {
        guard !namingTracks, places is PlaceNames else { return }
        namingTracks = true
        defer { namingTracks = false }
        let file = TrackPlaces.file(beside: (peopleStore as? PeopleStoreFile)?.url)
        if trackPlaces.isEmpty { trackPlaces = TrackPlaces.load(file) }
        // The service names its own tracks (tracks 0.4.1): only those it does not hold are named here.
        let unnamed = tracks.filter { trackPlaces[$0.id] == nil && $0.place == nil && $0.status != .onService }
        guard !unnamed.isEmpty else { return }
        let before = tracksLine
        var said = ""
        defer { if tracksLine == said { tracksLine = before } }
        for (n, track) in unnamed.enumerated() {
            if !tracksBusy {
                said = Words.t("Naming tracks by place: {0} of {1}", n + 1, unnamed.count)
                tracksLine = said
            }
            guard let points = await library.points(track.id), let first = points.lat.indices.first else { continue }
            let mid = points.lat.count / 2, last = points.lat.count - 1
            var spots: [TrackPlaces.Spot] = []
            for i in [first, mid, last] {
                try? await Task.sleep(for: .milliseconds(1100))
                guard let spot = await TrackPlaces.spot(points.lat[i], points.lon[i]) else {
                    // Said, not silent: the rest are named next time (0.29.16).
                    said = ""
                    if !tracksBusy { tracksLine = Words.t("Tracks not named by place: OpenStreetMap isn't answering. {0} of {1} named.", n, unnamed.count) }
                    return
                }
                spots.append(spot)
            }
            guard let name = TrackPlaces.name(spots[0], spots[1], spots[2]) else { continue }
            trackPlaces[track.id] = name
            TrackPlaces.save(trackPlaces, file)
        }
    }

    /// Shows what the library holds, without asking the service.
    public func showLibrary() async {
        tracks = await library.listed()
    }

    /// Import from the Tracks menu: the Mac's own file window, GPX and FIT only.

    public func importFiles(_ urls: [URL]) async {
        var added = 0
        var lines: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                switch try await library.importFile(url, role: role) {
                case .added: added += 1
                case .alreadyHere(let existing): lines.append(Words.t("{0} is already here as {1}.", url.lastPathComponent, existing.name))
                }
            } catch {
                lines.append(error.localizedDescription)
            }
        }
        tracks = await library.listed()
        if added > 0 {
            lines.insert(added == 1 ? Words.t("1 track imported.") : Words.t("{0} tracks imported.", added), at: 0)
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


// MARK: The buffer server (0.30.0, David, 17 November 2026)

extension AppModel {
    var bufferClient: BufferClient? { BufferClient(address: savedBuffer.address, key: savedBuffer.key) }

    /// A key has been saved for the buffer server.
    public var bufferKeySaved: Bool { !savedBuffer.key.isEmpty }

    /// The address or key differs from what was saved.
    public var bufferUnsaved: Bool { ServiceFields(address: bufferAddress, key: bufferKey) != savedBuffer }

    public func revertBuffer() {
        bufferAddress = savedBuffer.address
        bufferKey = savedBuffer.key
    }

    public func saveBuffer() async {
        let fields = ServiceFields(address: bufferAddress, key: bufferKey)
        do {
            try writeSecrets(serviceKey: savedService.key, nasPassword: savedNAS.password, bufferKey: fields.key)
        } catch {
            bufferLine = error.localizedDescription
            return
        }
        defaults.set(fields.address, forKey: "bufferAddress")
        savedBuffer = fields
        bufferAsked = nil
        await checkBuffer(saying: Words.t("Saved. "))
    }

    public func removeBuffer() async {
        do {
            try writeSecrets(serviceKey: savedService.key, nasPassword: savedNAS.password, bufferKey: "")
        } catch {
            bufferLine = error.localizedDescription
            return
        }
        bufferUploads.cancelAll()
        bufferKey = ""
        savedBuffer = ServiceFields(address: savedBuffer.address, key: "")
        bufferAddress = savedBuffer.address
        bufferWaiting = nil
        bufferAsked = nil
        bufferLine = ""
    }

    /// Asks the buffer server how it stands: the key, and how many photos wait there for the NAS.
    public func checkBuffer(saying prefix: String = "", showing: Bool = false) async {
        guard let client = bufferClient else { bufferLine = prefix.trimmingCharacters(in: .whitespaces); return }
        bufferBusy = true
        defer { bufferBusy = false }
        if !prefix.isEmpty || showing { bufferLine = prefix + Words.t("Checking the buffer server") }
        do {
            let status = try await client.status()
            bufferWaiting = status.waiting
            bufferAsked = (Date(), status.atHome)
            bufferLine = prefix + (status.role == "sender" ? Words.t("Key accepted.") : Words.t("This key can't send photos."))
        } catch {
            bufferLine = prefix + error.localizedDescription
        }
    }

    /// Through the buffer server when one is set up and this device is away
    /// from home; asked at most once a minute. The buffer server not
    /// answering: straight to the NAS, as before.
    func useBuffer() async -> Bool {
        guard let client = bufferClient else {
            if sendRoute == .buffer { sendRoute = nil }
            return false
        }
        let waiting = queueEntries.contains { ($0.state == .waiting || $0.state == .sending) && !$0.held }
        // No server folder chosen on this phone yet: the NAS can't be reached
        // straight, so always through the buffer server (0.30.4, David).
        if !PhoneFolders.isChosen(PhoneFolders.nasKey) { return true }
        if let asked = bufferAsked, Date().timeIntervalSince(asked.at) < 60 {
            if let atHome = asked.atHome { return !atHome }
            return false
        }
        // Nothing to send and nothing on its way: no need to ask.
        guard waiting || meter.count > 0 else { return sendRoute == .buffer }
        do {
            let status = try await client.status()
            bufferWaiting = status.waiting
            bufferAsked = (Date(), status.atHome)
            return !status.atHome
        } catch {
            bufferAsked = (Date(), nil)
            return false
        }
    }

    /// Hands waiting photos to the phone's transfers, up to 6 on their way
    /// at once, so a closed or locked phone carries on with them; topped up
    /// as they finish.
    /// The person's folder as the buffer server is told it: on the phone the
    /// folder as the Files app names it ("home/Squeaky", the logged-in user's
    /// home; the buffer server knows whose from the key), or the owner's
    /// Squeaky folder in their home when none is chosen yet (0.30.4, David);
    /// on the Mac the person's NAS folder.
    func bufferBase(_ nasFolder: String?) -> String? {
        return PhoneFolders.isChosen(PhoneFolders.nasKey)
            ? (UserDefaults.standard.string(forKey: PhoneFolders.nasKey + "Path") ?? PhoneFolders.path(PhoneFolders.nasKey))
            : "home/Squeaky"
    }

    func sendThroughBuffer() async {
        guard let client = bufferClient, !bufferTopping, !sendPaused else { return }
        bufferTopping = true
        defer { bufferTopping = false }
        if sendRoute != .buffer { sendRoute = .buffer }
        sendingThrough = client.address.host ?? "bufr.cc"
        let flying = await bufferUploads.inFlight()
        // Marked as going but no longer on their way (Squeaky closed meanwhile): waiting again.
        if queueEntries.contains(where: { $0.state == .sending && !flying.contains($0.id) }) {
            changeQueue { all in
                for i in all.indices where all[i].state == .sending && !flying.contains(all[i].id) { all[i].state = .waiting }
            }
        }
        // In the queue's own order, so the rows come back in the same places after a reopen.
        for entry in queueEntries where flying.contains(entry.id) && meter.going[entry.id] == nil {
            meter.begin(entry.id, name: (entry.relativePath as NSString).lastPathComponent, weights: .buffer)
        }
        // Six at a time: thirty shared one connection, and the starved ones started
        // again from nothing ("57% then back to 11%", 0.31.5, David).
        var room = 6 - flying.count
        while room > 0, !sendPaused, let entry = nextToSend() {
            guard let folder = book.person(entry.personId)?.nasFolder, NASFolder(folder) != nil else { break }
            let local = URL(fileURLWithPath: entry.localPath)
            let fingerprint: (sha256: String, size: Int64)? = await withCheckedContinuation { done in
                DispatchQueue.global(qos: .utility).async { done.resume(returning: try? BufferClient.fingerprint(of: local)) }
            }
            guard let fingerprint else {
                batchFailed += 1
                changeEntry(entry.id) { e in
                    e.state = .failed
                    e.reason = Words.t("The copy here could not be read.")
                }
                continue
            }
            let base = bufferBase(folder)
            guard let base, !base.isEmpty else {
                changeEntry(entry.id) { e in
                    e.reason = Words.t("Choose the server folder in Settings first.")
                    e.notBefore = Date().addingTimeInterval(60)
                }
                continue
            }
            let path = base.split(separator: "/").joined(separator: "/") + "/" + entry.relativePath
            let modified = (try? FileManager.default.attributesOfItem(atPath: local.path))?[.modificationDate] as? Date
            let request = client.upload(path: path, sha256: fingerprint.sha256, size: fingerprint.size,
                                        modified: modified, update: entry.update)
            changeEntry(entry.id) { $0.state = .sending }
            meter.begin(entry.id, name: (entry.relativePath as NSString).lastPathComponent, weights: .buffer)
            sendingBatch = true
            bufferUploads.send(entry.id, file: local, request: request)
            room -= 1
        }
        if meter.count > 0 {
            sayGoing()
        } else {
            sendingThrough = nil
            sendingBatch = false
            say(sendPaused ? Words.t("Paused.") : restingLine())
            let waiting = queueEntries.contains { $0.state == .waiting && NASFolder(book.person($0.personId)?.nasFolder) != nil }
            if !sendPaused, !waiting, !saving, !placingLater, batchSent + batchFailed > 0 {
                notifier.post(Self.batchText(sent: batchSent, failed: batchFailed))
                await shareWithServer()
                batchSent = 0
                batchFailed = 0
            }
        }
        refreshWork()
    }

    /// One photo back from the buffer server.
    func bufferDone(_ id: UUID, problem: (why: String, again: Bool)?, seconds: TimeInterval?) {
        meter.end(id)
        entrySizes[id] = nil
        guard let entry = queueEntries.first(where: { $0.id == id }) else { return }
        if let problem {
            if problem.again {
                changeEntry(id) { e in
                    e.state = .waiting
                    if problem.why != Words.t("Paused.") {
                        e.tries += 1
                        e.reason = problem.why
                        e.notBefore = Date().addingTimeInterval(Double(min(e.tries, 10)) * 60)
                    }
                }
            } else {
                batchFailed += 1
                changeEntry(id) { e in
                    e.state = .failed
                    e.reason = problem.why
                }
            }
        } else {
            batchSent += 1
            let before = SentRecord.stamp(entry.localPath)
            let bytes = before?.size ?? size(of: entry)
            if var seconds, let address = sendingThrough ?? bufferClient?.address.host {
                // Timed at the batch's pace: the photo's own time includes sharing the line (0.30.3).
                if let pace = bufferUploads.pace(), pace > 0 { seconds = Double(bytes) / pace }
                sendSpeeds.add(bytes: bytes, seconds: seconds, for: address)
                if let data = try? JSONEncoder().encode(sendSpeeds) { defaults.set(data, forKey: "sendSpeeds") }
                onPhotoTimed?((entry.relativePath as NSString).lastPathComponent, Int64(bytes), [0, seconds, 0, 0])
            }
            if let before {
                let record = SentRecord(personId: entry.personId, localPath: entry.localPath, nasPath: entry.relativePath,
                                        sent: Date(), size: before.size, modified: before.modified)
                try? sentLog.add([record])
                sentRecords.append(record)
                sentSinceTidy = true
            }
            changeEntry(id) { e in
                e.state = .sent
                e.sent = Date()
                e.sentAs = nil
                e.reason = nil
                e.notBefore = nil
            }
            bufferWaiting = (bufferWaiting ?? 0) + 1
        }
        refreshWork()
        // The next ones handed over straight away, on the phone also while it is locked.
        Task { await sendThroughBuffer() }
    }
}
