#if DEBUG
import Foundation
import GeotagCore
import GeotagUI

/// The whole of it in the simulator only: `--flow-test <card> <gpx> <nas>`
/// reads a stand-in card, places its photos on a track, saves them on the
/// phone and sends them to a stand-in NAS folder, then prints what happened.
extension DebugHooks {
    @MainActor
    static func flow(_ model: AppModel) async -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--flow-test"), args.count > i + 3 else { return false }
        setvbuf(stdout, nil, _IOLBF, 0)
        // Each line also written beside the stand-in NAS, as it is said.
        let trace = URL(fileURLWithPath: args[i + 3] + ".trace")
        FileManager.default.createFile(atPath: trace.path, contents: nil)
        func print(_ line: String) {
            Swift.print(line)
            if let h = try? FileHandle(forWritingTo: trace) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() }
        }
        let card = URL(fileURLWithPath: args[i + 1]), gpx = URL(fileURLWithPath: args[i + 2]), nas = URL(fileURLWithPath: args[i + 3])
        model.setPhonePerson(name: "Flow")
        guard let owner = model.macOwner, model.book.people.filter({ $0.id != PhoneFolders.othersId }).count == 1 else { print("flow: FAILED, no person"); return true }
        // `--no-folder`: a phone set up with the buffer key only (0.30.4).
        if !args.contains("--no-folder") { try? PhoneFolders.remember(nas, as: PhoneFolders.nasKey) }
        print("starting")
        await model.start()
        print("started")
        await model.importFiles([gpx])
        print("tracks: \(model.tracks.count) \(model.tracksLine)")
        print("card read starting")
        let source = PhotoSource(id: "flow-card", name: "FLOWCARD", url: card, isCard: true)
        model.choose(source)
        guard model.askingWhose != nil else { print("flow: FAILED, a new card was not asked about"); return true }
        await model.read(source, for: owner)
        while model.saving || model.photosBusy { try? await Task.sleep(for: .milliseconds(200)) }
        // The camera came from the card, with no offset yet: nothing saved by itself.
        guard var camera = model.book.camera(personId: owner, model: "Canon EOS R5m2"), camera.offsetSeconds == nil,
              model.results.isEmpty else { print("flow: FAILED, camera not added from the card, or saved without an offset"); return true }
        print("camera added from the card: \(camera.model), \(model.photosLine)")
        // Selected before the offset is set: Save selected photos is on, the choice the
        // person's (0.31.8; 0.31.4 held them). Not saved here, so they save with a location below.
        model.setTicked(Set(model.rows.map(\.id)), true)
        let noOffset = model.readyToSave.filter { $0.placement == .review(.offsetNotSet) }.count
        guard model.canSave, noOffset == model.rows.count else { print("flow: FAILED, Save selected photos off without an offset (\(noOffset))"); return true }
        print("without an offset: Save selected photos is on, \(noOffset) photos would go without a location")
        camera.offsetSeconds = 0
        model.save(camera)
        // `--buffer <address> <key>`: sent through a stand-in buffer server instead (0.30.0).
        let viaBuffer = args.firstIndex(of: "--buffer").flatMap { b in args.count > b + 2 ? (args[b + 1], args[b + 2]) : nil }
        if let (address, key) = viaBuffer {
            model.bufferAddress = address
            model.bufferKey = key
            await model.saveBuffer()
            print("buffer: \(model.bufferLine)")
        }
        model.setTicked(Set(model.rows.map(\.id)), true); await model.savePhotos()
        while model.saving || model.photosBusy { try? await Task.sleep(for: .milliseconds(200)) }
        print("photos line: \(model.photosLine)")
        for row in model.rows {
            print("  \(row.photo.fileName): \(String(describing: row.placement)) -> \(String(describing: model.results[row.id]))")
        }
        // The card read again, everything selected again and saved again: nothing copied twice (0.31.8).
        let savedOnce = model.results.values.filter { $0.url != nil }.count
        model.choose(source)
        try? await Task.sleep(for: .milliseconds(300))
        while model.saving || model.photosBusy { try? await Task.sleep(for: .milliseconds(200)) }
        model.setTicked(Set(model.rows.map(\.id)), true)
        await model.savePhotos()
        while model.saving || model.photosBusy { try? await Task.sleep(for: .milliseconds(200)) }
        print("saved again: \(model.photosLine)")
        guard model.results.values.filter({ $0.url != nil }).count == 0, savedOnce == model.rows.count,
              model.photosLine.contains("\(model.rows.count)") else { print("flow: FAILED, copied twice"); return true }
        let until = Date().addingTimeInterval(120)
        while Date() < until, model.queueEntries.contains(where: { $0.state != .sent && $0.state != .failed }) {
            try? await Task.sleep(for: .seconds(1))
        }
        var ok = !model.rows.isEmpty
        for entry in model.queueEntries {
            print("  queue \(entry.relativePath): \(entry.state) \(entry.reason ?? "")")
            if entry.state != .sent { ok = false }
        }
        if let (address, key) = viaBuffer {
            print("  route: \(String(describing: model.sendRoute)), waiting on the buffer server: \(String(describing: model.bufferWaiting))")
            if model.sendRoute != .buffer { ok = false }
            // The sync list kept at the buffer server too (0.31.8).
            await model.shareWithServer()
            if let client = BufferClient(address: address, key: key),
               let data = try? await client.readList("home/Geotag/~Geotag/saved.json"),
               let list = try? ServerList.decodeSaved(data) {
                print("  sync list at the buffer server: \(list.entries.count) photos, by \(list.updatedBy)")
                if list.entries.count != model.rows.count { ok = false }
            } else {
                print("  sync list at the buffer server: none")
                ok = false
            }
            print(ok ? "flow: all passed" : "flow: FAILED")
            return true
        }
        let landed = PhotoScanner.files(in: nas)
        for url in landed {
            let d = try? NativeMetadata.read(url)
            print("  on the NAS: \(url.path.replacingOccurrences(of: nas.path, with: "")) \(d?.lat ?? 0) \(d?.lon ?? 0) \(d?.alt ?? 0)")
            if d?.lat == nil { ok = false }
        }
        if landed.count != model.rows.count { ok = false }
        model.tidyMac(now: Date().addingTimeInterval(90 * 86_400))
        let isJPG = { (path: String) in ["jpg", "jpeg"].contains((path as NSString).pathExtension.lowercased()) }
        let jpgs = model.queueEntries.filter { isJPG($0.localPath) }
        let raws = model.queueEntries.filter { !isJPG($0.localPath) }
        let keptJPG = jpgs.filter { FileManager.default.fileExists(atPath: $0.localPath) }.count
        let keptRaw = raws.filter { FileManager.default.fileExists(atPath: $0.localPath) }.count
        print("  90 days on: \(keptJPG) of \(jpgs.count) JPGs kept on the phone, \(keptRaw) of \(raws.count) raws left on it")
        // Every copy leaves once on the server: the JPGs are in the Photos library (0.29.15).
        if keptJPG != 0 || keptRaw != 0 || raws.isEmpty || jpgs.isEmpty { ok = false }
        // Someone else's card: saved with locations on the phone, never sent.
        let before = model.queueEntries.count
        let theirs = PhotoSource(id: "flow-card-theirs", name: "THEIRCARD", url: card, isCard: true)
        model.choose(theirs)
        await model.read(theirs, for: PhoneFolders.othersId)
        if var camera = model.book.camera(personId: PhoneFolders.othersId, model: "Canon EOS R5m2") {
            camera.offsetSeconds = 0
            model.save(camera)
        }
        model.setTicked(Set(model.rows.map(\.id)), true); await model.savePhotos()
        while model.saving || model.photosBusy { try? await Task.sleep(for: .milliseconds(200)) }
        let others = PhotoScanner.files(in: PhoneFolders.copies.appendingPathComponent("Others"))
        let savedOthers = model.results.values.filter { $0.url != nil }.count
        print("  someone else's card: \(savedOthers) saved, \(others.count) copies left on the phone, queue \(before) then \(model.queueEntries.count)")
        let otherRaws = others.filter { !isJPG($0.path) }.count
        print("  someone else's card: \(otherRaws) raws saved")
        if savedOthers != model.rows.count || !others.isEmpty || model.queueEntries.count != before || otherRaws != 0 { ok = false }
        if model.photosLine.contains("Photos:") { print("  \(model.photosLine)"); ok = false }
        // Remembered: the same card again is not asked about.
        model.choose(theirs)
        if model.askingWhose != nil { ok = false; print("  asked again about a card it knows") }
        print(ok ? "flow: all passed" : "flow: FAILED")
        return true
    }
}
#endif

