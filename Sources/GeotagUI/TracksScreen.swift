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
                    Task { await model.refresh() }
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
            HStack(spacing: 8) {
                if model.tracksBusy {
                    ProgressView().controlSize(.small)
                }
                StatusLine(text: model.tracksLine)
            }
            .frame(height: 18)

            List(model.tracks) { track in
                TrackRow(track: track)
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: Style.radius))
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

struct TrackRow: View {
    @EnvironmentObject var model: AppModel
    let track: Track

    var body: some View {
        HStack(spacing: Style.gap) {
            TrackThumbnail(track: track)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(dateLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Style.gap)
            Text(durationText)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 70, alignment: .trailing)
            Text(sourceText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 190, alignment: .leading)
        }
        .padding(.vertical, 6)
    }

    private var dateLine: String {
        var style = Date.FormatStyle(date: .complete, time: .shortened)
        if let zone = track.timeZone.flatMap(TimeZone.init(identifier:)) { style.timeZone = zone }
        return track.start.formatted(style)
    }

    private var durationText: String {
        let minutes = Int((track.duration / 60).rounded())
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    private var sourceText: String {
        switch (track.source, track.status) {
        case (.strava, _): return "Strava"
        case (.file, .waitingToUpload): return "File, waiting to upload"
        case (.file, .thisMacOnly): return "File, this Mac only"
        case (.file, _): return "File"
        }
    }
}

/// The track's map picture; its bare shape until the map can be drawn.
struct TrackThumbnail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let track: Track
    @State private var image: NSImage?
    @State private var shape: [(Double, Double)] = []

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if !shape.isEmpty {
                TrackShape(points: shape, bounds: track.bounds)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .padding(10)
            }
        }
        .frame(width: MapThumbnails.size.width, height: MapThumbnails.size.height)
        .clipShape(RoundedRectangle(cornerRadius: Style.radius))
        .overlay(RoundedRectangle(cornerRadius: Style.radius).strokeBorder(Color(nsColor: .separatorColor)))
        .task(id: "\(track.id)-\(scheme == .dark)") {
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
