import AppKit
import QuickLookThumbnailing
import SwiftUI
import GeotagCore

enum PhotoText {
    /// The camera's own clock reading, shown as it was, with its zone.
    static func taken(_ photo: ScannedPhoto) -> String {
        guard let raw = photo.taken else { return "No time" }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return raw }
        var style = Date.FormatStyle(date: .abbreviated, time: .standard)
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style) + (photo.zone.map { " (\($0))" } ?? "")
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func status(_ status: ImportStatus) -> String {
        switch status {
        case .new: return "New"
        case .alreadyImported: return "Imported before"
        case .unknownCamera: return "Camera not on the list"
        }
    }
}

struct PhotosScreen: View {
    @EnvironmentObject var model: AppModel

    private var sources: [PhotoSource] {
        model.cards + (model.folder.map { [$0] } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            HStack(spacing: Style.gap) {
                ScreenTitle(text: "Photos")
                Button {
                    model.chooseFolder()
                } label: {
                    Text("Choose folder").buttonLabel()
                }
                .disabled(model.photosBusy)
            }

            if !sources.isEmpty {
                HStack(spacing: 8) {
                    ForEach(sources) { source in
                        SourceButton(source: source, selected: model.source?.id == source.id) {
                            model.choose(source)
                        }
                        .disabled(model.photosBusy)
                    }
                }
            }

            HStack(spacing: 8) {
                if let id = model.importPerson, model.source != nil, let person = model.book.person(id) {
                    Text(person.name).font(.headline).lineLimit(1)
                    Button {
                        if let source = model.source { model.askingWhose = source }
                    } label: {
                        Text("Change").buttonLabel()
                    }
                    .disabled(model.photosBusy)
                }
                if model.photosBusy { ProgressView().controlSize(.small) }
                StatusLine(text: model.photosLine)
            }
            .frame(height: 24)

            Table(model.rows) {
                TableColumn("") { row in
                    Toggle("", isOn: Binding(get: { row.ticked }, set: { model.setTicked(row.id, $0) }))
                        .labelsHidden()
                }
                .width(24)
                TableColumn("") { row in
                    PhotoPreview(url: row.photo.url)
                }
                .width(56)
                TableColumn("Name") { row in
                    Text(row.photo.fileName).lineLimit(1)
                }
                .width(min: 110, ideal: 140)
                TableColumn("Taken") { row in
                    Text(PhotoText.taken(row.photo)).monospacedDigit().lineLimit(1)
                }
                .width(min: 170, ideal: 220)
                TableColumn("Camera") { row in
                    Text(row.photo.model ?? "Unknown").lineLimit(1)
                }
                .width(min: 110, ideal: 150)
                TableColumn("Size") { row in
                    Text(PhotoText.size(row.photo.size)).monospacedDigit().lineLimit(1)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Status") { row in
                    Text(PhotoText.status(row.status))
                        .foregroundStyle(row.status == .new ? .primary : .secondary)
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 170)
            }
            .clipShape(RoundedRectangle(cornerRadius: Style.radius))
        }
        .padding(Style.pad * 1.5)
        .sheet(item: $model.askingWhose) { source in
            WhoseCard(source: source)
        }
    }
}

struct SourceButton: View {
    let source: PhotoSource
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(source.name, systemImage: source.isCard ? "sdcard" : "folder")
                .lineLimit(1)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: Style.radius)
                        .fill(selected ? Color.accentColor.opacity(0.25) : Color(nsColor: .controlColor))
                )
                .overlay(RoundedRectangle(cornerRadius: Style.radius).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .buttonStyle(.plain)
    }
}

/// Whose card is this: one button per person, last time's owner first in line.
struct WhoseCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let source: PhotoSource

    var body: some View {
        let last = model.lastPerson(for: source)
        VStack(alignment: .leading, spacing: Style.gap) {
            Text("Whose is \(source.name)?").font(.headline).lineLimit(1)
            HStack(spacing: 8) {
                ForEach(model.book.people) { person in
                    if person.id == last {
                        Button {
                            pick(person.id)
                        } label: {
                            Text(person.name).buttonLabel()
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button {
                            pick(person.id)
                        } label: {
                            Text(person.name).buttonLabel()
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Cancel").buttonLabel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Style.pad * 1.5)
        .frame(minWidth: 420)
    }

    private func pick(_ id: UUID) {
        dismiss()
        Task { await model.read(source, for: id) }
    }
}

/// The photo's small preview, as Finder makes it.
struct PhotoPreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            }
        }
        .frame(width: 48, height: 32)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 48, height: 32),
                                                       scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

struct HistoryScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            HStack(spacing: Style.gap) {
                ScreenTitle(text: "History")
                Picker("", selection: Binding(get: { model.historyPerson }, set: { model.showHistory($0) })) {
                    ForEach(model.book.people) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Table(model.historyEntries.indices.map { HistoryRow(index: $0, entry: model.historyEntries[$0]) }) {
                TableColumn("Name") { Text($0.entry.fileName).lineLimit(1) }
                TableColumn("Taken") { row in
                    Text(row.entry.taken ?? "No time").monospacedDigit().lineLimit(1)
                }
                TableColumn("Size") { Text(PhotoText.size($0.entry.size)).monospacedDigit().lineLimit(1) }
                TableColumn("Imported") { Text($0.entry.imported.formatted(date: .abbreviated, time: .shortened)).lineLimit(1) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Style.radius))
        }
        .padding(Style.pad * 1.5)
        .onAppear {
            if model.historyPerson == nil { model.showHistory(model.book.people.first?.id) }
        }
    }
}

struct HistoryRow: Identifiable {
    let index: Int
    let entry: HistoryEntry
    var id: Int { index }
}

struct CardsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "Cards") {
            Toggle("Open Geotag when a card is inserted", isOn: Binding(get: { model.openOnCard }, set: { model.setOpenOnCard($0) }))
                .toggleStyle(.switch)
            StatusLine(text: model.cardsLine)
        }
    }
}

/// The Photos screen on its own, for pictures made off-screen.
public struct PhotosScreenProbe: View {
    public init() {}
    public var body: some View { PhotosScreen() }
}
