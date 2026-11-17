import GeotagCore
import GeotagUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The watch's tracks, from the track service.
struct TracksTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var maps: MapThumbnails
    @State private var importing = false

    /// GPX and FIT files; any file where the phone knows neither.
    static let trackFiles: [UTType] = {
        let known = ["gpx", "fit"].compactMap { UTType(filenameExtension: $0) }
        return known.count == 2 ? known : [.data]
    }()

    init(model: AppModel) {
        self.model = model
        self.maps = model.thumbnails
    }

    var body: some View {
        NavigationStack {
            List {
                // Plain words above the list, no box: it looked like a field (0.29.30).
                Section {
                    StatusRow(text: model.tracksLine, busy: model.tracksBusy || model.namingTracks)
                    if maps.asked > maps.made {
                        StatusRow(text: Words.t("Making maps: {0} of {1}", maps.made + 1, maps.asked), busy: true)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                Section {
                    ForEach(model.tracks.sorted { $0.start > $1.start }) { track in
                        // The map on the left, the words on the right (0.29.4).
                        HStack(alignment: .top, spacing: 12) {
                            TrackPicture(model: model, track: track)
                                .frame(width: MapThumbnails.size.width, height: MapThumbnails.size.height)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.trackTitle(track))
                                Text(Self.line(track)).font(.caption).foregroundStyle(.secondary)
                                Button(Words.t("Recheck photos for this track")) { Task { await model.recheckPhotos(for: track) } }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                    .disabled(model.tracksBusy || model.saving || model.placingLater)
                            }
                            .lineLimit(1)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // The map's licence asks for its credit to show with it.
                if !model.mapCredit.isEmpty {
                    Text(model.mapCredit).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.horizontal).padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
            // The last card's photo behind every tab, veiled (0.29.5, David, 16 November 2026).
            .background(Backdrop(image: model.sidebarImage))
            .navigationBarTitleDisplayMode(.inline)
            // Refresh at the top right (0.29.7, David, 16 November 2026).
            .toolbar {
                PageTitle(title: Words.t("Tracks"))
                // A GPX or FIT file from the Files list, sent to the service as on the Mac (0.29.30).
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel(Words.t("Import GPX or FIT"))
                        .disabled(model.tracksBusy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.refresh(pullStrava: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(Words.t("Refresh"))
                        .disabled(model.tracksBusy)
                }
            }
            .refreshable { await model.refresh(pullStrava: true) }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.trackFiles, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await model.importFiles(urls) }
                case .failure(let error): model.tracksLine = error.localizedDescription
                }
            }
        }
    }

    /// "12 Nov 2026, 15:57 · 3 h 10 min · 8.4 km".
    static func line(_ track: Track) -> String {
        let zone = track.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        var parts = [When.current.dayAndTime(track.start, zone: zone, seconds: false)]
        let minutes = Int(track.end.timeIntervalSince(track.start) / 60)
        parts.append(minutes >= 60 ? Words.t("{0} h", minutes / 60) + " " + Words.t("{0} min", minutes % 60) : Words.t("{0} min", minutes))
        if let metres = track.distance { parts.append(Words.t("{0} km", String(format: "%.1f", metres / 1000))) }
        return parts.joined(separator: " · ")
    }
}

/// A track's map, as on the Mac: tiles with no words and the route in blue,
/// kept on the phone once made. Until it can be made, the route alone, drawn
/// from its own points. Tried again once the points or the maps come in.
struct TrackPicture: View {
    @ObservedObject var model: AppModel
    let track: Track
    @Environment(\.colorScheme) private var scheme
    @State private var points: [CGPoint] = []
    @State private var map: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let map {
                Image(uiImage: map).resizable().scaledToFill()
            } else {
                GeometryReader { box in
                    Path { path in
                        let fitted = Self.fit(points, in: box.size.insetBy(8))
                        guard let first = fitted.first else { return }
                        path.move(to: first)
                        for p in fitted.dropFirst() { path.addLine(to: p) }
                    }
                    .offset(x: 8, y: 8)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .task(id: "\(track.id)-\(model.tracksBusy)-\(model.mapsRound)-\(scheme == .dark)") {
            let dark = scheme == .dark
            if let known = model.thumbnails.cached(track.id, dark: dark) { map = known; return }
            guard let loaded = await model.points(track.id) else { return }
            if points.isEmpty { points = Self.flatten(loaded) }
            map = await model.thumbnails.make(track, points: loaded, dark: dark)
        }
    }

    /// East and north in metres from the first point, every few points.
    static func flatten(_ t: TrackPoints) -> [CGPoint] {
        guard let lat0 = t.lat.first else { return [] }
        let k = cos(lat0 * .pi / 180)
        let step = max(1, t.lat.count / 800)
        return stride(from: 0, to: t.lat.count, by: step).map {
            CGPoint(x: t.lon[$0] * k, y: -t.lat[$0])
        }
    }

    /// The route scaled to fit, the same scale both ways, centred.
    static func fit(_ points: [CGPoint], in size: CGSize) -> [CGPoint] {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return [] }
        let w = max(maxX - minX, 1e-9), h = max(maxY - minY, 1e-9)
        let scale = min(size.width / w, size.height / h)
        let dx = (size.width - w * scale) / 2, dy = (size.height - h * scale) / 2
        return points.map { CGPoint(x: ($0.x - minX) * scale + dx, y: ($0.y - minY) * scale + dy) }
    }
}

private extension CGSize {
    func insetBy(_ d: CGFloat) -> CGSize { CGSize(width: max(width - 2 * d, 1), height: max(height - 2 * d, 1)) }
}
