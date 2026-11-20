#if os(macOS)
import AppKit
import SwiftUI
import SqueakyCore

/// Where the map looks: its centre and zoom.
struct MapCamera: Equatable {
    var lat: Double
    var lon: Double
    var zoom: Double

    /// The view that shows every point given, with some room.
    static func fitting(_ points: [CGPoint], in size: CGSize) -> MapCamera {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
              size.width > 0, size.height > 0 else { return MapCamera(lat: 0, lon: 0, zoom: 2) }
        let w = max(maxX - minX, 1e-7), h = max(maxY - minY, 1e-7)
        let zoom = min(log2(size.width / (w * 1.3)), log2(size.height / (h * 1.3)), 18)
        let centre = World.coordinate(CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2))
        return MapCamera(lat: centre.lat, lon: centre.lon, zoom: max(zoom, 1))
    }
}

/// Web Mercator at zoom 0: the world as a 256-point square.
enum World {
    static func point(_ lat: Double, _ lon: Double) -> CGPoint {
        MapThumbnails.project(lat, lon, 0)
    }

    static func coordinate(_ p: CGPoint) -> (lat: Double, lon: Double) {
        let lon = Double(p.x) / 256 * 360 - 180
        let n = Double.pi - 2 * Double.pi * Double(p.y) / 256
        return (atan(sinh(n)) * 180 / .pi, lon)
    }
}

/// Map tiles kept while Squeaky runs, fetched a few at a time.
@MainActor
final class TileCache: ObservableObject {
    @Published private(set) var round = 0
    private var images: [String: NSImage] = [:]
    private var asked: Set<String> = []
    private let gate = Gate(limit: 6)

    func image(_ key: String) -> NSImage? { images[key] }

    func fetch(_ tiles: [(key: String, url: URL)]) {
        for tile in tiles where images[tile.key] == nil && !asked.contains(tile.key) {
            asked.insert(tile.key)
            let gate = self.gate
            Task {
                await gate.enter()
                let image = await MapThumbnails.tile(tile.url)
                await gate.leave()
                if let image { self.images[tile.key] = image; self.round += 1 } else { self.asked.remove(tile.key) }
            }
        }
    }
}

struct MapDot: Identifiable, Equatable {
    let id: String
    /// At zoom 0.
    let world: CGPoint
}

