import SwiftUI
import UniformTypeIdentifiers
import GeotagCore

struct TracksScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var importing = false

    private static let trackTypes: [UTType] = [
        UTType(filenameExtension: "gpx") ?? .xml,
        UTType(filenameExtension: "fit") ?? .data,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            HStack(spacing: Style.gap) {
                ScreenTitle(text: "Tracks")
                Button {
                    Task { await model.refresh(pullStrava: true) }
                } label: {
                    Text("Refresh").buttonLabel()
                }
                .disabled(model.tracksBusy)
                Button {
                    importing = true
                } label: {
                    Text("Import GPX or FIT").buttonLabel()
                }
                .disabled(model.tracksBusy)
            }
            StatusLine(text: model.tracksLine, busy: model.tracksBusy)
            .frame(height: 18)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: Style.gap)],
                          alignment: .leading, spacing: Style.gap) {
                    ForEach(model.tracks) { track in
                        TrackCard(track: track)
                    }
                }
                .padding(.bottom, Style.gap)
            }

            if !model.tracks.isEmpty, !model.mapCredit.isEmpty {
                Text(model.mapCredit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(Style.pad * 1.5)
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.trackTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.importFiles(urls) }
            case .failure(let error): model.tracksLine = error.localizedDescription
            }
        }
    }
}

/// One track in the grid: its map, then its name, day and length of time.
/// Clicking the map opens the track viewer.
struct TrackCard: View {
    @EnvironmentObject var model: AppModel
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                TrackThumbnail(track: track, scale: geo.size.width / MapThumbnails.size.width)
            }
            .aspectRatio(MapThumbnails.size.width / MapThumbnails.size.height, contentMode: .fit)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { model.viewing = track.id }
            }
            .handCursor()
            Text(track.name)
                .font(.headline)
                .lineLimit(1)
            Text(TrackText.date(track, weekday: false))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text([TrackText.duration(track), TrackText.source(track)].joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Style.radius).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Style.radius).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct TrackRow: View {
    @EnvironmentObject var model: AppModel
    let track: Track

    var body: some View {
        HStack(spacing: Style.gap) {
            TrackThumbnail(track: track)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { model.viewing = track.id }
                }
                .handCursor()
            VStack(alignment: .leading, spacing: 4) {
                Text(track.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(TrackText.date(track))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Style.gap)
            Text(TrackText.clock(track))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 70, alignment: .trailing)
            Text(TrackText.source(track))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 190, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

/// The track's map picture; its bare shape until the map can be drawn.
struct TrackThumbnail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let track: Track
    var scale: CGFloat = 1
    @State private var image: NSImage?
    @State private var shape: [(Double, Double)] = []

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if !shape.isEmpty {
                TrackShape(points: shape, bounds: track.bounds)
                    .stroke(Color(nsColor: MapThumbnails.lineColour), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .padding(10 * scale)
            }
        }
        .frame(width: MapThumbnails.size.width * scale, height: MapThumbnails.size.height * scale)
        .clipShape(RoundedRectangle(cornerRadius: Style.radius))
        .overlay(RoundedRectangle(cornerRadius: Style.radius).strokeBorder(Color(nsColor: .separatorColor)))
        .task(id: "\(track.id)-\(scheme == .dark)-\(model.mapsRound)") {
            let dark = scheme == .dark
            if let cached = model.thumbnails.cached(track.id, dark: dark) {
                image = cached
                return
            }
            image = nil
            guard let points = await model.points(track.id) else { return }
            shape = MapThumbnails.thinned(points, to: 300)
            image = await model.thumbnails.make(track, points: points, dark: dark)
        }
    }
}

/// The line alone, fitted to its box, north up.
struct TrackShape: Shape {
    let points: [(Double, Double)]
    let bounds: Bounds

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midLat = (bounds.minLat + bounds.maxLat) / 2
        let xScale = cos(midLat * .pi / 180)
        let w = max((bounds.maxLon - bounds.minLon) * xScale, 1e-6)
        let h = max(bounds.maxLat - bounds.minLat, 1e-6)
        let scale = min(rect.width / w, rect.height / h)
        let dx = rect.minX + (rect.width - w * scale) / 2
        let dy = rect.minY + (rect.height - h * scale) / 2
        for (i, (lat, lon)) in points.enumerated() {
            let p = CGPoint(x: dx + (lon - bounds.minLon) * xScale * scale, y: dy + (bounds.maxLat - lat) * scale)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// The Tracks window, opened from the Tracks menu in the Mac's menu bar.
/// The track viewer opens over it.
public struct TracksWindow: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    public var body: some View {
        TracksScreen()
            .textSelection(.enabled)
            .frame(minWidth: 720, minHeight: 480)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay {
                if let id = model.viewing {
                    TrackViewer(trackId: id)
                        .transition(.opacity)
                }
            }
    }
}

/// The Tracks menu's items.
public struct TracksMenu: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Button("Show Tracks") {
            openWindow(id: "tracks")
        }
        Divider()
        Button("Refresh") {
            Task { await model.refresh(pullStrava: true) }
        }
        Button("Import GPX or FIT…") {
            model.importWithPanel()
            openWindow(id: "tracks")
        }
    }
}

/// The Download menu's item, next to Tracks in the Mac's menu bar.
public struct DownloadMenu: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Button("Save to Downloads") {
            Task { await model.saveDownload() }
        }
        .disabled(model.makingDownload)
    }
}

/// The Tracks page on its own, for pictures made off-screen.
public struct TracksScreenProbe: View {
    public init() {}
    public var body: some View { TracksScreen().background(Color(nsColor: .windowBackgroundColor)) }
}