#if DEBUG
extension DebugHooks {
    /// `--watch-test <card>`: a remembered card is read by itself, and not
    /// again once let go of while it is still in.
    @MainActor
    static func watch(_ model: AppModel) async -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--watch-test"), args.count > i + 1 else { return false }
        let card = URL(fileURLWithPath: args[i + 1])
        model.setPhonePerson(name: "Watch")
        guard let owner = model.macOwner else { print("watch: FAILED, no person"); return true }
        var people = UserDefaults.standard.dictionary(forKey: "cardPeople") as? [String: String] ?? [:]
        people["watch-card"] = owner.uuidString
        UserDefaults.standard.set(people, forKey: "cardPeople")
        CardWatch.remember(card, id: "watch-card")
        let watch = CardWatch(model: model)
        watch.start()
        try? await Task.sleep(for: .seconds(5))
        while model.photosBusy || model.saving { try? await Task.sleep(for: .milliseconds(200)) }
        let found = model.source?.id == "watch-card" && !model.rows.isEmpty
        print("  read by itself: \(found), \(model.rows.count) photos")
        model.letGo()
        try? await Task.sleep(for: .seconds(8))
        let stayed = model.source == nil
        print("  not read again once let go of: \(stayed)")
        watch.stop()
        print(found && stayed ? "watch: all passed" : "watch: FAILED")
        return true
    }
}
#endif

