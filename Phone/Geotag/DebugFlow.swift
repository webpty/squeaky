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
        guard let owner = model.macOwner, model.book.people.count == 1 else { print("flow: FAILED, no person"); return true }
        try? PhoneFolders.remember(nas, as: PhoneFolders.nasKey)
        await model.start()
        await model.importFiles([gpx])
        print("tracks: \(model.tracks.count) \(model.tracksLine)")
        let source = PhotoSource(id: "flow-card", name: "FLOWCARD", url: card, isCard: true)
        model.choose(source)
        if model.askingWhose != nil { print("flow: FAILED, asked whose card it is"); return true }
        try? await Task.sleep(for: .seconds(1))
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
        let kept = model.queueEntries.filter { FileManager.default.fileExists(atPath: $0.localPath) }.count
        print("  kept on the phone 90 days on: \(kept) of \(model.queueEntries.count)")
        if kept != model.queueEntries.count { ok = false }
        print(ok ? "flow: all passed" : "flow: FAILED")
        return true
    }
}
#endif
