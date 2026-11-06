import Charts
import SwiftUI
import GeotagCore

/// One stretch between two offset code photos of a camera: how much its
/// clock drifted, and what it went through meanwhile.
public struct DriftPeriod: Identifiable, Equatable, Sendable {
    public var from: Date
    public var to: Date
    /// Seconds a day gained; negative when lost.
    public var perDay: Double
    /// The camera's own temperature over the stretch, from its photos.
    public var average: Double?
    public var lowest: Double?
    public var highest: Double?
    /// Where its photos were taken, as far as known.
    public var spots: [(lat: Double, lon: Double)]
    /// The outside temperature there, from the track service once it keeps the weather.
    public var outside: Double?

    public var id: Date { from }

    public static func == (a: DriftPeriod, b: DriftPeriod) -> Bool {
        a.from == b.from && a.to == b.to && a.perDay == b.perDay && a.average == b.average
    }

    /// Every stretch between two readings of this camera.
    public static func periods(_ camera: Camera, temperatures: CameraTemperatures) -> [DriftPeriod] {
        let readings = camera.readings.sorted { $0.at < $1.at }
        return zip(readings, readings.dropFirst()).compactMap { a, b in
            let days = b.at.timeIntervalSince(a.at) / 86_400
            guard days > 0 else { return nil }
            let samples = temperatures.samples(camera.id, from: a.at, to: b.at)
            let values = samples.map(\.celsius)
            return DriftPeriod(from: a.at, to: b.at, perDay: (b.offset - a.offset) / days,
                               average: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
                               lowest: values.min(), highest: values.max(),
                               spots: samples.compactMap { s in s.lat.flatMap { lat in s.lon.map { (lat, $0) } } },
                               outside: nil)
        }
    }
}

/// Each camera's clock drift between its offset code photos, beside its own
/// temperature and the outside temperature where it was (David, 1 November 2026).
public struct ClockDriftView: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    private var cameras: [Camera] {
        model.book.cameras.filter { !$0.readings.isEmpty }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Style.gap) {
                ScreenTitle(text: "Clock drift")
                ForEach(cameras) { camera in
                    CameraDrift(camera: camera,
                                owner: model.book.person(camera.personId)?.name,
                                periods: DriftPeriod.periods(camera, temperatures: model.temperatures))
                }
            }
            .padding(Style.pad * 1.5)
        }
        .textSelection(.enabled)
    }
}

struct CameraDrift: View {
    let camera: Camera
    let owner: String?
    let periods: [DriftPeriod]
    @State private var places: [Date: String] = [:]

    var body: some View {
        Card(title: [owner, camera.model].compactMap { $0 }.joined(separator: " · ")) {
            if let line = OffsetText.drift(camera) {
                Text(line).foregroundStyle(.secondary).lineLimit(1)
            }
            if periods.contains(where: { $0.average != nil || $0.outside != nil }) {
                Chart {
                    ForEach(periods) { p in
                        if let t = p.average {
                            PointMark(x: .value("Temperature", t), y: .value("Drift", p.perDay))
                                .foregroundStyle(by: .value("Temperature of", "Camera"))
                        }
                        if let t = p.outside {
                            PointMark(x: .value("Temperature", t), y: .value("Drift", p.perDay))
                                .foregroundStyle(by: .value("Temperature of", "Outside"))
                        }
                    }
                }
                .chartXAxisLabel("°C")
                .chartYAxisLabel("s a day")
                .frame(height: 220)
            }
            if !periods.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: Style.gap, verticalSpacing: 6) {
                    GridRow {
                        Text("From").bold()
                        Text("To").bold()
                        Text("Drift").bold()
                        Text("Camera").bold()
                        Text("Outside").bold()
                        Text("Places").bold()
                    }
                    .lineLimit(1)
                    ForEach(periods) { p in
                        GridRow {
                            Text(When.current.day(p.from))
                            Text(When.current.day(p.to))
                            Text(String(format: "%+.2f s a day", p.perDay)).monospacedDigit()
                            Text(Self.camera(p)).monospacedDigit()
                            Text(p.outside.map { String(format: "%.1f °C", $0) } ?? "").monospacedDigit()
                            Text(places[p.from] ?? "")
                        }
                        .lineLimit(1)
                    }
                }
            }
        }
        .task(id: periods.map(\.from)) {
            for p in periods where places[p.from] == nil {
                places[p.from] = await Self.names(p.spots)
            }
        }
    }

    /// "4.1 °C (−2.0 to 9.5)".
    static func camera(_ p: DriftPeriod) -> String {
        guard let a = p.average else { return "" }
        var text = String(format: "%.1f °C", a)
        if let lo = p.lowest, let hi = p.highest, hi > lo { text += String(format: " (%.1f to %.1f)", lo, hi) }
        return text
    }

    /// Up to three place names along the way, from a few of its spots.
    static func names(_ spots: [(lat: Double, lon: Double)]) async -> String {
        guard !spots.isEmpty else { return "" }
        let step = max(spots.count / 3, 1)
        var names: [String] = []
        for i in stride(from: 0, to: spots.count, by: step).prefix(3) {
            if let name = await PlaceNames.shared.name(lat: spots[i].lat, lon: spots[i].lon), !names.contains(name) { names.append(name) }
        }
        return names.joined(separator: ", ")
    }
}
