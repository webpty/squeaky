#if os(macOS)
import SwiftUI
import GeotagCore

/// How a track's details read, the same in the list and the viewer.
enum TrackText {
    /// In the zone where the track was recorded, when known.
    static func date(_ track: Track, weekday: Bool = true) -> String {
        let zone = track.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        return When.current.dayAndTime(track.start, zone: zone, weekday: weekday)
    }

    static func duration(_ track: Track) -> String {
        let minutes = Int((track.duration / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    static func clock(_ track: Track) -> String {
        let minutes = Int((track.duration / 60).rounded())
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func distance(_ track: Track) -> String? {
        guard let metres = track.distance, metres > 0 else { return nil }
        return Measurement(value: metres, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    static func source(_ track: Track) -> String {
        switch (track.source, track.status) {
        case (.strava, _): return "Strava"
        case (.file, .waitingToUpload): return "File, waiting to upload"
        case (.file, .thisMacOnly): return "File, this Mac only"
        case (.file, _): return "File"
        }
    }
}

/// A large map of one track over the whole window, with every other track a
/// slide away.
public struct TrackViewer: View {
    @EnvironmentObject var model: AppModel
    let trackId: String
    @State private var forward = true

    public init(trackId: String) {
        self.trackId = trackId
    }

    private var index: Int? { model.tracks.firstIndex { $0.id == trackId } }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }
            if let index {
                panel(model.tracks[index], at: index)
                    .textSelection(.enabled)
                    .padding(28)
            }
        }
        .onChange(of: model.tracks) { _, tracks in
            if !tracks.contains(where: { $0.id == trackId }) { close() }
        }
    }

    private func panel(_ track: Track, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            HStack(alignment: .top, spacing: Style.gap) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text([TrackText.date(track), TrackText.duration(track), TrackText.distance(track), TrackText.source(track)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Style.gap)
                RoundIconButton(symbol: "xmark", label: "Close") { close() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: Style.gap) {
                RoundIconButton(symbol: "chevron.left", label: "Previous") { go(to: index - 1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index == 0)
                ZStack {
                    LargeTrackMap(track: track)
                        .id(track.id)
                        .transition(.push(from: forward ? .trailing : .leading))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                RoundIconButton(symbol: "chevron.right", label: "Next") { go(to: index + 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index >= model.tracks.count - 1)
            }

            Text(model.mapCredit)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .opacity(model.mapCredit.isEmpty ? 0 : 1)

            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(model.tracks.enumerated()), id: \.element.id) { i, t in
                            TrackThumbnail(track: t, scale: 0.6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Style.radius)
                                        .strokeBorder(Color(nsColor: MapThumbnails.lineColour), lineWidth: i == index ? 3 : 0)
                                )
                                .onTapGesture { go(to: i) }
                                .handCursor()
                                .id(t.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: MapThumbnails.size.height * 0.6 + 4)
                .onAppear { reader.scrollTo(track.id, anchor: .center) }
                .onChange(of: trackId) { _, id in
                    withAnimation { reader.scrollTo(id, anchor: .center) }
                }
            }
        }
        .padding(Style.pad)
        .frame(maxWidth: 1040, maxHeight: 820)
        .background(
            RoundedRectangle(cornerRadius: Style.radius)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 24)
        )
    }

    private func go(to i: Int) {
        guard let current = index, i >= 0, i < model.tracks.count, i != current else { return }
        forward = i > current
        withAnimation(.easeInOut(duration: 0.25)) {
            model.viewing = model.tracks[i].id
        }
    }

    private func close() {
        model.viewing = nil
    }
}

/// The large map, or the bare line while the map is fetched or cannot be had.
struct LargeTrackMap: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let track: Track
    @State private var image: NSImage?
    @State private var shape: [(Double, Double)] = []
    @State private var loading = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Style.radius).fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Style.radius))
            } else {
                if !shape.isEmpty {
                    TrackShape(points: shape, bounds: track.bounds)
                        .stroke(Color(nsColor: MapThumbnails.lineColour), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .padding(40)
                }
                if loading { ProgressView() }
            }
        }
        .aspectRatio(MapThumbnails.largeSize.width / MapThumbnails.largeSize.height, contentMode: .fit)
        .task(id: "\(track.id)-\(scheme == .dark)-\(model.mapsRound)") {
            let dark = scheme == .dark
            loading = true
            defer { loading = false }
            if let cached = model.thumbnails.cached(track.id, dark: dark, large: true) {
                image = cached
                return
            }
            image = nil
            guard let points = await model.points(track.id) else { return }
            shape = MapThumbnails.thinned(points, to: 1500)
            image = await model.thumbnails.make(track, points: points, dark: dark, large: true)
        }
    }
}

#endif
