#if os(macOS)
import SwiftUI
import SqueakyCore

/// The setup, once on a new Mac and again from the Squeaky menu: whose Mac
/// it is, where each person's photos are saved, the track service, the NAS,
/// and whether Squeaky opens when a card goes in (David, 1 November 2026).
/// Everything it sets is in Settings too, and stays changeable there.
struct SetupView: View {
    enum Step: Int, CaseIterable {
        case owner, folders, service, nas, cards

        var title: String {
            switch self {
            case .owner: return "Whose Mac is this?"
            case .folders: return "Save folders"
            case .service: return "Track service"
            case .nas: return "NAS"
            case .cards: return "Cards"
            }
        }
    }

    /// Filled in on the track service step when the address is empty; it can be changed.
    static let serviceAddress = "https://geotrac.cc"

    @EnvironmentObject var model: AppModel
    @State private var step: Step
    @State private var newName = ""

    init(at step: Step = .owner) {
        _step = State(initialValue: step)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            HStack {
                Text(step.title).font(.title2).lineLimit(1)
                Spacer()
                Text("\(step.rawValue + 1) of \(Step.allCases.count)")
                    .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Divider()
            Group {
                switch step {
                case .owner: owner
                case .folders: folders
                case .service: service
                case .nas: nas
                case .cards: cards
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Button {
                    model.settingUp = false
                } label: {
                    Text("Later").buttonLabel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if step != .owner {
                    Button {
                        go(-1)
                    } label: {
                        Text("Back").buttonLabel()
                    }
                }
                if step == .cards {
                    Button {
                        model.finishSetup()
                    } label: {
                        Text("Done").buttonLabel()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        go(1)
                    } label: {
                        Text("Next").buttonLabel()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Style.pad * 1.5)
        .frame(width: 680, height: 460)
        .onChange(of: step) { _, now in
            if now == .service, model.serviceAddress.isEmpty { model.serviceAddress = Self.serviceAddress }
        }
    }

    private func go(_ by: Int) {
        step = Step(rawValue: step.rawValue + by) ?? step
    }

    // MARK: Steps

    /// Whose Mac: first in line when a card asks whose it is. Each card still asks.
    private var owner: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            Picker("", selection: Binding(get: { model.macOwner }, set: { model.setMacOwner($0) })) {
                Text("Nobody in particular").tag(UUID?.none)
                ForEach(model.book.people) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            // A new install starts with nobody (0.21.0): people are added here or in Settings.
            HStack(spacing: Style.gap) {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(addPerson)
                Button(action: addPerson) {
                    Text("Add person").buttonLabel()
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addPerson() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let person = Person(name: name)
        model.save(person)
        if model.macOwner == nil { model.setMacOwner(person.id) }
        newName = ""
    }

    /// Each person's save folder on this Mac; any can stay empty.
    private var folders: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(model.peopleOwnerFirst) { person in
                    HStack(spacing: Style.gap) {
                        Text(person.name).lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                        Text(Folders.shown(person.saveFolder))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            var changed = person
                            if let url = Folders.choose(startingAt: person.saveFolder) {
                                changed.saveFolder = url.path
                                model.save(changed)
                            }
                        } label: {
                            Text("Choose folder…").buttonLabel()
                        }
                    }
                    .padding(.vertical, 8)
                    if person.id != model.peopleOwnerFirst.last?.id { Divider() }
                }
            }
        }
    }

    /// The address and this Mac's own key, checked as they are saved.
    private var service: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            Grid(alignment: .leading, horizontalSpacing: Style.gap, verticalSpacing: Style.gap) {
                GridRow {
                    Text("Address").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                    TextField("", text: $model.serviceAddress).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Key").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                    SecureField("", text: $model.serviceKey).textFieldStyle(.roundedBorder)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Style.gap) {
                Button {
                    Task { await model.saveService() }
                } label: {
                    Text("Save and check").buttonLabel()
                }
                StatusLine(text: model.settingsLine, lines: 2, busy: model.settingsBusy)
            }
            .disabled(model.settingsBusy)
        }
    }

    /// One NAS for this Mac, and each person's folder on it.
    private var nas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Style.gap) {
                Grid(alignment: .leading, horizontalSpacing: Style.gap, verticalSpacing: Style.gap) {
                    GridRow {
                        Text("Address").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                        TextField("", text: $model.nasAddress).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Backup address").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                        TextField("", text: $model.nasBackupAddress).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("User name").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                        TextField("", text: $model.nasUser).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Password").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                        SecureField("", text: $model.nasPassword).textFieldStyle(.roundedBorder)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: Style.gap) {
                    Button {
                        Task { await model.saveNAS() }
                    } label: {
                        Text("Save and check").buttonLabel()
                    }
                    StatusLine(text: model.nasLine, lines: 2, busy: model.nasBusy)
                }
                .disabled(model.nasBusy)
                Divider()
                ForEach(model.peopleOwnerFirst) { person in
                    HStack(spacing: Style.gap) {
                        Text(person.name).lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                        TextField("", text: Binding(
                            get: { model.book.person(person.id)?.nasFolder ?? "" },
                            set: { text in
                                guard var changed = model.book.person(person.id) else { return }
                                changed.nasFolder = text.isEmpty ? nil : text
                                model.save(changed)
                            }))
                            .textFieldStyle(.roundedBorder)
                        Button {
                            if var changed = model.book.person(person.id), let url = Folders.choose(startingAt: "/Volumes") {
                                changed.nasFolder = Folders.nasPath(url)
                                model.save(changed)
                            }
                        } label: {
                            Text("Choose").buttonLabel()
                        }
                    }
                }
            }
        }
    }

    /// Whether Squeaky opens by itself when a card goes in, and why it starts at login for that.
    private var cards: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            Toggle("Open Squeaky when a card is inserted", isOn: Binding(get: { model.openOnCard }, set: { model.setOpenOnCard($0) }))
                .toggleStyle(.switch)
            Text("With this on, Squeaky starts quietly at login, so it can take a card the moment it goes in, keep it out of Finder, and keep the card unchanged.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.cardsLine.isEmpty {
                StatusLine(text: model.cardsLine)
            }
        }
    }
}

#endif