/// A map to drag and zoom: OpenStreetMap tiles with no words, the tracks in
/// orange, and the photos as dots.
struct SlippyMap: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @StateObject private var tiles = TileCache()
    @Binding var camera: MapCamera
    /// Each track's line at zoom 0.
    let lines: [[CGPoint]]
    let dots: [MapDot]
    let selected: String?
    let onTap: (String?) -> Void

    @State private var dragStart: MapCamera?
    @State private var zoomStart: Double?

    private static let tileSize = 256.0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let needed = neededTiles(size)
            ZStack(alignment: .bottomTrailing) {
                Canvas { context, size in
                    draw(&context, size: size, tileKeys: needed)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            let start = dragStart ?? camera
                            if dragStart == nil { dragStart = camera }
                            let scale = pow(2, start.zoom)
                            let centre = World.point(start.lat, start.lon)
                            let moved = CGPoint(x: centre.x - value.translation.width / scale,
                                                y: centre.y - value.translation.height / scale)
                            let c = World.coordinate(moved)
                            camera = MapCamera(lat: c.lat, lon: c.lon, zoom: start.zoom)
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let start = zoomStart ?? camera.zoom
                            if zoomStart == nil { zoomStart = camera.zoom }
                            camera.zoom = min(max(start + log2(value.magnification), 1), 18)
                        }
                        .onEnded { _ in zoomStart = nil }
                )
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in onTap(dot(at: value.location, size: size)) }
                )
                .task(id: needed.map(\.key).joined(separator: ",") + "\(scheme == .dark)\(model.mapsRound)") {
                    tiles.fetch(needed)
                }

                HStack(spacing: 8) {
                    RoundIconButton(symbol: "minus", label: "Zoom out") { camera.zoom = max(camera.zoom - 1, 1) }
                    RoundIconButton(symbol: "plus", label: "Zoom in") { camera.zoom = min(camera.zoom + 1, 18) }
                }
                .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Style.radius))
    }

    private var tileZoom: Int { min(max(Int(floor(camera.zoom)), 1), 18) }

    private func topLeft(_ size: CGSize) -> CGPoint {
        let scale = pow(2, camera.zoom)
        let centre = World.point(camera.lat, camera.lon)
        return CGPoint(x: centre.x * scale - size.width / 2, y: centre.y * scale - size.height / 2)
    }

    private func neededTiles(_ size: CGSize) -> [(key: String, url: URL)] {
        guard let source = model.thumbnails.source, let key = source.key, !key.isEmpty, size.width > 0 else { return [] }
        let z = tileZoom
        let ts = Self.tileSize * pow(2, camera.zoom - Double(z))
        let tl = topLeft(size)
        let count = 1 << z
        let template = scheme == .dark ? source.dark : source.light
        var out: [(String, URL)] = []
        for ty in Int(floor(tl.y / ts))...Int(floor((tl.y + size.height) / ts)) where ty >= 0 && ty < count {
            for tx in Int(floor(tl.x / ts))...Int(floor((tl.x + size.width) / ts)) {
                let x = ((tx % count) + count) % count
                let text = template.replacingOccurrences(of: "{z}", with: "\(z)")
                    .replacingOccurrences(of: "{x}", with: "\(x)").replacingOccurrences(of: "{y}", with: "\(ty)")
                    + (template.contains("?") ? "&" : "?") + "key=" + key
                if let url = URL(string: text) { out.append(("\(scheme == .dark)/\(z)/\(x)/\(ty)", url)) }
            }
        }
        return out
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, tileKeys: [(key: String, url: URL)]) {
        _ = tiles.round
        let z = tileZoom
        let ts = Self.tileSize * pow(2, camera.zoom - Double(z))
        let tl = topLeft(size)
        for tile in tileKeys {
            let parts = tile.key.split(separator: "/")
            guard parts.count == 4, let x = Double(parts[2]), let y = Double(parts[3]), let image = tiles.image(tile.key) else { continue }
            // The tile may sit one world to the left or right of the view.
            var left = x * ts - tl.x
            let world = ts * Double(1 << z)
            while left + ts < 0 { left += world }
            while left > size.width { left -= world }
            let rect = CGRect(x: left.rounded(.down), y: (y * ts - tl.y).rounded(.down), width: ts.rounded(.up) + 1, height: ts.rounded(.up) + 1)
            context.draw(Image(nsImage: image), in: rect)
        }

        let scale = pow(2, camera.zoom)
        func screen(_ w: CGPoint) -> CGPoint { CGPoint(x: w.x * scale - tl.x, y: w.y * scale - tl.y) }
        let orange = Color(nsColor: MapThumbnails.lineColour)
        for line in lines {
            var path = Path()
            var last: CGPoint?
            for w in line {
                let p = screen(w)
                if let l = last {
                    if abs(p.x - l.x) + abs(p.y - l.y) < 1.5 { continue }
                    path.addLine(to: p)
                } else {
                    path.move(to: p)
                }
                last = p
            }
            context.stroke(path, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(orange), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }

        for dot in dots {
            let p = screen(dot.world)
            let big = dot.id == selected
            let r: CGFloat = big ? 8 : 5
            let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            context.fill(circle, with: .color(big ? .white : Color(red: 0.12, green: 0.43, blue: 0.92)))
            context.stroke(circle, with: .color(big ? Color(red: 0.12, green: 0.43, blue: 0.92) : .white), lineWidth: big ? 3 : 1.5)
        }
    }

    private func dot(at point: CGPoint, size: CGSize) -> String? {
        let scale = pow(2, camera.zoom)
        let tl = topLeft(size)
        var best: (String, CGFloat)?
        for dot in dots {
            let p = CGPoint(x: dot.world.x * scale - tl.x, y: dot.world.y * scale - tl.y)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= 12, best == nil || d < best!.1 { best = (dot.id, d) }
        }
        return best?.0
    }
}

#endif
