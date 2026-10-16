import AppKit
import MapKit
import GeotagCore

/// Small map pictures of each track's shape, drawn once per appearance and
/// kept on this Mac, so they show with no internet afterwards.
@MainActor
public final class MapThumbnails {
    public static let size = NSSize(width: 160, height: 100)

    let folder: URL
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
        folder.appendingPathComponent("\(id)-\(dark ? "dark" : "light").png")
    }

    /// The picture if it was drawn before, from memory or disk.
    public func cached(_ id: String, dark: Bool) -> NSImage? {
        let key = "\(id)-\(dark)"
        if let image = memory[key] { return image }
        guard let image = NSImage(contentsOf: fileURL(id, dark: dark)) else { return nil }
        memory[key] = image
        return image
    }

    /// Draws the picture, or answers nil when the map cannot be had (offline).
    /// A failure is not tried again for five minutes.
    public func make(_ track: Track, points: TrackPoints, dark: Bool) async -> NSImage? {
        if let image = cached(track.id, dark: dark) { return image }
        let key = "\(track.id)-\(dark)"
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < 300 { return nil }
        guard let image = await Self.render(points: points, bounds: track.bounds, dark: dark, size: Self.size) else {
            failedAt[key] = Date()
            return nil
        }
        memory[key] = image
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? png.write(to: fileURL(track.id, dark: dark), options: .atomic)
        }
        return image
    }

    /// A map of the track's area with its line drawn on top.
    public static func render(points: TrackPoints, bounds: Bounds, dark: Bool, size: NSSize) async -> NSImage? {
        let options = MKMapSnapshotter.Options()
        options.region = region(bounds, size: size)
        options.size = size
        options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        options.pointOfInterestFilter = .excludingAll

        let snapshot: MKMapSnapshotter.Snapshot
        do {
            snapshot = try await MKMapSnapshotter(options: options).start()
        } catch {
            return nil
        }
        let image = snapshot.image
        let line = thinned(points, to: 600)
        let output = NSImage(size: image.size)
        output.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        let path = NSBezierPath()
        for (i, (lat, lon)) in line.enumerated() {
            // On the Mac the snapshot's points already count up from the bottom.
            let p = snapshot.point(for: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.lineWidth = 2.5
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        NSColor.white.withAlphaComponent(dark ? 0.35 : 0.9).setStroke()
        let casing = path.copy() as! NSBezierPath
        casing.lineWidth = 4.5
        casing.stroke()
        NSColor.systemBlue.setStroke()
        path.stroke()
        output.unlockFocus()
        return output
    }

    static func region(_ b: Bounds, size: NSSize) -> MKCoordinateRegion {
        let centre = CLLocationCoordinate2D(latitude: (b.minLat + b.maxLat) / 2, longitude: (b.minLon + b.maxLon) / 2)
        var latSpan = max(b.maxLat - b.minLat, 0.003) * 1.3
        var lonSpan = max(b.maxLon - b.minLon, 0.003) * 1.3
        // Keep the picture's shape so the line is not squeezed.
        let aspect = Double(size.width / size.height)
        let lonPerLat = 1 / max(cos(centre.latitude * .pi / 180), 0.05)
        if lonSpan / lonPerLat / latSpan < aspect { lonSpan = latSpan * aspect * lonPerLat } else { latSpan = lonSpan / lonPerLat / aspect }
        return MKCoordinateRegion(center: centre, span: MKCoordinateSpan(latitudeDelta: min(latSpan, 170), longitudeDelta: min(lonSpan, 350)))
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
