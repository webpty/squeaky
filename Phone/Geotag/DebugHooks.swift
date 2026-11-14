#if DEBUG
import Foundation
import GeotagCore

/// Checks run in the simulator only, never in the phone's build: with
/// `--write-test <folder> <out>`, every CR3 and JPG in the folder is saved
/// with a location by the phone's own writer, its check run on the phone's
/// own photo reader, and the outcome printed.
enum DebugHooks {
    static func run() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--write-test"), args.count > i + 2 else { return }
        let folder = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
        let files = PhotoScanner.files(in: folder).filter { NativeMetadata.kind($0) != nil }
        let photos = NativeMetadata.scan(files) { _ in }
        var failed = 0
        for (n, photo) in photos.enumerated() {
            let alt: Double? = [123.45, 0, -0.5, nil][n % 4]
            let spot = Position(lat: -54.8019123, lon: -68.3029456, alt: alt, moment: Date(timeIntervalSince1970: 1_794_316_131.5), fromPoint: 0)
            let saver = Saver(engine: .native, folder: out.appendingPathComponent("\(n)"))
            let result = saver.save(SaveItem(photo: photo, placement: .matched(spot), withoutLocation: false, shift: n % 3 == 0 ? 3600 : 0))
            if case .saved = result { print("pass  \(photo.fileName)") } else { failed += 1; print("FAIL  \(photo.fileName)  \(result)") }
        }
        print(failed == 0 ? "phone writer: all \(photos.count) passed" : "phone writer: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
