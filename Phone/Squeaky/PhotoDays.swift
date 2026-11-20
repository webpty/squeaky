import SqueakyCore
import SqueakyUI
import SwiftUI

/// The photos on the Photos page, one section per day (0.31.0, David,
/// 18 November 2026): newest day first, earliest photo first within it; a
/// blue tick on each to choose what is saved; a tap selects or deselects, a
/// slide that starts sideways selects or deselects everything from where it
/// began to where the finger is, scrolling by itself near the edges; each
/// day folds away, remembered, and days copied before start folded with no
/// pictures made until opened.
struct PhotoDay: Identifiable {
    let id: String          // "2026-06-20"
    let date: Date?
    var frames: [PhotoFrame]
    /// Every photo of the day was copied before, or has been now.
    var copied: Bool
}

/// One square: the JPG of a RAW+JPG pair, standing for both.
struct PhotoFrame: Identifiable {
    let id: String          // the shown row's id
    let rows: [ImportRow]   // every file of the frame
    let picture: URL
    let taken: String
    var ticked: Bool { rows.contains(where: \.ticked) }
    /// A video's length, shown on its square (0.33.0).
    var duration: Double? { rows.first(where: \.photo.isVideo)?.photo.duration }
    var isVideo: Bool { PhotoKinds.isVideo(picture) }
    /// Played from its context menu; a RAW video cannot be (0.33.0).
    var playable: Bool { isVideo && !PhotoKinds.isRawVideo(picture) }
}

enum PhotoDays {
    static let key = "photoDaysOpen"

    /// The days, from the rows shown and every file belonging to each frame.
    @MainActor
    static func days(shown: [ImportRow], all: [ImportRow], model: AppModel) -> [PhotoDay] {
        func frameKey(_ r: ImportRow) -> String { (r.photo.fileName as NSString).deletingPathExtension + "|" + (r.photo.taken ?? "") }
        var byFrame: [String: [ImportRow]] = [:]
        for r in all { byFrame[frameKey(r), default: []].append(r) }
        var days: [String: PhotoDay] = [:]
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy:MM:dd"
        // A day's photos copied before and those not yet are two cards, so the new
        // ones are selected at once; one card again once all are copied, with the
        // green tick, as is every day copied before (0.31.9, David).
        for row in shown {
            let taken = row.photo.taken ?? ""
            let day = String(taken.prefix(10))
            let dayId = day.isEmpty ? "unknown" : day.replacingOccurrences(of: ":", with: "-")
            let files = byFrame[frameKey(row)] ?? [row]
            let frame = PhotoFrame(id: row.id, rows: files, picture: model.pictureURL(row) ?? row.photo.url, taken: taken)
            let copied = files.allSatisfy { model.isSaved($0) }
            let id = copied ? dayId + copiedSuffix : dayId
            if days[id] == nil { days[id] = PhotoDay(id: id, date: parse.date(from: day), frames: [], copied: copied) }
            days[id]!.frames.append(frame)
        }
        return days.values
            .map { var d = $0; d.frames.sort { $0.taken < $1.taken }; return d }
            .sorted { a, b in
                let da = a.id.replacingOccurrences(of: copiedSuffix, with: ""), db = b.id.replacingOccurrences(of: copiedSuffix, with: "")
                return da != db ? da > db : !a.copied
            }
    }

    /// The card of a day's photos already copied.
    static let copiedSuffix = "-copied"

    /// "17 Nov 2026", in the phone's own short form (0.31.3, David).
    static func title(_ day: PhotoDay) -> String {
        guard let date = day.date else { return Words.t("Date unknown") }
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        // Day, short month name and year, in the phone's own order: "17 Nov 2026".
        // The phone's medium style can be all numbers ("2025-09-20").
        f.setLocalizedDateFormatFromTemplate("dMMMy")
        return f.string(from: date)
    }

    /// Days opened or folded by hand; the rest follow whether they were copied before.
    static func isOpen(_ day: PhotoDay) -> Bool {
        let chosen = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        return chosen[day.id] ?? !day.copied
    }

    static func setOpen(_ day: PhotoDay, _ open: Bool) {
        var chosen = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        chosen[day.id] = open
        UserDefaults.standard.set(chosen, forKey: key)
    }
}

/// Where each square is on screen, for the slide.
struct FrameSpots: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The day's title: fold, name, count, Select all.
struct DayHeader: View {
    let day: PhotoDay
    let open: Bool
    let canChange: Bool
    let toggleOpen: () -> Void
    let selectAll: (Bool) -> Void

    var body: some View {
        let all = !day.frames.isEmpty && day.frames.allSatisfy(\.ticked)
        let count = day.frames.count.formatted()
        // The date, and one button with the count on the same line (0.31.3, David).
        HStack(spacing: 8) {
            Button(action: toggleOpen) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(PhotoDays.title(day)).font(.headline).lineLimit(1)
                    // Copied, the same tick as the copied photos (0.31.9, David).
                    if day.copied {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.green)
                            .accessibilityLabel(Words.t("Copied"))
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Blue to select, purple to deselect (0.34.2, David); greyed out while the
            // day is folded, whose photos keep whatever they were.
            Button(all ? Words.t("Deselect {0}", count) : Words.t("Select {0}", count)) { selectAll(!all) }
                .buttonStyle(.borderedProminent)
                .tint(all ? Color.purple : Color.heroBlue)
                .controlSize(.small)
                .lineLimit(1)
                .fixedSize()
                .disabled(!canChange || !open)
        }
        .textCase(nil)
        .foregroundStyle(.primary)
    }
}

/// A square with its blue tick, top left.
struct PickSquare: View {
    @ObservedObject var box: PictureBox
    let ticked: Bool
    let saved: Bool
    let failed: Bool
    var video = false
    var raw = false
    var duration: Double?

    var body: some View {
        Square(image: box.image, saved: saved, failed: failed, raw: raw)
            // A video: a play mark and its length, bottom left (0.33.0, David: "10:07").
            .overlay(alignment: .bottomLeading) {
                if video {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 10))
                        if let duration { Text(MovieFrames.length(duration)).font(.system(size: 12, weight: .semibold)).monospacedDigit() }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
                    .padding(5)
                }
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, ticked ? Color.heroBlue : Color.black.opacity(0.25))
                    .shadow(color: .black.opacity(0.3), radius: 1)
                    .padding(5)
                    .accessibilityLabel(ticked ? Words.t("Selected") : Words.t("Not selected"))
            }
    }
}

/// The slide in progress: where it began, the order of the squares, and
/// how each was before it, so moving back puts them as they were.
struct Slide {
    var order: [String]
    var start: Int
    var select: Bool
    var before: [String: Bool]
    var last: Int
}
