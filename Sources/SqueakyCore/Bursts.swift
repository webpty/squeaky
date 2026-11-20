import Foundation

/// Bursts (0.29.6, David, 16 November 2026): each goes into its own folder,
/// "burst_01", "burst_02", inside its day folder. Canon records the drive
/// mode in every photo (`ScannedPhoto.drive`, its ContinuousDrive value): a
/// run of two or more frames shot in a continuous mode, slow or fast, each
/// within two seconds of the last, is a burst; a single shot never is, however
/// quick. A camera that records no drive mode: three or more frames each
/// under a second apart. RAW and JPG of one frame go together.
public enum Bursts {
    /// Canon's continuous modes: Continuous, Speed Priority, Low, High, High+, Silent.
    public static let continuous: Set<Int> = [1, 3, 4, 5, 8, 10]

    /// The bursts among these photos, each as the ids of its photos in
    /// shooting order; the bursts in shooting order too.
    public static func find(_ photos: [ScannedPhoto]) -> [[String]] {
        struct Frame {
            var at: Date
            var drive: Int?
            var ids: [String]
        }
        var byCamera: [String: [String: Frame]] = [:]
        for photo in photos {
            guard let at = Moments.clockReading(photo) else { continue }
            let camera = photo.model ?? ""
            // One frame: the same camera at the same moment, RAW and JPG alike.
            let key = "\(photo.taken ?? "")|\(photo.subSeconds ?? "")|\((photo.fileName as NSString).deletingPathExtension)"
            var frame = byCamera[camera]?[key] ?? Frame(at: at, drive: photo.drive, ids: [])
            frame.ids.append(photo.id)
            if frame.drive == nil { frame.drive = photo.drive }
            byCamera[camera, default: [:]][key] = frame
        }
        var bursts: [(at: Date, ids: [String])] = []
        for (_, frames) in byCamera {
            let sorted = frames.values.sorted { $0.at < $1.at }
            var run: [Frame] = []
            func close() {
                let known = run.first?.drive != nil
                if run.count >= (known ? 2 : 3) { bursts.append((run[0].at, run.flatMap(\.ids))) }
                run = []
            }
            for frame in sorted {
                let known = frame.drive != nil
                let inBurst = known ? continuous.contains(frame.drive!) : true
                if !inBurst { close(); continue }
                if let last = run.last {
                    let gap = frame.at.timeIntervalSince(last.at)
                    let sameKind = (last.drive != nil) == known
                    if !sameKind || gap > (known ? 2.0 : 1.0) || gap < 0 { close() }
                }
                run.append(frame)
            }
            close()
        }
        return bursts.sorted { $0.at < $1.at }.map(\.ids)
    }

    /// "burst_01": the next free number in a day folder.
    public static func nextName(in folder: URL, taken: Set<String> = []) -> String {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []) + Array(taken)
        let used = names.compactMap { name -> Int? in
            guard name.hasPrefix("burst_") else { return nil }
            return Int(name.dropFirst(6))
        }
        return String(format: "burst_%02d", (used.max() ?? 0) + 1)
    }
}
