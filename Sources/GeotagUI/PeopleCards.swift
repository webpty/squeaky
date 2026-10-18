import AppKit
import SwiftUI
import GeotagCore

/// An icon-only button: a circle the size of the other buttons.
struct RoundIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color(nsColor: .controlColor)))
                .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .accessibilityLabel(label)
    }
}

enum Folders {
    /// A folder chosen on this Mac.
    @MainActor
    static func choose(startingAt start: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let start { panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A NAS folder as kept: the share and the path inside it, so it does not
    /// depend on where this Mac mounts the share ("homes-1" is still "homes").
    static func nasPath(_ url: URL) -> String {
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeURLForRemountingKey]
        if let values = try? url.resourceValues(forKeys: keys), let volume = values.volume,
           let share = values.volumeURLForRemounting?.lastPathComponent, !share.isEmpty, share != "/" {
            let root = volume.standardizedFileURL.pathComponents
            let inside = url.standardizedFileURL.pathComponents.dropFirst(root.count)
            return ([share] + inside).joined(separator: "/")
        }
        let parts = url.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes" { return parts.dropFirst(2).joined(separator: "/") }
        return url.path
    }

    static func shown(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "Not chosen" }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: People

struct PeopleCard: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Person?
    @State private var removing: Person?

    var body: some View {
        Card(title: "People") {
            VStack(spacing: 0) {
                ForEach(model.book.people) { person in
                    HStack(spacing: Style.gap) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(person.name).font(.headline).lineLimit(1)
                            Text("Saved in: \(Folders.shown(person.saveFolder))")
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text("NAS: \(Folders.shown(person.nasFolder))")
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: Style.gap)
                        RoundIconButton(symbol: "pencil", label: "Edit") { editing = person }
                        RoundIconButton(symbol: "trash", label: "Remove") { removing = person }
                    }
                    .padding(.vertical, 8)
                    if person.id != model.book.people.last?.id { Divider() }
                }
            }
            HStack(spacing: Style.gap) {
                Button {
                    editing = Person(name: "")
                } label: {
                    Text("Add person").buttonLabel()
                }
                StatusLine(text: model.peopleLine)
            }
        }
        .sheet(item: $editing) { person in
            PersonEditor(person: person) { saved in
                model.save(saved)
            }
            .textSelection(.enabled)
        }
        .alert("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let id = removing?.id { model.remove(person: id) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            let count = removing.map { model.book.cameras(of: $0.id).count } ?? 0
            Text(count == 0 ? "" : count == 1 ? "Their camera is removed from the list too." : "Their \(count) cameras are removed from the list too.")
        }
    }
}

