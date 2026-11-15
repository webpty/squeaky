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
