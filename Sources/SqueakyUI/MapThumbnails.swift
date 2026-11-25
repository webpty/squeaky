import SqueakyCore
import UIKit

/// The phone's map pictures (0.29.4, David, 16 November 2026), as the Mac's:
/// wordless OpenStreetMap tiles from CARTO, named by the track service, with
/// the route drawn on top, in blue on the phone. Kept on the phone once made.
@MainActor
public final class MapThumbnails: ObservableObject {
    public static let size = CGSize(width: 120, height: 90)
    /// Maps asked for and made in this round, for "Making maps: 3 of 40" (0.29.16).
    @Published public private(set) var asked = 0
    @Published public private(set) var made = 0
    static let scale: CGFloat = 3
    public static let lineColour = UIColor.systemBlue

    let folder: URL
    public var source: MapSource?
    private var memory: [String: UIImage] = [:]
    private var failedAt: [String: Date] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let gate = Gate(limit: 3)

    public init(folder: URL = MapThumbnails.standardFolder()) {
        self.folder = folder
    }

    public nonisolated static func standardFolder() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Squeaky/Maps", isDirectory: true)
    }

    private func fileURL(_ id: String, dark: Bool) -> URL {
        folder.appendingPathComponent("\(id)-phone-\(dark ? "dark" : "light").png")
    }

    public func cached(_ id: String, dark: Bool) -> UIImage? {
        let key = "\(id)-\(dark)"
        if let image = memory[key] { return image }
        guard let data = try? Data(contentsOf: fileURL(id, dark: dark)), let image = UIImage(data: data, scale: Self.scale) else { return nil }
        memory[key] = image
        return image
    }

    /// The picture, or nil when the map cannot be had: no key yet, or no
    /// internet. A failure waits a minute, or the next refresh.
    public func make(_ track: Track, points: TrackPoints, dark: Bool) async -> UIImage? {
        if let image = cached(track.id, dark: dark) { return image }
        guard let source, let key = source.key, !key.isEmpty else { return nil }
        let memoKey = "\(track.id)-\(dark)"
        if let failed = failedAt[memoKey], Date().timeIntervalSince(failed) < 60 { return nil }
        if let running = inFlight[memoKey] { return await running.value }
        if asked == made { asked = 0; made = 0 }
        asked += 1
        defer { made += 1 }
        let file = fileURL(track.id, dark: dark)
        let gate = self.gate
        let task = Task { () -> UIImage? in
            await gate.enter()
            let png = await Self.render(points: points, bounds: track.bounds, template: dark ? source.dark : source.light, key: key)
            await gate.leave()
            guard let png, let image = UIImage(data: png, scale: Self.scale) else { return nil }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
            return image
        }
        inFlight[memoKey] = task
        let image = await task.value
        inFlight[memoKey] = nil
        if let image { memory[memoKey] = image } else { failedAt[memoKey] = Date() }
        return image
    }

    public func forgetFailures() -> Bool {
        defer { failedAt = [:] }
        return !failedAt.isEmpty
    }

    public nonisolated static func project(_ lat: Double, _ lon: Double, _ z: Int) -> CGPoint {
        let world = 256 * pow(2, Double(z))
        let la = max(min(lat, 85.0511), -85.0511) * .pi / 180
        return CGPoint(x: (lon + 180) / 360 * world, y: (1 - log(tan(la) + 1 / cos(la)) / .pi) / 2 * world)
    }

    nonisolated static func zoom(_ b: Bounds, size: CGSize) -> Int {
        for z in stride(from: 17, through: 1, by: -1) {
            let a = project(b.maxLat, b.minLon, z), c = project(b.minLat, b.maxLon, z)
            if (c.x - a.x) * 1.3 <= size.width && (c.y - a.y) * 1.3 <= size.height { return z }
        }
        return 1
    }

    /// A track's map as large as the screen allows, the route framed to fit
    /// (0.29.35, David, 17 November 2026: "a big image like the others").
    /// Kept on the phone once made, by its size.
    public func large(_ track: Track, points: TrackPoints, dark: Bool, size: CGSize) async -> UIImage? {
        let size = CGSize(width: size.width.rounded(.down), height: size.height.rounded(.down))
        guard size.width > 40, size.height > 40 else { return nil }
        let file = folder.appendingPathComponent("\(track.id)-phone-large-\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light").png")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data, scale: Self.scale) { return image }
        guard let source, let key = source.key, !key.isEmpty else { return nil }
        guard let png = await Self.render(points: points, bounds: track.bounds, template: dark ? source.dark : source.light,
                                          key: key, size: size, thin: 2000, lineWidth: 4) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: file, options: .atomic)
        return UIImage(data: png, scale: Self.scale)
    }

    static func render(points: TrackPoints, bounds: Bounds, template: String, key: String,
                       size: CGSize = MapThumbnails.size, thin: Int = 400, lineWidth: CGFloat = 2.5) async -> Data? {
        let z = zoom(bounds, size: size)
        let a = project(bounds.maxLat, bounds.minLon, z), c = project(bounds.minLat, bounds.maxLon, z)
        let left = (((a.x + c.x) / 2 - size.width / 2) * scale).rounded() / scale
        let top = (((a.y + c.y) / 2 - size.height / 2) * scale).rounded() / scale
        let tiles = 1 << z
        var images: [(x: Int, y: Int, image: UIImage)] = []
        for ty in Int(floor(top / 256))...Int(floor((top + size.height) / 256)) {
            guard ty >= 0, ty < tiles else { continue }
            for tx in Int(floor(left / 256))...Int(floor((left + size.width) / 256)) {
                let wrapped = ((tx % tiles) + tiles) % tiles
                var text = template.replacingOccurrences(of: "{z}", with: String(z))
                    .replacingOccurrences(of: "{x}", with: String(wrapped)).replacingOccurrences(of: "{y}", with: String(ty))
                text += (text.contains("?") ? "&" : "?") + "key=" + (key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key)
                guard let url = URL(string: text), let image = await tile(url) else { return nil }
                images.append((tx, ty, image))
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let line = thinned(points, to: thin).map { project($0.0, $0.1, z) }.map { CGPoint(x: $0.x - left, y: $0.y - top) }
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for t in images {
                t.image.draw(in: CGRect(x: CGFloat(t.x) * 256 - left, y: CGFloat(t.y) * 256 - top, width: 256, height: 256))
            }
            let path = UIBezierPath()
            for (i, p) in line.enumerated() { if i == 0 { path.move(to: p) } else { path.addLine(to: p) } }
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.lineWidth = lineWidth + 1.5
            UIColor.white.withAlphaComponent(0.85).setStroke()
            path.stroke()
            path.lineWidth = lineWidth
            lineColour.setStroke()
            path.stroke()
        }
        return image.pngData()
    }

    static func tile(_ url: URL) async -> UIImage? {
        var request = URLRequest(url: url)
        request.setValue("Squeaky/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(700 * attempt)) }
            if let (data, response) = await fetched(request),
               (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) {
                return image
            }
        }
        return nil
    }

    public nonisolated static func thinned(_ p: TrackPoints, to count: Int) -> [(Double, Double)] {
        guard p.count > count else { return zip(p.lat, p.lon).map { ($0, $1) } }
        let step = Double(p.count - 1) / Double(count - 1)
        return (0..<count).map { i in
            let k = Int((Double(i) * step).rounded())
            return (p.lat[k], p.lon[k])
        }
    }
}

/// Lets a few callers through at a time; the rest wait their turn.
actor Gate {
    private let limit: Int
    private var inside = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func enter() async {
        if inside < limit { inside += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { inside -= 1 } else { waiting.removeFirst().resume() }
    }
}

/// One request for a map tile, reported to `NetHealth` (0.31.8).
func fetched(_ request: URLRequest) async -> (Data, URLResponse)? {
    do {
        let answer = try await URLSession.shared.data(for: request)
        NetHealth.shared.through()
        return answer
    } catch {
        NetHealth.shared.failed(error)
        return nil
    }
}
