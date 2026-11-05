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
    @Published public private(set) var results: [String: SaveResult] = [:]
    private var stopAsked = false

    /// The Download menu's disk image being made.
    @Published public private(set) var makingDownload = false
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
    @Published public private(set) var nasReach = NASReach.checking {
        didSet {
            // It answers again: the warning goes by itself.
            guard case .through = nasReach, nasAway else { return }
            nasAway = false
            if photosFix == .openTailscale { photosLine = "" }
        }
    }
    /// Geotag opened with photos waiting and the NAS did not answer.
    @Published public private(set) var nasAway = false
    public static let nasAwayText = "The NAS isn't answering. If you're away from home, turn on Tailscale; otherwise check the connection."
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
    /// Geotag's folder in iCloud Drive; nil when iCloud Drive is off. A test's
    /// stays in its scratch folder.
    public let cloudFolder: URL?
    /// The Macs that have copied their settings to iCloud, and why this one could not.
    @Published public private(set) var cloudMacs: [CloudCopy.Mac] = []
    @Published public private(set) var cloudProblem: String?
    private var cloudTimer: Timer?
    /// Everyone came from iCloud into an install that had nobody.
    private var newFromCloud = false
    /// Where this Mac and iCloud last agreed; a test's own, beside its people file.
    private var cloudSeenKey: String {
        guard let file = peopleStore as? PeopleStoreFile, file.url != PeopleStoreFile.standard().url else { return "cloudSeen" }
        return "cloudSeen-" + file.url.path
    }
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
                places: PlaceNaming? = nil,
                power: PowerPort? = nil,
                temperatures: TemperatureStorePort? = nil,
                sentLog: SentLogPort? = nil,
                cloudFolder: URL? = nil) {
        // Beside the people list unless told otherwise, so a test's stays in its scratch folder.
        self.temperatureStore = temperatures
            ?? (peopleStore as? PeopleStoreFile).map { TemperatureStoreFile(url: $0.url.deletingLastPathComponent().appendingPathComponent("temperatures.json")) }
            ?? TemperatureStoreFile.standard()
        self.sentLog = sentLog
            ?? (queue as? QueueStoreFile).map { SentLogFile(url: $0.url.deletingLastPathComponent().appendingPathComponent("sent.jsonl")) }
            ?? SentLogFile.standard()
        if let cloudFolder {
            self.cloudFolder = cloudFolder
        } else if let file = peopleStore as? PeopleStoreFile {
            self.cloudFolder = file.url == PeopleStoreFile.standard().url
                ? CloudCopy.standardFolder
                : file.url.deletingLastPathComponent().appendingPathComponent("iCloud", isDirectory: true)
        } else {
            self.cloudFolder = nil
        }
        self.notifier = notifier ?? MacNotifier.shared
        self.power = power ?? MacPower()
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
            peopleLine = "The people list could not be read: \(error.localizedDescription)"
        }
        self.temperatures = (try? temperatureStore.load()) ?? CameraTemperatures()
        if let raw = defaults.string(forKey: "appearance"), let mode = Appearance(rawValue: raw) {
            appearance = mode
        }
        macOwner = defaults.string(forKey: "macOwner").flatMap(UUID.init(uuidString:)).flatMap { id in book.person(id) != nil ? id : nil }
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
        if let data = defaults.data(forKey: "stepTimes"), let times = try? JSONDecoder().decode(StepTimes.self, from: data) { stepTimes = times }
        if let data = defaults.data(forKey: "sendSpeeds"), let speeds = try? JSONDecoder().decode(SendSpeeds.self, from: data) { sendSpeeds = speeds }
        if defaults.object(forKey: "sendAtOnce") != nil { sendAtOnce = min(max(defaults.integer(forKey: "sendAtOnce"), 1), 6) }
        // A send cut off by a crash or a shutdown starts again from the beginning.
        var entries = (try? queue.load()) ?? []
        for i in entries.indices where entries[i].state == .sending { entries[i].state = .waiting }
        queueEntries = entries
        keepOnMac = defaults.string(forKey: "keepOnMac").flatMap(KeepOnMac.init(rawValue:)) ?? .thirtyDays
        sentRecords = (try? self.sentLog.load()) ?? []
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

    /// As Geotag opens: photos waiting and no answer from the NAS at either
    /// address, so say so once, here and as a notification (David, 1 November 2026).
    public func announceNASAway() {
        let waiting = queueEntries.contains { $0.state == .waiting && NASFolder(book.person($0.personId)?.nasFolder) != nil }
        guard nasReach == .unreachable, waiting else { return }
        nasAway = true
        notifier.post(Self.nasAwayText, kind: "nas-away")
        if photosLine.isEmpty { say(Self.nasAwayText, fix: Tailscale.app == nil ? nil : .openTailscale) }
    }

    // MARK: Setting up this Mac

    /// The setup is showing: once on a new Mac, and from the Geotag menu.
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
        return serviceAddress.isEmpty && !book.people.contains { !($0.saveFolder ?? "").isEmpty } || newFromCloud
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
            parts.append("\(left.formatted()) \(left == 1 ? "photo" : "photos") on \(source.name) \(left == 1 ? "is" : "are") not saved yet. Reopening Geotag and clicking Save photos carries on from there.")
        }
        let going = queueEntries.filter { ($0.state == .waiting || $0.state == .sending) && NASFolder(book.person($0.personId)?.nasFolder) != nil }.count
        if going > 0 {
            parts.append("\(going.formatted()) \(going == 1 ? "photo is" : "photos are") uploading to the NAS. Reopening Geotag will resume the upload.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// At launch: show what this Mac has, then ask the service, and again every ten minutes.
    public func start() async {
        // A window opened again runs this again; the rest is once per launch.
        guard !started else { return }
        started = true
        Quitting.cutOff = { [weak self] in self?.quitCutOff() }
        // iCloud first: a new install of David's takes everything from it.
        await syncWithCloud()
        if needsSetup {
            settingUp = true
        } else {
            defaults.set(true, forKey: "setupDone")
        }
        applyAppearance()
        startCards()
        startSending()
        Task {
            await checkNAS()
            announceNASAway()
        }
        // A click on a notification opens the Queue page.
        MacNotifier.onOpen = { [weak self] in
            self?.screen = .queue
            Windows.bringForward()
        }
        tracks = await library.listed()
        await refresh()
        cloudTimer?.invalidate()
        cloudTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncWithCloud() }
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
        guard !saving else { return }
        guard let source else {
            photosLine = "Insert a card."
            return
        }
        guard let personId = importPerson, let person = book.person(personId) else {
            say("Choose whose card \(source.name) is.", fix: .chooseWhose)
            return
        }
        guard let folder = person.saveFolder, !folder.isEmpty else {
            say("\(person.name) has no save folder yet.", fix: .chooseFolder(personId))
            return
        }
        guard let tool = exifTool else {
            photosLine = "ExifTool is missing from Geotag. Install Geotag again."
            return
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            say("\(person.name)'s save folder can't be found: \(folder). If it is on a drive, plug the drive in, or choose another folder.",
                fix: .chooseFolder(personId))
            return
        }
        let todo = readyToSave
        guard !todo.isEmpty else {
            photosLine = rows.isEmpty ? "There are no photos on \(source.name)." : "Every photo on \(source.name) is already saved."
            return
        }
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
        let began = Date()
        var warnedPower = false
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
                    later.append(UnplacedEntry(personId: personId, localPath: url.path, photo: row.photo, shifted: named.shift))
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
        // Ejected or another card chosen meanwhile: that line stands.
        guard readingRound == round else { return }
        let stopped = saveDone < saveTotal
        var line = stopped ? "Stopped after \(saveDone) of \(saveTotal)." : "\(savedCount) saved."
        if stopped { line += " \(savedCount) saved." }
        let unplaced = todo.filter { $0.needsReview && results[$0.id]?.url != nil }.count
        if unplaced > 0 { line += " \(unplaced) of them without a location: see the Status column." }
        if failedCount > 0 { line += " \(failedCount) not saved: see the Status column." }
        if results.values.contains(.failed(Saver.diskFull)) { line = "Stopped: \(Saver.diskFull.lowercased()). \(savedCount) saved before that." }
        // Done before the last line is said, so the menu bar never shows it.
        saving = false
        photosLine = line
        // Every photo is on this Mac: the NAS copies go from there, so the
        // card is not needed any more (David, 1 November 2026).
        if !stopped, failedCount == 0, savedCount > 0, source.bsd != nil, self.source?.id == source.id {
            let onMac = "\(savedCount.formatted()) \(savedCount == 1 ? "photo is" : "photos are") on this Mac; the NAS copies go from there."
            eject(done: onMac)
        }
    }

    /// "Saving 341 of 3,630, about 12 min left", and the warning to connect
    /// to power when the battery would run out first.
    nonisolated public static func savingLine(done: Int, total: Int, left: TimeInterval?, battery: TimeInterval?) -> (line: String, warning: String?) {
        var line = "Saving \((done + 1).formatted()) of \(total.formatted())"
        guard let left else { return (line, nil) }
        line += ", \(Remaining.text(left)) left"
        guard let battery, battery < left else { return (line, nil) }
        let warning = "Connect to power: \(Remaining.text(left)) of saving left, the battery has \(Remaining.text(battery))."
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

    /// Settings opens on this camera's details, from the Photos page.
    @Published public var cameraToEdit: UUID?

    /// The fix offered beside the Photos line, taken.
    public func take(_ fix: PhotosFix) {
        switch fix {
        case .chooseWhose:
            if let source { askingWhose = source }
        case .chooseFolder(let id):
            guard var person = book.person(id),
                  let url = Folders.choose(startingAt: person.saveFolder) else { return }
            person.saveFolder = url.path
            save(person)
            photosLine = "\(person.name)'s photos are saved in \(Folders.shown(url.path))."
            Task { await savePhotos() }
        case .trackService, .cameras:
            screen = .settings
        case .camera(let id):
            screen = .settings
            cameraToEdit = id
        case .openTailscale:
            Tailscale.open()
        }
    }

    /// "See photos on the map": the map window, or why there is nothing to show on it.
    public func openMap() {
        if let why = mapRefusal() {
            say(why.line, fix: why.fix)
        } else {
            // What it said was missing is there now: that line goes.
            if photosFix != nil { photosLine = "" }
            aligning = true
        }
    }

    /// Why the map window has nothing to show, and the way to it; nil when it has.
    public func mapRefusal() -> (line: String, fix: PhotosFix?)? {
        guard let source else { return ("Insert a card.", nil) }
        guard let personId = importPerson else { return ("Choose whose card \(source.name) is.", .chooseWhose) }
        guard !rows.isEmpty else { return ("There are no photos on \(source.name).", nil) }
        guard !alignable.isEmpty else {
            let fresh = rows.filter(\.ticked)
            if fresh.isEmpty { return ("Every photo on \(source.name) is already saved.", nil) }
            let unplaced = fresh.filter { !$0.photo.hasLocation }
            if unplaced.isEmpty { return ("Every new photo on \(source.name) has its own location.", nil) }
            let timed = unplaced.filter { $0.photo.taken != nil }
            if timed.isEmpty { return ("None of the new photos has a time.", nil) }
            for row in timed {
                guard let model = row.photo.model else { continue }
                guard let camera = book.camera(personId: personId, model: model) else {
                    return ("The \(model) is not on the camera list. Add it in Settings, under Cameras.", .cameras)
                }
                if camera.zone == .notSet {
                    return ("The \(camera.model)'s time zone is not set.", .camera(camera.id))
                }
            }
            return ("None of the new photos names its camera.", nil)
        }
        guard !tracks.isEmpty else {
            return ("There are no tracks on this Mac yet. Set up the track service in Settings.", .trackService)
        }
        return nil
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
    /// `done` is said after "can come out" once the card is off, in place of
    /// the usual line, and as a notification.
    public func eject(done: String? = nil) {
        guard let card = source, let bsd = card.bsd else {
            photosLine = "No card is held to eject."
            return
        }
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
                if let done {
                    self.photosLine = "\(card.name) can come out. \(done)"
                    self.notifier.post("\(card.name) can come out.", kind: "card")
                } else {
                    self.photosLine = "\(card.name) is ejected. You can take it out."
                }
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
        readProgress = (0, total)
        defer { readProgress = nil }
        photosLine = "Reading 0 of \(total)"
        do {
            let photos = try await Task.detached {
                try PhotoScanner(exifTool: tool).scan(files) { done in
                    Task { @MainActor [weak self] in
                        guard let self, self.readingRound == round else { return }
                        self.readProgress = (done, total)
                        self.photosLine = "Reading \(done) of \(total)"
                    }
                }
            }.value
            let past = (try? history.load(personId)) ?? []
            guard readingRound == round, self.source?.id == source.id else { return }
            rows = ImportList.rows(photos, history: past, book: book, personId: personId)
            refreshBreaks()
            noteFirmware(photos, personId: personId)
            noteLenses(photos, personId: personId)
            let codes = await readOffsetCodes(photos, personId: personId, tool: tool)
            guard readingRound == round, self.source?.id == source.id else { return }
            await loadTimeline()
            rematch()
            photosLine = rows.isEmpty ? "No photos on \(source.name)." : codes
            Task { await noteTemperatures(photos, personId: personId, tool: tool) }
            // Every camera set: nothing to line up, so the photos are saved straight
            // away, and the card comes out once they are on the Mac (David, 1 November 2026).
            if camerasReady, saveWhenReady {
                await savePhotos()
            } else if trackNear(alignable) {
                aligning = true
            }
        } catch {
            if readingRound == round { photosLine = "The photos could not be read: \(error.localizedDescription)" }
        }
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

    /// How many photos at each end of a camera's run are looked at for an offset code.
    static let codeEnds = 5

    /// Offset codes among the first and last photos of each camera on the
    /// card: each sets its camera's offset, to the hundredth, and adds a
    /// reading to its drift. Says what was set; empty when nothing was.
    func readOffsetCodes(_ photos: [ScannedPhoto], personId: UUID, tool: ExifTool) async -> String {
        var byModel: [String: [ScannedPhoto]] = [:]
        for photo in photos where photo.taken != nil {
            if let model = photo.model { byModel[model, default: []].append(photo) }
        }
        var candidates: [ScannedPhoto] = []
        for (_, list) in byModel {
            let sorted = list.sorted { (Moments.clockReading($0) ?? .distantPast) < (Moments.clockReading($1) ?? .distantPast) }
            candidates += sorted.count <= Self.codeEnds * 2 ? sorted : Array(sorted.prefix(Self.codeEnds) + sorted.suffix(Self.codeEnds))
        }
        let found: [(ScannedPhoto, Date)] = await Task.detached {
            candidates.compactMap { photo in OffsetCode.find(in: photo.url).map { (photo, $0) } }
        }.value
        var said: [String] = []
        for (photo, moment) in found {
            guard let model = photo.model, var camera = book.camera(personId: personId, model: model),
                  let offset = Moments.exactOffset(placing: photo, camera: camera, at: moment) else { continue }
            camera.add(ClockReading(at: moment, offset: offset))
            save(camera)
            said.append("\(camera.model): clock \(OffsetText.exact(offset)), set from the offset code.")
        }
        return said.joined(separator: " ")
    }

    /// The temperature each camera recorded, a photo every quarter of an hour
    /// or so, with where it was taken when known.
    func noteTemperatures(_ photos: [ScannedPhoto], personId: UUID, tool: ExifTool) async {
        var picked: [(photo: ScannedPhoto, camera: Camera, at: Date)] = []
        var last: [UUID: Date] = [:]
        let rowsByPath = Dictionary(rows.map { ($0.photo.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        for photo in photos {
            guard let model = photo.model, let camera = book.camera(personId: personId, model: model),
                  case .success(let at) = Moments.moment(photo, camera: camera) else { continue }
            if let previous = last[camera.id], abs(at.timeIntervalSince(previous)) < 900 { continue }
            last[camera.id] = at
            picked.append((photo, camera, at))
        }
        guard !picked.isEmpty else { return }
        let urls = picked.map(\.photo.url)
        let read = await Task.detached { TemperatureReader.read(urls, exifTool: tool) }.value
        guard !read.isEmpty else { return }
        var next = temperatures
        for item in picked {
            guard let celsius = read[item.photo.url.path] else { continue }
            var sample = TemperatureSample(at: item.at, celsius: celsius)
            if case .matched(let p)? = rowsByPath[item.photo.url.path]?.placement {
                sample.lat = p.lat
                sample.lon = p.lon
            } else if let lat = item.photo.ownLat, let lon = item.photo.ownLon {
                sample.lat = lat
                sample.lon = lon
            }
            next.add([sample], camera: item.camera.id)
        }
        temperatures = next
        try? temperatureStore.save(next)
    }

    /// A week after a camera's last offset code photo, and each week after,
    /// one notification to take another (David, 1 November 2026).
    public func remindClocks(now: Date = Date()) {
        var reminded = defaults.dictionary(forKey: "clockReminders") as? [String: Double] ?? [:]
        for camera in book.cameras {
            guard let lastReading = camera.readings.last?.at else { continue }
            let since = max(lastReading.timeIntervalSince1970, reminded[camera.id.uuidString] ?? 0)
            guard now.timeIntervalSince1970 - since >= 7 * 86_400 else { continue }
            let owner = book.person(camera.personId).map { "\($0.name)'s " } ?? ""
            notifier.post("Time to photograph the offset code with \(owner)\(camera.model).", kind: "clock-\(camera.id.uuidString)")
            reminded[camera.id.uuidString] = now.timeIntervalSince1970
        }
        defaults.set(reminded, forKey: "clockReminders")
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

    /// Every photo placed again: after a card is read, a camera changes, the
    /// gap changes, or new tracks arrive.
    public func rematch() {
        Task { await placeLater() }
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
            // Dates still to correct: what the camera's error now calls for, less what was done at saving.
            let shift = dateShift(entry.photo, personId: entry.personId) - entry.shifted
            if let problem = await Task.detached(operation: { saver.addLocation(to: url, position, shift: shift) }).value {
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

    /// Whether one of the tracks runs within a day of any of these photos, by
    /// their cameras' clocks as set. Without one the map has nothing to line
    /// them up with, so it does not open by itself after a card is read
    /// (David, 18 October 2026); See photos on the map still opens it.
    public func trackNear(_ rows: [ImportRow]) -> Bool {
        guard let personId = importPerson else { return false }
        var hours = Set<Int>()
        for row in rows {
            guard let model = row.photo.model, var camera = book.camera(personId: personId, model: model) else { continue }
            camera.offsetSeconds = camera.offsetSeconds ?? 0
            if case .success(let moment) = Moments.moment(row.photo, camera: camera) {
                hours.insert(Int(moment.timeIntervalSince1970) / 3600)
            }
        }
        let pieces = timeline.pieces
        return hours.contains { hour in
            let t = hour * 3600
            return pieces.contains { $0.start - 86_400 <= t + 3600 && t <= $0.end + 86_400 }
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
            say(meter.count == 0 ? "Paused." : meter.count == 1 ? "Pausing after this photo." : "Pausing after these \(meter.count) photos.")
        } else {
            nextTry = nil
            say("")
        }
    }

    public func setSendAtOnce(_ count: Int) {
        sendAtOnce = min(max(count, 1), 6)
        defaults.set(sendAtOnce, forKey: "sendAtOnce")
    }

    /// Keeps this Mac and iCloud the same: what changed on either side goes
    /// to the other, the lists of photos read combined (0.21.0).
    public func syncWithCloud() async {
        guard let folder = cloudFolder,
              let people = peopleStore as? PeopleStoreFile,
              let history = history as? HistoryStoreFolder,
              let temperatures = temperatureStore as? TemperatureStoreFile else {
            cloudProblem = "iCloud Drive is off on this Mac."
            return
        }
        let all = defaults.dictionaryRepresentation()
        var settings: [String: Any] = [:]
        for key in CloudCopy.sharedKeys { if let value = all[key] { settings[key] = value } }
        nonisolated(unsafe) let shared = settings
        let seen = defaults.data(forKey: cloudSeenKey).flatMap { try? JSONDecoder().decode(CloudSync.Seen.self, from: $0) } ?? CloudSync.Seen()
        let local = CloudSync.Local(people: people.url, temperatures: temperatures.url, history: history.folder,
                                    macName: Host.current().localizedName ?? "This Mac")
        let outcome: Result<CloudSync.Outcome, Error> = await Task.detached {
            Result { try CloudSync.sync(local, settings: shared, seen: seen, into: folder) }
        }.value
        switch outcome {
        case .success(let done):
            cloudProblem = nil
            if let data = try? JSONEncoder().encode(done.seen) { defaults.set(data, forKey: cloudSeenKey) }
            if done.peopleTaken, let book = try? peopleStore.load() {
                if self.book.people.isEmpty { newFromCloud = true }
                self.book = book
            }
            if done.temperaturesTaken, let taken = try? temperatureStore.load() { self.temperatures = taken }
            if let taken = done.settingsTaken { takeSettings(taken) }
            if cloudMacs != done.macs { cloudMacs = done.macs }
        case .failure(let error):
            cloudProblem = "Not synced with iCloud: \(error.localizedDescription)"
        }
    }

    /// iCloud's settings in place of this Mac's, and shown at once.
    private func takeSettings(_ taken: [String: Any]) {
        for key in CloudCopy.sharedKeys {
            if let value = taken[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        openOnCard = defaults.object(forKey: "openOnCard") as? Bool ?? true
        maxGapSeconds = defaults.object(forKey: "maxGapSeconds") != nil ? defaults.integer(forKey: "maxGapSeconds") : 120
        if defaults.object(forKey: "breakMinutes") != nil { breakMinutes = defaults.integer(forKey: "breakMinutes") }
        if defaults.object(forKey: "clockFixMinutes") != nil { clockFixMinutes = defaults.integer(forKey: "clockFixMinutes") }
        dateOrder = defaults.string(forKey: "dateOrder").flatMap(DateOrder.init(rawValue:)) ?? .system
        clock24 = defaults.object(forKey: "clock24") as? Bool
        When.current = When(order: dateOrder, clock24: clock24)
        if let raw = defaults.string(forKey: "appearance"), let mode = Appearance(rawValue: raw) { appearance = mode }
        if NSApp != nil { applyAppearance() }
        serviceAddress = defaults.string(forKey: "trackServiceAddress") ?? ""
        savedService = ServiceFields(address: serviceAddress, key: serviceKey)
        mapCredit = defaults.string(forKey: "mapCredit") ?? ""
        nasAddress = defaults.string(forKey: "nasAddress") ?? ""
        nasBackupAddress = defaults.string(forKey: "nasBackupAddress") ?? ""
        nasUser = defaults.string(forKey: "nasUser") ?? ""
        savedNAS = nasFields
        rematch()
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
    /// going by the record alone. Never one still to send, still waiting for
    /// a location, or changed since it went. An emptied day folder goes too.
    public func tidyMac(now: Date = Date()) {
        lastTidy = now
        sentSinceTidy = false
        var busy = Set(queueEntries.filter { $0.state != .sent }.map(\.localPath))
        busy.formUnion(((try? unplaced.load()) ?? []).map(\.localPath))
        let plan = MacTidy.plan(sentRecords, keep: keepOnMac, busy: busy, now: now)
        guard !plan.remove.isEmpty || !plan.gone.isEmpty else { return }
        let fm = FileManager.default
        let roots = Set(book.people.compactMap { $0.saveFolder.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
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
            .filter { $0.state == .waiting && ($0.notBefore ?? .distantPast) <= now && NASFolder(place($0)) != nil
                && !going.contains("\(place($0) ?? "")/\($0.relativePath)") }
            .min { $0.added < $1.added }
    }

    /// Sends waiting photos to the NAS, oldest first and `sendAtOnce` at a
    /// time, until nothing more can go now, the NAS can't be reached, or
    /// sending is paused. Called every few seconds from launch; the queue is
    /// on disk, so it carries on after a restart.
    public func sendWaiting() async {
        guard !sendingNow, !sendPaused else { return }
        if let next = nextTry, Date() < next { return }
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
                    all[i].reason = "Their person was removed from People"
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
                    guard let place = NASFolder(book.person(entry.personId)?.nasFolder) else { break }
                    let connection: NASConnection
                    do {
                        connection = try await nas.connect(share: place.share)
                    } catch {
                        nasReach = .unreachable
                        let retry = Date().addingTimeInterval(60)
                        nextTry = retry
                        halt = "\(error.localizedDescription) Trying again at \(When.current.time(retry))."
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
                    halt = "NAS full. Trying again at \(When.current.time(retry))."
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
        // Every ten minutes, and straight after a send when copies go as soon as they are on the NAS.
        if lastTidy.map({ Date().timeIntervalSince($0) > 600 }) ?? true || (sentSinceTidy && keepOnMac == .untilOnNAS) { tidyMac() }
    }

    /// "IMG_0001.JPG to nas. 12 more waiting, about 20 min left. Slow.", or
    /// with several going up, "3 photos to nas at once. ..." Said again as
    /// photos move along and the queue changes, so it never goes stale.
    private func sayGoing() {
        guard let address = sendingThrough, meter.count > 0, !sendPaused else { return }
        let host = NASOverSMB.host(address) ?? address
        let more = queueEntries.filter { $0.state == .waiting }.count
        let going = meter.only.map { "\($0.name) to \(host)." } ?? "\(meter.count) photos to \(host) at once."
        var line = going + (more == 0 ? "" : " \(more) more waiting") + (sendingLeft().map { ", \($0) left." } ?? (more == 0 ? "" : "."))
        if let word = sendingSpeed() { line += " \(word.rawValue)." }
        say(line)
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
        let tool = exifTool, update = entry.update, meter = self.meter, id = entry.id
        let clock = StepClock()
        let before = SentRecord.stamp(entry.localPath)
        // On a thread of its own: a connection that hangs must not hold up
        // the threads the rest of Geotag runs on.
        let outcome: Result<SendOutcome, NASError> = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                do {
                    done.resume(returning: .success(try NASSender.send(local, as: name, into: folder, update: update,
                                                                       clean: clean, exifTool: tool) { step in
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
        guard let address = sendingThrough else { return nil }
        let ahead = queueEntries.filter { $0.state == .waiting && NASFolder(book.person($0.personId)?.nasFolder) != nil }
        var bytes = ahead.reduce(0.0) { $0 + Double(size(of: $1)) }
        for entry in queueEntries where entry.state == .sending {
            bytes += Double(size(of: entry)) * (1 - (meter.going[entry.id]?.fraction ?? 0))
        }
        return sendSpeeds.seconds(for: bytes, through: address).map(Remaining.text)
    }

    /// What the menu bar icon shows while Geotag works: the Photos page's own
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
            lines.append("Sending to the NAS: \((done + now).formatted()) of \(total.formatted())" + (sendingLeft().map { ", \($0) left" } ?? ""))
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
        // At once, so no line from before stays up while the tracks come in.
        tracksLine = "Loading tracks"
        if role == nil { await testService() }
        guard let role else {
            tracks = await library.listed()
            tracksLine = settingsLine
            return
        }
        await loadMaps(service)
        if thumbnails.forgetFailures() { mapsRound += 1 }
        let report = await library.refresh(service: service, role: role, pullStrava: pullStrava) { @MainActor [weak self] done, total in
            self?.tracksLine = "Loading tracks: \(done.formatted()) of \(total.formatted())"
        }
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
