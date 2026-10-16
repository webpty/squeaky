import AppKit
import GeotagCore

/// Small map pictures of each track: OpenStreetMap tiles with no words, as the
/// track service names them, with the line drawn on top. Each is drawn once
/// per appearance and kept on this Mac, so it shows with no internet after.
@MainActor
public final class MapThumbnails {
    public static let size = NSSize(width: 160, height: 100)
    /// The track viewer's map.
    public static let largeSize = NSSize(width: 880, height: 520)
    /// Pixels per point in the pictures kept.
    static let scale: CGFloat = 2
    public static let lineColour = NSColor(red: 0.949, green: 0.443, blue: 0.110, alpha: 1)

    let folder: URL
    public var source: MapSource?
    private var memory: [String: NSImage] = [:]
    private var failedAt: [String: Date] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// Three maps drawn at a time, so the tile server is not flooded.
    private let gate = Gate(limit: 3)

    public init(folder: URL = MapThumbnails.standardFolder()) {
        self.folder = folder
    }

    public nonisolated static func standardFolder() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Geotag/Maps", isDirectory: true)
    }

    private func fileURL(_ id: String, dark: Bool, large: Bool) -> URL {
        folder.appendingPathComponent("\(id)-osm2-\(large ? "large-" : "")\(dark ? "dark" : "light").png")
    }

    /// The picture if it was drawn before, from memory or disk.
    public func cached(_ id: String, dark: Bool, large: Bool = false) -> NSImage? {
        let key = "\(id)-\(dark)-\(large)"
        if let image = memory[key] { return image }
        guard let image = NSImage(contentsOf: fileURL(id, dark: dark, large: large)) else { return nil }
        image.size = large ? Self.largeSize : Self.size
        memory[key] = image
        return image
    }

    /// Draws the picture, or answers nil when the map cannot be had: no key
    /// yet, or no internet. The drawing runs on its own, so a row scrolled out
    /// of sight does not abandon it halfway, and the same map is never fetched
    /// twice at once. A failure waits a minute, or the next refresh.
    public func make(_ track: Track, points: TrackPoints, dark: Bool, large: Bool = false) async -> NSImage? {
        if let image = cached(track.id, dark: dark, large: large) { return image }
        guard let source, let key = source.key, !key.isEmpty else { return nil }
        let memoKey = "\(track.id)-\(dark)-\(large)"
        if let failed = failedAt[memoKey], Date().timeIntervalSince(failed) < 60 { return nil }
        if let running = inFlight[memoKey] { return await running.value }

        let size = large ? Self.largeSize : Self.size
        let file = fileURL(track.id, dark: dark, large: large)
        let gate = self.gate
        let task = Task { () -> NSImage? in
            await gate.enter()
            let png = await Self.render(points: points, bounds: track.bounds,
                                        template: dark ? source.dark : source.light, key: key, size: size,
                                        lineWidth: large ? 3.5 : 2.5)
            await gate.leave()
            guard let png, let image = NSImage(data: png) else { return nil }
            image.size = size
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

    /// Lets every map that failed be tried again; true when there were any.
    public func forgetFailures() -> Bool {
        defer { failedAt = [:] }
        return !failedAt.isEmpty
    }

    // MARK: Drawing

    /// Web Mercator, in points at zoom `z` with 256-point tiles.
    public nonisolated static func project(_ lat: Double, _ lon: Double, _ z: Int) -> CGPoint {
        let world = 256 * pow(2, Double(z))
        let la = max(min(lat, 85.0511), -85.0511) * .pi / 180
        let x = (lon + 180) / 360 * world
        let y = (1 - log(tan(la) + 1 / cos(la)) / .pi) / 2 * world
        return CGPoint(x: x, y: y)
    }

    /// The closest zoom that still fits the track, with some room round it.
    public nonisolated static func zoom(_ b: Bounds, size: NSSize) -> Int {
        for z in stride(from: 17, through: 1, by: -1) {
            let a = project(b.maxLat, b.minLon, z), c = project(b.minLat, b.maxLon, z)
            if (c.x - a.x) * 1.3 <= size.width && (c.y - a.y) * 1.3 <= size.height { return z }
        }
        return 1
    }

    /// The picture as PNG bytes, or nil when any tile cannot be had.
    public static func render(points: TrackPoints, bounds: Bounds, template: String, key: String,
                              size: NSSize, lineWidth: CGFloat = 2.5) async -> Data? {
        let z = zoom(bounds, size: size)
        let a = project(bounds.maxLat, bounds.minLon, z), c = project(bounds.minLat, bounds.maxLon, z)
        // On whole pixels, so the tiles meet without seams.
        let left = (((a.x + c.x) / 2 - size.width / 2) * scale).rounded() / scale
        let top = (((a.y + c.y) / 2 - size.height / 2) * scale).rounded() / scale
        let tiles = 1 << z

        var images: [(x: Int, y: Int, image: NSImage)] = []
        for ty in Int(floor(top / 256))...Int(floor((top + size.height) / 256)) {
            guard ty >= 0, ty < tiles else { continue }
            for tx in Int(floor(left / 256))...Int(floor((left + size.width) / 256)) {
                let wrapped = ((tx % tiles) + tiles) % tiles
                var text = template
                    .replacingOccurrences(of: "{z}", with: String(z))
                    .replacingOccurrences(of: "{x}", with: String(wrapped))
                    .replacingOccurrences(of: "{y}", with: String(ty))
                text += (text.contains("?") ? "&" : "?") + "key=" + (key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key)
                guard let url = URL(string: text) else { return nil }
                guard let image = await tile(url) else { return nil }
                images.append((tx, ty, image))
            }
        }

        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // Points from the top-left of the view to the picture's pixels, which count from the bottom.
        func pixel(_ p: CGPoint) -> NSPoint {
            NSPoint(x: (p.x - left) * scale, y: CGFloat(h) - (p.y - top) * scale)
        }
        for t in images {
            let corner = pixel(CGPoint(x: CGFloat(t.x) * 256, y: CGFloat(t.y + 1) * 256))
            t.image.draw(in: NSRect(x: corner.x, y: corner.y, width: 256 * scale, height: 256 * scale),
                         from: .zero, operation: .copy, fraction: 1)
        }
        let path = NSBezierPath()
        for (i, (lat, lon)) in thinned(points, to: size.width > 400 ? 3000 : 600).enumerated() {
            let p = pixel(project(lat, lon, z))
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.lineWidth = (lineWidth + 2) * scale
        NSColor.white.withAlphaComponent(0.85).setStroke()
        path.stroke()
        path.lineWidth = lineWidth * scale
        lineColour.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// One tile, tried three times before giving up.
    static func tile(_ url: URL) async -> NSImage? {
        var request = URLRequest(url: url)
        request.setValue("Geotag/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(700 * attempt)) }
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }

    /// Every n-th point, enough for a line this small.
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

    init(limit: Int) {
        self.limit = limit
    }

    func enter() async {
        if inside < limit {
            inside += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            inside -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
