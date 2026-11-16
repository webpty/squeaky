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
        let card = URL(fileURLWithPath: args[i + 1]), gpx = URL(fileURLWithPath: args[i + 2]), nas = URL(fileURLWithPath: args[i + 3])
        model.setPhonePerson(name: "Flow")
        guard let owner = model.macOwner, model.book.people.filter({ $0.id != PhoneFolders.othersId }).count == 1 else { print("flow: FAILED, no person"); return true }
        try? PhoneFolders.remember(nas, as: PhoneFolders.nasKey)
        await model.start()
        await model.importFiles([gpx])
        print("tracks: \(model.tracks.count) \(model.tracksLine)")
        let source = PhotoSource(id: "flow-card", name: "FLOWCARD", url: card, isCard: true)
        model.choose(source)
        guard model.askingWhose != nil else { print("flow: FAILED, a new card was not asked about"); return true }
        await model.read(source, for: owner)
        while model.saving || model.photosBusy { try? await Task.sleep(for: .milliseconds(200)) }
        // The camera came from the card, with no offset yet: nothing saved by itself.
        guard var camera = model.book.camera(personId: owner, model: "Canon EOS R5m2"), camera.offsetSeconds == nil,
              model.results.isEmpty else { print("flow: FAILED, camera not added from the card, or saved without an offset"); return true }
        print("camera added from the card: \(camera.model), \(model.photosLine)")
        camera.offsetSeconds = 0
        model.save(camera)
        await model.savePhotos()
        while model.saving || model.photosBusy { try? await Task.sleep(for: .milliseconds(200)) }
        print("photos line: \(model.photosLine)")
        for row in model.rows {
            print("  \(row.photo.fileName): \(String(describing: row.placement)) -> \(String(describing: model.results[row.id]))")
        }
        let until = Date().addingTimeInterval(120)
        while Date() < until, model.queueEntries.contains(where: { $0.state != .sent && $0.state != .failed }) {
            try? await Task.sleep(for: .seconds(1))
        }
        var ok = !model.rows.isEmpty
        for entry in model.queueEntries {
            print("  queue \(entry.relativePath): \(entry.state) \(entry.reason ?? "")")
            if entry.state != .sent { ok = false }
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
        if keptJPG != jpgs.count || keptRaw != 0 || raws.isEmpty { ok = false }
        // Someone else's card: saved with locations on the phone, never sent.
        let before = model.queueEntries.count
        let theirs = PhotoSource(id: "flow-card-theirs", name: "THEIRCARD", url: card, isCard: true)
        model.choose(theirs)
        await model.read(theirs, for: PhoneFolders.othersId)
        if var camera = model.book.camera(personId: PhoneFolders.othersId, model: "Canon EOS R5m2") {
            camera.offsetSeconds = 0
            model.save(camera)
        }
        await model.savePhotos()
        while model.saving || model.photosBusy { try? await Task.sleep(for: .milliseconds(200)) }
        let others = PhotoScanner.files(in: PhoneFolders.documents.appendingPathComponent("Others"))
        let placedThere = others.filter { (try? NativeMetadata.read($0))?.lat != nil }.count
        print("  someone else's card: \(placedThere) of \(others.count) with a location in Others, queue \(before) then \(model.queueEntries.count)")
        let otherRaws = others.filter { !isJPG($0.path) }.count
        print("  someone else's card: \(otherRaws) raws saved")
        if others.count != model.rows.count || placedThere != others.count || model.queueEntries.count != before || otherRaws != 0 { ok = false }
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
    }
}
#endif
