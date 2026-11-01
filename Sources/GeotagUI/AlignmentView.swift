import AppKit
import QuickLookThumbnailing
import SwiftUI
import GeotagCore

/// Slides a camera's photos along the track until they sit where they were
/// taken, then keeps that as the camera's clock offset.
struct AlignmentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var cameraId: UUID?
    /// Seconds added to the camera's offset while sliding.
    @State private var extra: Double = 0
    @State private var mapCamera = MapCamera(lat: 0, lon: 0, zoom: 2)
    @State private var fitted = false
    @State private var selected: String?
    @State private var lines: [[CGPoint]] = []
    @State private var place = ""
    /// The track the photos belong to, chosen by hand: their camera's clock
    /// may be too far out for them to fall on any track by its own times.
    @State private var trackId: String?
    /// Why "Use this offset" had nothing to keep.
    @State private var refusal = ""

    private var personId: UUID? { model.importPerson }

    /// The cameras with photos to align, in the order they first appear.
    private var cameras: [Camera] {
        guard let personId else { return [] }
        var seen: [UUID] = []
        var out: [Camera] = []
        for row in model.alignable {
            if let c = row.photo.model.flatMap({ model.book.camera(personId: personId, model: $0) }), !seen.contains(c.id) {
                seen.append(c.id)
                out.append(c)
            }
        }
        return out
    }

    private var camera: Camera? {
        cameras.first { $0.id == cameraId } ?? cameras.first
    }

    private var chosenTrack: Track? {
        trackId.flatMap { id in model.tracks.first { $0.id == id } }
    }

    /// Where the slider starts: the camera's own offset, or with a track
    /// chosen, the offset that puts its first photo at the track's start
    /// (David, 18 October 2026: the photos go on the map from there).
    private var base: Int {
        guard let camera else { return 0 }
        guard let track = chosenTrack,
              let first = photos.min(by: { (Moments.clockReading($0.photo) ?? .distantFuture) < (Moments.clockReading($1.photo) ?? .distantFuture) }),
              let offset = Moments.offset(placing: first.photo, camera: camera, at: track.start) else { return camera.offsetSeconds ?? 0 }
        return offset
    }

    /// How far the photos can slide each way: a quarter of an hour, and with
    /// a track chosen, as far as its end.
    private var range: ClosedRange<Double> {
        guard let track = chosenTrack else { return -900...900 }
        let times = photos.compactMap { Moments.clockReading($0.photo) }
        let span = (times.max() ?? .distantPast).timeIntervalSince(times.min() ?? .distantPast)
        return -max(900, (track.duration - max(span, 0)).rounded())...900
    }

    /// The camera as it would be with the slider where it is; a camera with no
    /// offset yet starts from on time.
    private var trial: Camera? {
        guard var c = camera else { return nil }
        c.offsetSeconds = base + Int(extra)
        return c
    }

    private var photos: [ImportRow] {
        guard let camera, let personId else { return [] }
        return model.alignable.filter { $0.photo.model.flatMap { model.book.camera(personId: personId, model: $0)?.id } == camera.id }
    }

    private var placed: [(row: ImportRow, position: Position?)] {
        guard let trial else { return [] }
        return photos.map { row in
            if case .success(let moment) = Moments.moment(row.photo, camera: trial) {
                return (row, model.timeline.position(at: moment, gap: model.maxGapSeconds))
            }
            return (row, nil)
        }
    }

    var body: some View {
        let placed = self.placed
        let dots = placed.compactMap { p in p.position.map { MapDot(id: p.row.id, world: World.point($0.lat, $0.lon)) } }
        VStack(alignment: .leading, spacing: Style.gap) {
            HStack(spacing: Style.gap) {
                Text(place).font(.title2.weight(.semibold)).lineLimit(1)
                if cameras.count > 1 {
                    Picker("", selection: Binding(get: { camera?.id }, set: { cameraId = $0; extra = 0; fitted = false })) {
                        ForEach(cameras) { Text($0.model).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Picker("", selection: Binding(get: { trackId }, set: { trackId = $0; extra = 0; fitted = false })) {
                    Text("By the photos' own times").tag(String?.none)
                    Divider()
                    ForEach(model.tracks.sorted { $0.start > $1.start }) { track in
                        Text("\(track.name), \(When.current.dayAndTime(track.start))").tag(Optional(track.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                RoundIconButton(symbol: "xmark", label: "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(alignment: .top, spacing: Style.gap) {
                GeometryReader { geo in
                    SlippyMap(camera: $mapCamera, lines: lines, dots: dots, selected: selected) { selected = $0 }
                        .onAppear {
                            fit(dots, size: geo.size)
                            if selected == nil { selected = dots.first?.id ?? placed.first?.row.id }
                        }
                        .onChange(of: camera?.id) { _, _ in fit(dots, size: geo.size, again: true) }
                        .onChange(of: trackId) { _, _ in
                            buildLines()
                            fit(self.dotsNow, size: geo.size, again: true)
                        }
                }
                PhotoPanel(row: placed.first { $0.row.id == selected }?.row,
                           position: placed.first { $0.row.id == selected }?.position)
                    .frame(width: 260)
            }

            Text(model.mapCredit)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .opacity(model.mapCredit.isEmpty ? 0 : 1)

            VStack(spacing: 6) {
                HStack {
                    Text("\(PhotoText.gap(Int(-range.lowerBound))) earlier").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(readout).font(.headline).monospacedDigit().lineLimit(1)
                    Spacer()
                    Text("\(PhotoText.gap(Int(range.upperBound))) later").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                // Whole seconds, without the tick marks a step would draw.
                Slider(value: Binding(get: { extra }, set: { extra = $0.rounded() }), in: range)
                    .labelsHidden()
            }

            HStack(spacing: Style.gap) {
                let away = placed.filter { $0.position == nil }.count
                StatusLine(text: !refusal.isEmpty ? refusal
                           : away == 0 ? "\(placed.count) photos on the track" : "\(placed.count - away) on the track, \(away) away from any track")
                Spacer()
                // The arrow keys move the slider a second at a time.
                Button("") { extra = max(extra - 1, range.lowerBound) }.keyboardShortcut(.leftArrow, modifiers: []).hidden().frame(width: 0)
                Button("") { extra = min(extra + 1, range.upperBound) }.keyboardShortcut(.rightArrow, modifiers: []).hidden().frame(width: 0)
                Button {
                    dismiss()
                } label: {
                    Text("Cancel").buttonLabel()
                }
                Button {
                    guard let trial else {
                        refusal = "There are no photos without a location to line up on this card."
                        return
                    }
                    model.save(trial)
                    extra = 0
                    // Saved: the photos now fall on the track by the camera's offset.
                    trackId = nil
                    if cameras.count <= 1 { dismiss() }
                } label: {
                    Text("Use this offset").buttonLabel()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Style.pad * 1.5)
        .frame(minWidth: 1000, minHeight: 720)
        .task { buildLines() }
        .task(id: camera?.id) { await name(placed) }
    }

    /// The window's title: where the photos were taken, as best as can be
    /// found. The place name from OpenStreetMap, else the track's name, else
    /// the day.
    private func name(_ placed: [(row: ImportRow, position: Position?)]) async {
        let found = placed.compactMap(\.position)
        if let lat = found.map(\.lat).sorted().dropFirst(found.count / 2).first,
           let lon = found.map(\.lon).sorted().dropFirst(found.count / 2).first,
           let named = await PlaceNames.shared.name(lat: lat, lon: lon) {
            place = named
            return
        }
        if let id = found.first?.trackId, let track = model.tracks.first(where: { $0.id == id }) {
            place = track.name
            return
        }
        if let first = placed.first, let clock = Moments.clockReading(first.row.photo) {
            place = When.current.day(clock, zone: TimeZone(secondsFromGMT: 0)!, weekday: true)
        }
    }

    /// "Clock 1 min 12 s ahead", for the offset as it would be saved.
    private var readout: String {
        guard let trial else { return "" }
        return "Clock " + OffsetText.describe(trial.offsetSeconds).lowercased()
    }

    /// The tracks near the photos' days, as lines at zoom 0; the chosen
    /// track's day when there is one.
    private func buildLines() {
        let moments = photos.compactMap { row -> Date? in
            guard let c = trial else { return nil }
            if case .success(let m) = Moments.moment(row.photo, camera: c) { return m }
            return nil
        }
        lines = model.timeline.pieces(near: moments).map { piece in
            let p = piece.points
            return p.t.indices.map { World.point(p.lat[$0], p.lon[$0]) }
        }
    }

    /// The photos' dots as they stand.
    private var dotsNow: [MapDot] {
        placed.compactMap { p in p.position.map { MapDot(id: p.row.id, world: World.point($0.lat, $0.lon)) } }
    }

    private func fit(_ dots: [MapDot], size: CGSize, again: Bool = false) {
        guard !fitted || again else { return }
        let points = dots.isEmpty ? lines.flatMap { $0 } : dots.map(\.world)
        guard !points.isEmpty else { return }
        mapCamera = MapCamera.fitting(points, in: size)
        fitted = true
    }
}

/// The chosen photo, larger, with when and how near the track it falls.
struct PhotoPanel: View {
    let row: ImportRow?
    let position: Position?
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: Style.radius).fill(Color(nsColor: .controlBackgroundColor))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Style.radius))
                }
            }
            .frame(height: 180)
            if let row {
                Text(row.photo.fileName).font(.headline).lineLimit(1)
                Text(PhotoText.taken(row.photo)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                Text(position.map { "\($0.fromPoint) s from the track" } ?? "Away from any track")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .task(id: row?.id) {
            image = nil
            guard let url = row?.photo.url else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 260, height: 180), scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

/// The alignment window on its own, for pictures made off-screen.
public struct AlignmentProbe: View {
    public init() {}
    public var body: some View { AlignmentView().background(Color(nsColor: .windowBackgroundColor)) }
}
