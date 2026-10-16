import Foundation

/// A track read from a GPX or FIT file, before it joins the library.
public struct ImportedTrack: Equatable, Sendable {
    public var name: String
    public var fileName: String
    public var points: TrackPoints
}

public enum TrackFileError: Error, LocalizedError, Equatable {
    case unknownKind(String)
    case unreadable(String)
    case noPoints(String)

    public var errorDescription: String? {
        switch self {
        case .unknownKind(let name): return "\(name) is not a GPX or FIT file."
        case .unreadable(let name): return "\(name) could not be read."
        case .noPoints(let name): return "\(name) has no points with a time and a position."
        }
    }
}

public enum TrackFiles {
    public static func read(_ url: URL) throws -> ImportedTrack {
        let fileName = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TrackFileError.unreadable(fileName)
        }
        let parsed: (name: String?, points: TrackPoints)
        switch url.pathExtension.lowercased() {
        case "gpx": parsed = try GPXReader.read(data, fileName: fileName)
        case "fit": parsed = try FITReader.read(data, fileName: fileName)
        default: throw TrackFileError.unknownKind(fileName)
        }
        let points = ordered(parsed.points)
        guard points.count >= 2 else { throw TrackFileError.noPoints(fileName) }
        let name = parsed.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ImportedTrack(
            name: (name?.isEmpty == false ? name! : url.deletingPathExtension().lastPathComponent),
            fileName: fileName,
            points: points
        )
    }

    /// Time order, one point per second at most, nothing without a position.
    static func ordered(_ p: TrackPoints) -> TrackPoints {
        let order = p.t.indices
            .filter { p.lat[$0].isFinite && p.lon[$0].isFinite && abs(p.lat[$0]) <= 90 && abs(p.lon[$0]) <= 180 }
            .sorted { p.t[$0] < p.t[$1] }
        var out = TrackPoints(t: [], lat: [], lon: [], alt: [])
        for i in order where out.t.last != p.t[i] {
            out.t.append(p.t[i])
            out.lat.append(p.lat[i])
            out.lon.append(p.lon[i])
            out.alt.append(p.alt[i])
        }
        return out
    }
}

// MARK: - GPX

enum GPXReader {
    static func read(_ data: Data, fileName: String) throws -> (name: String?, points: TrackPoints) {
        let delegate = GPXDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw TrackFileError.unreadable(fileName) }
        return (delegate.name, delegate.points)
    }
}

private final class GPXDelegate: NSObject, XMLParserDelegate {
    var name: String?
    var points = TrackPoints(t: [], lat: [], lon: [], alt: [])

    private var inPoint = false
    private var lat = 0.0, lon = 0.0
    private var ele: Double?
    private var time: Int?
    private var text = ""
    private var path: [String] = []

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func epoch(_ s: String) -> Int? {
        let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = withFraction.date(from: s) ?? plain.date(from: s) else { return nil }
        return Int(d.timeIntervalSince1970.rounded())
    }

    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let el = local(elementName)
        path.append(el)
        text = ""
        if el == "trkpt" || el == "rtept" {
            inPoint = true
            lat = Double(attributes["lat"] ?? "") ?? .nan
            lon = Double(attributes["lon"] ?? "") ?? .nan
            ele = nil
            time = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let el = local(elementName)
        defer { path.removeLast() }
        let parent = path.count >= 2 ? path[path.count - 2] : ""
        switch el {
        case "ele" where inPoint:
            ele = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "time" where inPoint && (parent == "trkpt" || parent == "rtept"):
            time = Self.epoch(text)
        case "name" where name == nil && (parent == "trk" || parent == "metadata" || parent == "rte"):
            name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "trkpt", "rtept":
            inPoint = false
            if let time, lat.isFinite, lon.isFinite {
                points.t.append(time)
                points.lat.append(lat)
                points.lon.append(lon)
                points.alt.append(ele)
            }
        default:
            break
        }
    }
}
