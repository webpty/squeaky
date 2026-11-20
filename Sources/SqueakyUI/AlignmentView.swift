#if os(macOS)
import AppKit
import QuickLookThumbnailing
import SwiftUI
import SqueakyCore

/// The photos on the map, card in or out: each where its own location puts
/// it, or where its time falls along the tracks by its camera's clock
/// offset. Only to look at (0.26.0, David, 6 November 2026): a camera's
/// offset comes from photographing the offset code, so there is nothing
/// to slide or keep here.
struct AlignmentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var cameraId: UUID?
    @State private var mapCamera = MapCamera(lat: 0, lon: 0, zoom: 2)
    @State private var fitted = false
    @State private var selected: String?
    @State private var lines: [[CGPoint]] = []
    @State private var place = ""

    private var personId: UUID? { model.importPerson }

    /// The cameras with photos to show, in the order they first appear.
    private var cameras: [Camera] {
        guard let personId else { return [] }
        var seen: [UUID] = []
        var out: [Camera] = []
        for row in model.mappable {
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

    private var photos: [ImportRow] {
        guard let personId else { return [] }
        // A photo with its own location but a camera not on the list still shows.
        guard let camera else { return model.mappable }
        return model.mappable.filter { $0.photo.model.flatMap { model.book.camera(personId: personId, model: $0)?.id } == camera.id }
    }

    private var placed: [(row: ImportRow, position: Position?)] {
        photos.map { row in
            if row.photo.hasLocation, let lat = row.photo.ownLat, let lon = row.photo.ownLon {
                return (row, Position(lat: lat, lon: lon, alt: nil, moment: Moments.clockReading(row.photo) ?? .distantPast, fromPoint: 0))
            }
            guard var c = camera else { return (row, nil) }
            c.offsetSeconds = c.offsetSeconds ?? 0
            if case .success(let moment) = Moments.moment(row.photo, camera: c) {
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
                    Picker("", selection: Binding(get: { camera?.id }, set: { cameraId = $0; fitted = false })) {
                        ForEach(cameras) { Text($0.model).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
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
                        .onChange(of: camera?.id) { _, _ in
                            buildLines()
                            fit(self.dotsNow, size: geo.size, again: true)
                        }
                }
                let chosen = placed.first { $0.row.id == selected }
                PhotoPanel(row: chosen?.row, picture: chosen.flatMap { model.pictureURL($0.row) }, position: chosen?.position)
                    .frame(width: 260)
            }

            Text(model.mapCredit)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .opacity(model.mapCredit.isEmpty ? 0 : 1)

            HStack(spacing: Style.gap) {
                let away = placed.filter { $0.position == nil }.count
                StatusLine(text: away == 0 ? "\(placed.count) photos on the map" : "\(placed.count - away) on the map, \(away) away from any track")
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Close").buttonLabel()
                }
            }
        }
        .padding(Style.pad * 1.5)
        .frame(minWidth: 1000, minHeight: 720)
        .task { buildLines() }
        .task(id: camera?.id) { await name(placed) }
    }

    /// The title: where the photos were taken, as best as can be found. The
    /// place name from OpenStreetMap, else the track's name, else the day.
    private func name(_ placed: [(row: ImportRow, position: Position?)]) async {
        let found = placed.compactMap(\.position)
        if let lat = found.map(\.lat).sorted().dropFirst(found.count / 2).first,
           let lon = found.map(\.lon).sorted().dropFirst(found.count / 2).first,
           let named = await PlaceNames.shared.name(lat: lat, lon: lon) {
            place = named
            return
        }
        if let id = found.first?.trackId, let track = model.tracks.first(where: { $0.id == id }) {
            place = model.trackTitle(track)
            return
        }
        if let first = placed.first, let clock = Moments.clockReading(first.row.photo) {
            place = When.current.day(clock, zone: TimeZone(secondsFromGMT: 0)!, weekday: true)
        }
    }

    /// The tracks near the photos' days, as lines at zoom 0.
    private func buildLines() {
        let moments = placed.compactMap { $0.position?.moment }
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
    /// From the card while it is in, else the copy on this Mac; nil for none.
    let picture: URL?
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
                Text(row.photo.hasLocation ? "Its own location" : position.map { "\($0.fromPoint) s from the track" } ?? "Away from any track")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .task(id: row?.id) {
            image = nil
            guard let url = picture else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 260, height: 180), scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

/// The map of photos on its own, for pictures made off-screen.
public struct AlignmentProbe: View {
    public init() {}
    public var body: some View { AlignmentView().background(Color(nsColor: .windowBackgroundColor)) }
}

#endif