struct PersonEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var person: Person
    let onSave: (Person) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            Text(person.name.isEmpty ? "Add person" : person.name).font(.headline).lineLimit(1)
            // One row each, every field and button reaching the same right edge.
            HStack(spacing: Style.gap) {
                Text("Name").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                TextField("", text: $person.name).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: Style.gap) {
                Text("Save folder").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                Text(Folders.shown(person.saveFolder))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    if let url = Folders.choose(startingAt: person.saveFolder) { person.saveFolder = url.path }
                } label: {
                    Text("Choose").buttonLabel()
                }
            }
            HStack(spacing: Style.gap) {
                Text("NAS folder").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                TextField("", text: Binding(get: { person.nasFolder ?? "" },
                                            set: { person.nasFolder = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                Button {
                    if let url = Folders.choose(startingAt: "/Volumes") { person.nasFolder = Folders.nasPath(url) }
                } label: {
                    Text("Choose").buttonLabel()
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
                Button {
                    person.name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(person)
                    dismiss()
                } label: {
                    Text("Save").buttonLabel()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(person.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Style.pad * 1.5)
        .frame(width: 560)
    }
}

// MARK: Cameras

enum OffsetText {
    static func describe(_ seconds: Int?) -> String {
        guard let seconds else { return "Offset not set" }
        if seconds == 0 { return "On time" }
        let a = abs(seconds)
        var parts: [String] = []
        if a >= 3600 { parts.append("\(a / 3600) h") }
        if a % 3600 >= 60 { parts.append("\(a % 3600 / 60) min") }
        if a % 60 > 0 { parts.append("\(a % 60) s") }
        return parts.joined(separator: " ") + (seconds > 0 ? " ahead" : " behind")
    }

    static func zone(_ zone: CameraZone) -> String {
        switch zone {
        case .fromPhoto: return "Zone from the photo"
        case .fixed(let id): return ZoneList.label(id)
        case .notSet: return "Zone not set"
        }
    }
}

enum ZoneList {
    static let all: [String] = TimeZone.knownTimeZoneIdentifiers.sorted()

    static func label(_ id: String) -> String {
        guard let zone = TimeZone(identifier: id) else { return id }
        let s = zone.secondsFromGMT()
        let sign = s < 0 ? "−" : "+"
        let h = abs(s) / 3600, m = abs(s) % 3600 / 60
        return "\(id.replacingOccurrences(of: "_", with: " ")) (GMT\(sign)\(h)\(m == 0 ? "" : String(format: ":%02d", m)))"
    }
}

struct CamerasCard: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Camera?
    @State private var removing: Camera?

    var body: some View {
        Card(title: "Cameras") {
            VStack(spacing: 0) {
                ForEach(model.book.cameras) { camera in
                    HStack(spacing: Style.gap) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(camera.model).font(.headline).lineLimit(1)
                            Text([model.book.person(camera.personId)?.name ?? "Nobody",
                                  OffsetText.zone(camera.zone),
                                  OffsetText.describe(camera.offsetSeconds)].joined(separator: " · "))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: Style.gap)
                        RoundIconButton(symbol: "pencil", label: "Edit") { editing = camera }
                        RoundIconButton(symbol: "trash", label: "Remove") { removing = camera }
                    }
                    .padding(.vertical, 8)
                    if camera.id != model.book.cameras.last?.id { Divider() }
                }
            }
            Button {
                if let first = model.book.people.first {
                    editing = Camera(personId: first.id, model: "", zone: .notSet)
                }
            } label: {
                Text("Add camera").buttonLabel()
            }
            .disabled(model.book.people.isEmpty)
        }
        .sheet(item: $editing) { camera in
            CameraEditor(camera: camera, people: model.book.people) { saved in
                model.save(saved)
            }
            .textSelection(.enabled)
        }
        .alert("Remove \(removing?.model ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let id = removing?.id { model.remove(camera: id) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        }
    }
}

struct CameraEditor: View {
    enum Clock: String, CaseIterable, Identifiable {
        case notSet, onTime, ahead, behind
        var id: String { rawValue }
        var title: String {
            switch self {
            case .notSet: return "Not set"
            case .onTime: return "On time"
            case .ahead: return "Ahead"
            case .behind: return "Behind"
            }
        }
    }

    /// The zone picker's choices: from the photo, not set, or a named zone.
    enum ZoneChoice: Hashable {
        case fromPhoto, notSet, named(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State var camera: Camera
    let people: [Person]
    let onSave: (Camera) -> Void

    @State private var clock = Clock.notSet
    @State private var hours = 0
    @State private var minutes = 0
    @State private var seconds = 0
    @State private var zone = ZoneChoice.notSet
    @State private var line = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            Text(camera.model.isEmpty ? "Add camera" : camera.model).font(.headline).lineLimit(1)
            // One row each, the wide fields reaching the same right edge.
            HStack(spacing: Style.gap) {
                Text("Person").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                Picker("", selection: $camera.personId) {
                    ForEach(people) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
            }
            HStack(spacing: Style.gap) {
                Text("Model").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                TextField("", text: $camera.model).textFieldStyle(.roundedBorder)
                Button {
                    readFromPhoto()
                } label: {
                    Text("Read from a photo").buttonLabel()
                }
            }
            HStack(spacing: Style.gap) {
                Text("Time zone").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                Picker("", selection: $zone) {
                    Text("From the photo").tag(ZoneChoice.fromPhoto)
                    Text("Not set").tag(ZoneChoice.notSet)
                    Divider()
                    ForEach(ZoneList.all, id: \.self) { Text(ZoneList.label($0)).tag(ZoneChoice.named($0)) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
            }
            HStack(spacing: Style.gap) {
                Text("Clock").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                Picker("", selection: $clock) {
                    ForEach(Clock.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
            }
            if clock == .ahead || clock == .behind {
                HStack(spacing: Style.gap) {
                    Text("By").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                    HStack(spacing: 8) {
                        number($hours, "h", 0...23)
                        number($minutes, "min", 0...59)
                        number($seconds, "s", 0...59)
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack {
                StatusLine(text: line)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Cancel").buttonLabel()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    Text("Save").buttonLabel()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(camera.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Style.pad * 1.5)
        .frame(width: 600)
        .onAppear(perform: load)
    }

    private func number(_ value: Binding<Int>, _ unit: String, _ range: ClosedRange<Int>) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
            Stepper("", value: value, in: range).labelsHidden()
            Text(unit).lineLimit(1)
        }
    }

    private func load() {
        switch camera.zone {
        case .fromPhoto: zone = .fromPhoto
        case .fixed(let id): zone = .named(id)
        case .notSet: zone = .notSet
        }
        guard let offset = camera.offsetSeconds else { clock = .notSet; return }
        clock = offset == 0 ? .onTime : offset > 0 ? .ahead : .behind
        let a = abs(offset)
        hours = a / 3600
        minutes = a % 3600 / 60
        seconds = a % 60
    }

    private func readFromPhoto() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let reading = CameraReader.read(url) else {
            line = "\(url.lastPathComponent) says nothing about its camera."
            return
        }
        camera.model = reading.model
        if reading.zone != nil {
            zone = .fromPhoto
            line = "Model and time zone read."
        } else {
            if zone == .fromPhoto { zone = .notSet }
            line = "Model read. This photo has no time zone."
        }
    }

    private func save() {
        camera.model = camera.model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch zone {
        case .fromPhoto: camera.zone = .fromPhoto
        case .notSet: camera.zone = .notSet
        case .named(let id): camera.zone = .fixed(id)
        }
        let total = hours * 3600 + minutes * 60 + seconds
        switch clock {
        case .notSet: camera.offsetSeconds = nil
        case .onTime: camera.offsetSeconds = 0
        case .ahead: camera.offsetSeconds = total
        case .behind: camera.offsetSeconds = -total
        }
        onSave(camera)
        dismiss()
    }
}
