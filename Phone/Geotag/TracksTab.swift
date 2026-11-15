import GeotagCore
import GeotagUI
import SwiftUI

/// The watch's tracks, from the track service.
struct TracksTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusRow(text: model.tracksLine, busy: model.tracksBusy)
                    Button(Words.t("Refresh")) { Task { await model.refresh(pullStrava: true) } }
                        .disabled(model.tracksBusy)
                }
                Section {
                    ForEach(model.tracks.sorted { $0.start > $1.start }) { track in
                        VStack(alignment: .leading, spacing: 4) {
                            TrackPicture(model: model, id: track.id)
                                .frame(height: 110)
                                .padding(.bottom, 4)
                            Text(track.name)
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
            .navigationTitle(Words.t("Tracks"))
            .refreshable { await model.refresh(pullStrava: true) }
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

/// A track's route as a blue line, drawn from its own points, so it shows
/// with no internet (David, 15 November 2026).
struct TrackPicture: View {
    @ObservedObject var model: AppModel
    let id: String
    @State private var points: [CGPoint] = []

    var body: some View {
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
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .task(id: id) {
            guard points.isEmpty, let track = await model.points(id) else { return }
            points = Self.flatten(track)
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
