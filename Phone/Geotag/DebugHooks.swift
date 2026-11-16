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

#if DEBUG
import ImageIO
extension DebugHooks {
    /// `--time-test <folder> <out>`: how long each step of saving takes, per file.
    static func time() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--time-test"), args.count > i + 2 else { return }
        let folder = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let spot = Position(lat: -54.8, lon: -68.3, alt: 10, moment: Date(timeIntervalSince1970: 1_794_316_131), fromPoint: 0)
        var totals: [String: Double] = [:]
        func step(_ name: String, _ work: () -> Void) {
            let t = Date()
            work()
            totals[name, default: 0] += Date().timeIntervalSince(t)
        }
        let files = PhotoScanner.files(in: folder).filter { NativeMetadata.kind($0) != nil }
        for (n, url) in files.enumerated() {
            let copy = out.appendingPathComponent("\(n)-" + url.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            step("1 read details", { _ = NativeMetadata.scan([url]) { _ in } })
            step("2 copy from card", { try? FileManager.default.copyItem(at: url, to: copy) })
            step("3 write location", { _ = try? NativeMetadata.write(into: copy, original: url, position: spot, shift: 0) })
            step("4 compare byte for byte", { _ = NativeMetadata.compare(copy: copy, original: url,
                                                                         patches: (try? NativeMetadata.patches(for: url, position: spot, shift: 0)) ?? []) })
            step("5 read back", { _ = try? NativeMetadata.read(copy) })
            step("6 open as picture", {
                if let src = CGImageSourceCreateWithURL(copy as CFURL, nil) {
                    _ = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary)
                }
            })
        }
        for (name, t) in totals.sorted(by: { $0.key < $1.key }) {
            print(String(format: "%@: %.3f s per file", name, t / Double(max(files.count, 1))))
        }
        exit(0)
    }
}
#endif
