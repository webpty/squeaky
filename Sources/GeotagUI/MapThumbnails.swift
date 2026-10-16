import AppKit
import GeotagCore

/// Small map pictures of each track: OpenStreetMap tiles with no words, as the
/// track service names them, with the line drawn on top. Each is drawn once
/// per appearance and kept on this Mac, so it shows with no internet after.
@MainActor
public final class MapThumbnails {
    public static let size = NSSize(width: 160, height: 100)
    /// Pixels per point in the pictures kept.
    static let scale: CGFloat = 2
    public static let lineColour = NSColor(red: 0.949, green: 0.443, blue: 0.110, alpha: 1)

    let folder: URL
    public var source: MapSource?
    private var memory: [String: NSImage] = [:]
    private var failedAt: [String: Date] = [:]

    public init(folder: URL = MapThumbnails.standardFolder()) {
        self.folder = folder
    }

    public nonisolated static func standardFolder() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Geotag/Maps", isDirectory: true)
    }

    private func fileURL(_ id: String, dark: Bool) -> URL {
        folder.appendingPathComponent("\(id)-osm-\(dark ? "dark" : "light").png")
    }

    /// The picture if it was drawn before, from memory or disk.
    public func cached(_ id: String, dark: Bool) -> NSImage? {
        let key = "\(id)-\(dark)"
        if let image = memory[key] { return image }
        guard let image = NSImage(contentsOf: fileURL(id, dark: dark)) else { return nil }
        memory[key] = image
        return image
    }

    /// Draws the picture, or answers nil when the map cannot be had: no key
    /// yet, or no internet. A failure is not tried again for five minutes.
    public func make(_ track: Track, points: TrackPoints, dark: Bool) async -> NSImage? {
        if let image = cached(track.id, dark: dark) { return image }
        guard let source, let key = source.key, !key.isEmpty else { return nil }
        let memoKey = "\(track.id)-\(dark)"
        if let failed = failedAt[memoKey], Date().timeIntervalSince(failed) < 300 { return nil }
        guard let png = await Self.render(points: points, bounds: track.bounds,
                                          template: dark ? source.dark : source.light, key: key, size: Self.size),
              let image = NSImage(data: png) else {
            failedAt[memoKey] = Date()
            return nil
        }
        image.size = Self.size
        memory[memoKey] = image
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: fileURL(track.id, dark: dark), options: .atomic)
        return image
    }

    // MARK: Drawing

    /// Web Mercator, in points at zoom `z` with 256-point tiles.
    public static func project(_ lat: Double, _ lon: Double, _ z: Int) -> CGPoint {
        let world = 256 * pow(2, Double(z))
        let la = max(min(lat, 85.0511), -85.0511) * .pi / 180
        let x = (lon + 180) / 360 * world
        let y = (1 - log(tan(la) + 1 / cos(la)) / .pi) / 2 * world
        return CGPoint(x: x, y: y)
    }

    /// The closest zoom that still fits the track, with some room round it.
    public static func zoom(_ b: Bounds, size: NSSize) -> Int {
        for z in stride(from: 17, through: 1, by: -1) {
            let a = project(b.maxLat, b.minLon, z), c = project(b.minLat, b.maxLon, z)
            if (c.x - a.x) * 1.3 <= size.width && (c.y - a.y) * 1.3 <= size.height { return z }
        }
        return 1
    }

    /// The picture as PNG bytes, or nil when any tile cannot be had.
    public static func render(points: TrackPoints, bounds: Bounds, template: String, key: String,
                              size: NSSize) async -> Data? {
        let z = zoom(bounds, size: size)
        let a = project(bounds.maxLat, bounds.minLon, z), c = project(bounds.minLat, bounds.maxLon, z)
        let left = (a.x + c.x) / 2 - size.width / 2
        let top = (a.y + c.y) / 2 - size.height / 2
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
                var request = URLRequest(url: url)
                request.setValue("Geotag/\(appVersion)", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 20
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = NSImage(data: data) else { return nil }
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
        for (i, (lat, lon)) in thinned(points, to: 600).enumerated() {
            let p = pixel(project(lat, lon, z))
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.lineWidth = 4.5 * scale
        NSColor.white.withAlphaComponent(0.85).setStroke()
        path.stroke()
        path.lineWidth = 2.5 * scale
        lineColour.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Every n-th point, enough for a line this small.
    public static func thinned(_ p: TrackPoints, to count: Int) -> [(Double, Double)] {
        guard p.count > count else { return zip(p.lat, p.lon).map { ($0, $1) } }
        let step = Double(p.count - 1) / Double(count - 1)
        return (0..<count).map { i in
            let k = Int((Double(i) * step).rounded())
            return (p.lat[k], p.lon[k])
        }
    }
}
