import Foundation

/// A lens the family's photos have named, with the camera it was last on and
/// when (David, 18 October 2026). Photos never say which firmware a lens
/// runs: the camera shows that in its own Firmware menu, with the lens on.
public struct Lens: Codable, Identifiable, Equatable, Sendable {
    /// As the camera names it, without an extender: "RF600mm F4 L IS USM".
    public var model: String
    /// Nil for a lens that reports none.
    public var serial: String?
    /// Whose card its latest photo was on, and the camera that took it.
    public var personId: UUID
    public var camera: String
    /// When that photo was taken, by the camera's clock.
    public var seen: Date?
    /// The firmware version typed in by hand, from the camera's Firmware
    /// menu, and when it was typed (David, 18 October 2026).
    public var firmware: String?
    public var firmwareSet: Date?

    public var id: String { Lenses.key(model: model, serial: serial) }

    public init(model: String, serial: String?, personId: UUID, camera: String, seen: Date?,
                firmware: String? = nil, firmwareSet: Date? = nil) {
        self.model = model
        self.serial = serial
        self.personId = personId
        self.camera = camera
        self.seen = seen
        self.firmware = firmware
        self.firmwareSet = firmwareSet
    }
}

public enum Lenses {
    /// The lens out of what the camera writes. An extender comes after a "+"
    /// ("EF100-400mm f/4.5-5.6L IS II USM +1.4x III") and is not the lens, so
    /// a lens used with and without one is one lens. Nil when nothing is named.
    public static func name(_ text: String?) -> String? {
        guard let text else { return nil }
        let lens = (text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lens.rangeOfCharacter(from: .alphanumerics) == nil ? nil : lens
    }

    /// The serial number, or nil for the zeros a lens without one reports
    /// ("0000000000"). Leading zeros of a real one stay: "0000131373".
    public static func serial(_ text: String?) -> String? {
        guard let s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              s.contains(where: { $0 != "0" }) else { return nil }
        return s
    }

    static func key(model: String, serial: String?) -> String {
        "\(model.lowercased())|\(serial ?? "")"
    }

    /// Canon's support page for the lens, where its firmware is offered. Canon
    /// U.S.A. names each page after the lens as the camera writes it: lower
    /// case, every "." "/" and space a "-", and a "-" after "EF" or "EF-S"
    /// ("EF-S18-55mm f/3.5-5.6 IS II" is ef-s-18-55mm-f-3-5-5-6-is-ii). Checked
    /// on 18 October 2026 against the pages of the RF70-200mm Z, RF70-200mm,
    /// RF600mm, RF24-105mm, RF-S18-150mm, EF600mm III, EF70-200mm III and
    /// EF-S18-55mm II. Nil for other makers' lenses.
    public static func page(forLens model: String) -> URL? {
        var name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name.hasPrefix("rf") || name.hasPrefix("ef") else { return nil }
        for prefix in ["ef-s", "ef"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            if rest.first?.isNumber == true { name = prefix + "-" + rest }
            break
        }
        var slug = ""
        for c in name {
            let keep = c.isASCII && (c.isLetter || c.isNumber)
            if keep { slug.append(c) } else if slug.last != "-" { slug.append("-") }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? nil : URL(string: "https://www.usa.canon.com/support/p/\(slug)")
    }

    /// The lenses known once these photos from one person's card are taken
    /// in. Each lens counts from its latest photo on the card: a new lens is
    /// added; a known one moves to that photo's camera and day only when the
    /// photo is later than the one it was last seen in, so an older card
    /// never takes it back. A firmware version typed in stays.
    public static func noting(_ photos: [ScannedPhoto], personId: UUID, into known: [Lens]) -> [Lens] {
        var latest: [String: (lens: Lens, order: Int)] = [:]
        for (i, photo) in photos.enumerated() {
            guard let model = name(photo.lens), let camera = photo.model else { continue }
            let lens = Lens(model: model, serial: serial(photo.lensSerial), personId: personId, camera: camera,
                            seen: Moments.clockReading(photo))
            if let held = latest[lens.id], (held.lens.seen ?? .distantPast) > (lens.seen ?? .distantPast) { continue }
            latest[lens.id] = (lens, latest[lens.id]?.order ?? i)
        }
        var out = known
        for found in latest.values.sorted(by: { $0.order < $1.order }).map(\.lens) {
            if let i = out.firstIndex(where: { $0.id == found.id }) {
                guard (found.seen ?? .distantPast) > (out[i].seen ?? .distantPast) else { continue }
                out[i].personId = found.personId
                out[i].camera = found.camera
                out[i].seen = found.seen
            } else {
                out.append(found)
            }
        }
        return out
    }
}