#if DEBUG
extension DebugHooks {
    /// `--show-card <card>`: the card read as a remembered one, for a picture
    /// of the Photos tab; the app then runs as usual.
    @MainActor
    static func show(_ model: AppModel) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--show-card"), args.count > i + 1 else { return }
        model.setPhonePerson(name: "Show")
        guard let owner = model.macOwner else { return }
        var people = UserDefaults.standard.dictionary(forKey: "cardPeople") as? [String: String] ?? [:]
        people["show-card"] = owner.uuidString
        UserDefaults.standard.set(people, forKey: "cardPeople")
        let source = PhotoSource(id: "show-card", name: "EOS_DIGITAL", url: URL(fileURLWithPath: args[i + 1]), isCard: true)
        // With a track file after it: the camera set and the panel before saving shown.
        if args.count > i + 2, args[i + 2].hasSuffix(".gpx") {
            await model.importFiles([URL(fileURLWithPath: args[i + 2])])
            var camera = Camera(personId: owner, model: "Canon EOS R5m2", zone: .fromPhoto, offsetSeconds: 0)
            camera.offsetSet = Date()
            model.save(camera)
        }
        model.choose(source)
        if args.contains("--save") {
            try? await Task.sleep(for: .seconds(3))
            while model.photosBusy { try? await Task.sleep(for: .milliseconds(200)) }
            model.dontSave()
            model.setTicked(Set(model.rows.map(\.id)), true); await model.savePhotos()
        }
    }
}
#endif

#if DEBUG
extension DebugHooks {
    /// `--pull-test <card> <gpx>`: the card taken away after the first photo
    /// saved; the save must stop there, the rest not marked as failed.
    @MainActor
    static func pull(_ model: AppModel) async -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--pull-test"), args.count > i + 2 else { return false }
        let card = URL(fileURLWithPath: args[i + 1]), gpx = URL(fileURLWithPath: args[i + 2])
        model.setPhonePerson(name: "Pull")
        guard let owner = model.macOwner else { return true }
        await model.importFiles([gpx])
        var camera = Camera(personId: owner, model: "Canon EOS R5m2", zone: .fromPhoto, offsetSeconds: 0)
        camera.offsetSet = Date()
        model.save(camera)
        let source = PhotoSource(id: "pull-card", name: "PULLCARD", url: card, isCard: true)
        var people = UserDefaults.standard.dictionary(forKey: "cardPeople") as? [String: String] ?? [:]
        people["pull-card"] = owner.uuidString
        UserDefaults.standard.set(people, forKey: "cardPeople")
        model.choose(source)
        try? await Task.sleep(for: .seconds(1))
        while model.photosBusy || model.trackCheck == .checking { try? await Task.sleep(for: .milliseconds(100)) }
        model.dontSave()
        guard model.source != nil, !model.rows.isEmpty else { print("pull: FAILED, the card was not read"); return true }
        let saving = Task { model.setTicked(Set(model.rows.map(\.id)), true); await model.savePhotos() }
        let until = Date().addingTimeInterval(30)
        while model.results.isEmpty, Date() < until { try? await Task.sleep(for: .milliseconds(20)) }
        let away = card.deletingLastPathComponent().appendingPathComponent(card.lastPathComponent + "-away")
        try? FileManager.default.moveItem(at: card, to: away)
        await saving.value
        try? FileManager.default.moveItem(at: away, to: card)
        let failed = model.results.values.filter { if case .failed = $0 { return true }; return false }.count
        print("  line: \(model.photosLine)")
        print("  \(model.results.count) results, \(failed) failed, card let go: \(model.source == nil)")
        print(failed == 0 && model.results.count < model.rows.count && model.photosLine.hasPrefix("The card stopped answering")
              && model.source == nil ? "pull: all passed" : "pull: FAILED")
        return true
    }
}
#endif

#if DEBUG
extension DebugHooks {
    /// `--list-test <card> <server>`: a phone that never read the sync files
    /// reads them before deciding what is new on the card (0.29.17).
    @MainActor
    static func list(_ model: AppModel) async -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--list-test"), args.count > i + 2 else { return false }
        let card = URL(fileURLWithPath: args[i + 1]), server = URL(fileURLWithPath: args[i + 2])
        model.setPhonePerson(name: "List")
        guard let owner = model.macOwner else { return true }
        try? PhoneFolders.remember(server, as: PhoneFolders.nasKey)
        var people = UserDefaults.standard.dictionary(forKey: "cardPeople") as? [String: String] ?? [:]
        people["list-card"] = owner.uuidString
        UserDefaults.standard.set(people, forKey: "cardPeople")
        model.choose(PhotoSource(id: "list-card", name: "LISTCARD", url: card, isCard: true))
        try? await Task.sleep(for: .seconds(1))
        while model.photosBusy { try? await Task.sleep(for: .milliseconds(100)) }
        let before = model.rows.filter { $0.status == .alreadyImported }.count
        print("  \(before) of \(model.rows.count) already saved; problem: \(model.savedListProblem ?? "none")")
        print(before == model.rows.count && model.savedListProblem == nil ? "list: all passed" : "list: FAILED")
        return true
    }
}
#endif
