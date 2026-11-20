import SqueakyCore
import SqueakyUI
import AVKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The card, chosen in the Files list once it is plugged in, and its photos.
struct PhotosTab: View {
    @ObservedObject var model: AppModel
    @State private var choosing = false
    @StateObject private var pictures = Pictures()
    @StateObject private var library = LibraryLocations()
    @State private var showingFailed = false
    // Days and selecting (0.31.0).
    @State private var foldChanged = 0
    /// Where each square is, kept without redrawing the page as it scrolls (0.34.2).
    @State private var spotBox = SpotBox()
    @State private var slide: Slide?
    @State private var ignoring = false
    @State private var fingerAt: CGPoint?
    @State private var listFrame: CGRect = .zero
    @State private var rolling: Task<Void, Never>?
    @State private var viewing: Viewing?

    var body: some View {
        NavigationStack {
          ScrollViewReader { scroller in
            List {
                Section {
                    if let note = model.backgroundNote { StatusRow(text: note, busy: false) }
                    // A spinning wheel while the sync files are read or saved (0.29.18).
                    StatusRow(text: model.syncActivity ?? QueueText.sync(model.lastSave, problem: model.sharedProblem),
                              busy: model.syncActivity != nil)
                    StatusRow(text: model.photosLine, busy: model.photosBusy || model.saving || model.movingOutOfFiles)
                    // Who the SD card belongs to: said, not changed here (0.29.19); changed in Settings.
                    if let id = model.importPerson, model.book.person(id) != nil {
                        LabeledContent(Words.t("Card belongs to"),
                                       value: id == PhoneFolders.othersId ? Words.t("someone else") : Words.t("you"))
                    }
                    if !model.rows.isEmpty {
                        LabeledContent(Words.t("Photos"), value: counts)
                    }
                    // Every photo not saved, by name, with the full reason (0.29.28, David: "we need a button to show the error").
                    if model.results.values.contains(where: { if case .failed = $0 { return true }; return false }) {
                        Button(Words.t("Show unsaved")) { showingFailed = true }
                            .buttonStyle(WideButton(.grey)).buttonRow()
                    }
                    // Why photos wait: one line for each reason, with how many.
                    ForEach(reasons, id: \.self) { line in
                        Sentences(text: line).foregroundStyle(.secondary)
                    }
                }.cardRows()
                // Locations added later to photos already in Photos (0.31.8, David).
                if model.source == nil {
                    LibraryLocationsSection(model: model, library: library)
                }
                // Real buttons, each group in its own card, no titles (0.34.4, David).
                if model.saving {
                    Section {
                        Button(Words.t("Stop")) { model.stopSaving() }.buttonStyle(WideButton(.grey)).buttonRow()
                    }.cardRows()
                } else if model.source == nil {
                    Section {
                        // Everything saved and the card still in: nothing to open (0.29.40, David).
                        if model.cardStillIn, allSaved {
                            Text(Words.t("Copy done. Remove the card."))
                        } else {
                            Button(Words.t("Open card")) { choosing = true }
                                .buttonStyle(WideButton(.blue)).buttonRow()
                                .disabled(model.photosBusy || model.macOwner == nil)
                        }
                        if !model.rows.isEmpty {
                            Button(Words.t("Clear"), role: .destructive) { model.clearPhotos() }
                                .buttonStyle(WideButton(.red)).buttonRow()
                        }
                    }.cardRows()
                } else {
                    // Every photo on the card at once (0.31.3, David): blue to select, purple to deselect.
                    // Only what can be chosen: with "Hide already saved" on, nothing saved (0.34.4).
                    let choosable = model.choosable
                    let everything = !choosable.isEmpty && choosable.allSatisfy(\.ticked)
                    // Selecting and saving in one card (0.34.5, David).
                    Section {
                        VStack(spacing: 12) {
                            Button(everything ? Words.t("Deselect all") : Words.t("Select all")) {
                                model.setTicked(Set(choosable.map(\.id)), !everything)
                            }
                            .buttonStyle(WideButton(everything ? .purple : .blue))
                            .disabled(choosable.isEmpty || model.photosBusy)
                            // Side by side, one above the other where the words are too long (0.34.4, David).
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) { saveButtons }
                                VStack(spacing: 10) { saveButtons }
                            }
                            Toggle(Words.t("Hide already saved"), isOn: $model.hideSaved)
                                .disabled(model.photosBusy || model.saving)
                        }
                        .buttonRow()
                    }.cardRows()
                    // No "Done with this card": the iPhone has no eject; the card is let go of
                    // once every photo is saved, or when it is taken out (0.34.4, David).
                }
                // The photos by day, to choose what is saved (0.31.0, David, 18 November 2026).
                let days = PhotoDays.days(shown: shown, all: model.rows, model: model)
                let _ = foldChanged
                ForEach(days) { day in
                    let open = PhotoDays.isOpen(day)
                    // Each day a card: the title and its photos together (0.31.3, David).
                    Section {
                        DayHeader(day: day, open: open, canChange: canPick,
                                  toggleOpen: { PhotoDays.setOpen(day, !open); foldChanged += 1 },
                                  selectAll: { on in model.setTicked(Set(day.frames.flatMap { $0.rows.map(\.id) }), on) })
                            .listRowSeparator(.hidden)
                        if open {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                                ForEach(day.frames) { frame in
                                    PickSquare(box: pictures.box(frame.picture), ticked: frame.ticked,
                                               saved: frame.rows.allSatisfy { model.isSaved($0) },
                                               failed: frame.rows.contains { if case .failed? = model.results[$0.id] { return true }; return false },
                                               video: frame.isVideo, raw: PhotoKinds.isRawVideo(frame.picture), duration: frame.duration)
                                        .id(frame.id)
                                        // Held: the panel, larger, to go through them (0.33.1, David).
                                        .onLongPressGesture(minimumDuration: 0.4) { viewing = Viewing(id: frame.id) }
                                        .background(GeometryReader { g in
                                            Color.clear.preference(key: FrameSpots.self, value: [frame.id: g.frame(in: .global)])
                                        })
                                        .onTapGesture {
                                            guard canPick else { return }
                                            model.setTicked(Set(frame.rows.map(\.id)), !frame.ticked)
                                        }
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 10, trailing: 10))
                            .listRowSeparator(.hidden)
                            .onAppear { pictures.make(day.frames.map(\.picture)) }
                        }
                    }.cardRows()
                }
            }
            .onPreferenceChange(FrameSpots.self) { spotBox.all = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { listFrame = $0 }
            .scrollDisabled(slide != nil)
            .simultaneousGesture(sliding(days: days(), scroller: scroller))
            .scrollContentBackground(.hidden)
            // The last card's photo behind every tab, veiled (0.29.5, David, 16 November 2026).
            .background(Backdrop(image: model.sidebarImage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PageTitle(title: Words.t("Photos"))
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.checkAgain() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(Words.t("Check photos again"))
                        .disabled(model.source == nil || model.saving || model.photosBusy)
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    let source = Self.source(url)
                    CardWatch.remember(url, id: source.id)
                    model.choose(source)
                case .failure(let error): model.tell(error.localizedDescription)
                }
            }
            #if DEBUG
            .onAppear {
                if CommandLine.arguments.contains("--choose-card") { choosing = true }
                if CommandLine.arguments.contains("--ask-whose") {
                    model.askingWhose = PhotoSource(id: "debug", name: "EOS_DIGITAL", url: URL(fileURLWithPath: "/"), isCard: true)
                }
            }
            #endif
          }
        }
        // Looked through again whenever the tracks or the offsets change, and after a save.
        .task(id: "\(model.tracks.count)|\(model.timeline.pieces.count)|\(model.saving)|\(model.source == nil)") {
            guard !model.saving, model.source == nil else { return }
            await library.lookIfAllowed(model)
        }
        .sheet(isPresented: $showingFailed) { NotSaved(model: model) }
        .sheet(item: $viewing) { start in
            Viewer(model: model, pictures: pictures, framesNow: { days().flatMap(\.frames) }, current: start.id)
                .presentationDragIndicator(.visible)
        }
        // Apart from the Files list above: two on one view and neither opens.
        .sheet(isPresented: Binding(get: { model.askingWhose != nil }, set: { if !$0 { model.askingWhose = nil } })) {
            WhoseCard(model: model)
        }
    }

    /// Save selected in blue, Save all in teal.
    @ViewBuilder var saveButtons: some View {
        // Dimmed with nothing selected, and with everything selected: Save all does that (0.34.6, David).
        let all = !model.choosable.isEmpty && model.choosable.allSatisfy(\.ticked)
        Button(Words.t("Save selected")) { Task { await model.checkTracksBeforeSave() } }
            .buttonStyle(WideButton(.blue))
            .disabled(!model.canSave || all)
        // Every photo on the card that can be chosen (0.32.1, David).
        Button(Words.t("Save all")) { model.saveAll() }
            .buttonStyle(WideButton(.teal))
            .disabled(model.choosable.isEmpty || model.photosBusy || model.importPerson == nil)
    }

    /// The photos shown, one square per frame: the JPG of a RAW+JPG pair.
    var shown: [ImportRow] {
        // While the card is in, every photo on it, to choose from (0.31.0); once out, the
        // copies saved from it still on the phone, with a check (0.29.12).
        let cardIn = model.source != nil
        let waiting = model.rows.filter { row in
            if let copy = model.results[row.id]?.url {
                // Card out: only a copy still on the phone has a picture; a raw sent to the server has none (0.29.14).
                return cardIn || FileManager.default.fileExists(atPath: copy.path)
            }
            // "Hide already saved" while the card is in (0.34.4, David).
            return cardIn && !(model.hideSaved && model.isSaved(row))
        }
        var seen = Set<String>()
        // A JPG stands for its raw; a video for its RAW video (0.33.0).
        func rank(_ r: ImportRow) -> Int {
            switch (r.photo.fileName as NSString).pathExtension.lowercased() {
            case "jpg", "jpeg": return 0
            case "mp4", "mov": return 1
            default: return 2
            }
        }
        let jpgFirst = waiting.sorted { rank($0) < rank($1) }
        var keep = Set<String>()
        for row in jpgFirst {
            let frame = (row.photo.fileName as NSString).deletingPathExtension + "|" + (row.photo.taken ?? "")
            if seen.insert(frame).inserted { keep.insert(row.id) }
        }
        return waiting.filter { keep.contains($0.id) }
    }

    /// The days as shown now, for the slide.
    func days() -> [PhotoDay] { PhotoDays.days(shown: shown, all: model.rows, model: model) }

    /// Photos can be selected while the card is in and nothing is being saved.
    var canPick: Bool { model.source != nil && !model.saving }

    /// A slide over the squares: starting sideways it selects, or deselects
    /// when it starts on a selected one, everything from where it began to
    /// where the finger is; starting up or down it is left to the scrolling.
    /// Near the top or bottom tenth the page moves by itself (0.31.0).
    func sliding(days: [PhotoDay], scroller: ScrollViewProxy) -> some Gesture {
        // The finger and the squares in the same screen coordinates (0.31.3: a named
        // space put the slide one row off).
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard canPick, !ignoring else { return }
                fingerAt = value.location
                if slide == nil {
                    let sideways = abs(value.translation.width) > abs(value.translation.height)
                    guard sideways, let first = frame(at: value.startLocation) else { ignoring = true; return }
                    let open = days.filter { PhotoDays.isOpen($0) }
                    let frames = open.flatMap(\.frames)
                    let order = frames.map(\.id)
                    guard let start = order.firstIndex(of: first) else { ignoring = true; return }
                    var before: [String: Bool] = [:]
                    for f in frames { before[f.id] = f.ticked }
                    slide = Slide(order: order, start: start, select: !(before[first] ?? false), before: before, last: start)
                    roll(scroller: scroller, frames: frames)
                }
                reach()
            }
            .onEnded { _ in
                slide = nil
                ignoring = false
                fingerAt = nil
                rolling?.cancel()
                rolling = nil
            }
    }

    /// The square under a point, if any.
    func frame(at point: CGPoint) -> String? {
        spotBox.all.first { $0.value.contains(point) }?.key
    }

    /// Everything from the start of the slide to the square under the finger set as the slide says.
    func reach() {
        let frames = days().flatMap(\.frames)
        guard var s = slide, let point = fingerAt, let id = frame(at: point), let now = s.order.firstIndex(of: id), now != s.last else { return }
        s.last = now
        slide = s
        let range = min(s.start, now)...max(s.start, now)
        let byId = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0) })
        var on = Set<String>(), off = Set<String>()
        for (i, fid) in s.order.enumerated() {
            guard let f = byId[fid] else { continue }
            let want = range.contains(i) ? s.select : (s.before[fid] ?? false)
            if want != f.ticked { f.rows.forEach { if want { on.insert($0.id) } else { off.insert($0.id) } } }
        }
        model.setTicked(on, true)
        model.setTicked(off, false)
    }

    /// While the finger is in the top or bottom tenth, the page moves a row at a time.
    func roll(scroller: ScrollViewProxy, frames: [PhotoFrame]) {
        rolling?.cancel()
        rolling = Task { @MainActor in
            while !Task.isCancelled, slide != nil {
                try? await Task.sleep(for: .milliseconds(180))
                guard let point = fingerAt, let s = slide, listFrame.height > 0 else { continue }
                let visible = s.order.enumerated().filter { spotBox.all[$0.element].map { $0.maxY > listFrame.minY && $0.minY < listFrame.maxY } ?? false }.map(\.offset)
                guard let low = visible.min(), let high = visible.max() else { continue }
                if point.y > listFrame.minY + listFrame.height * 0.9, high + 1 < s.order.count {
                    withAnimation(.linear(duration: 0.17)) { scroller.scrollTo(s.order[min(high + 3, s.order.count - 1)], anchor: .bottom) }
                } else if point.y < listFrame.minY + listFrame.height * 0.1, low > 0 {
                    withAnimation(.linear(duration: 0.17)) { scroller.scrollTo(s.order[max(low - 3, 0)], anchor: .top) }
                } else {
                    continue
                }
                try? await Task.sleep(for: .milliseconds(30))
                reach()
            }
        }
    }

    /// "8 photos: Camera time offset not set".
    var reasons: [String] {
        guard !model.saving else { return [] }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for row in model.rows where row.needsReview && row.status != .alreadyImported && model.results[row.id] == nil {
            let why = PhotoText.location(row, gap: model.maxGapSeconds)
            if counts[why] == nil { order.append(why) }
            counts[why, default: 0] += 1
        }
        // Selected photos whose camera has no offset: what to do about it (0.31.8, David).
        let offsetWhy = Words.t("Camera time offset not set")
        let offsetSelected = model.rows.contains { $0.ticked && $0.placement == .review(.offsetNotSet) && model.results[$0.id] == nil }
        return order.map { why in
            let said = counts[why] == 1 ? Words.t("1 photo: {0}", why) : Words.t("{0} photos: {1}", counts[why]!.formatted(), why)
            return why == offsetWhy && offsetSelected
                ? said + ". " + Words.t("Show the offset code in Settings and photograph it with that camera.") : said
        }
    }

    /// "340 new, 12 already saved".
    /// Every photo on the card is saved, selected or not (0.32.1; 0.29.40 counted only the selected).
    var allSaved: Bool {
        !model.rows.isEmpty && model.rows.allSatisfy { model.isSaved($0) }
    }

    var counts: String {
        // Updated after every photo saved (0.29.13): saved now counts with saved before.
        let before = model.rows.filter { $0.status == .alreadyImported || model.results[$0.id]?.url != nil }.count
        let new = model.rows.count - before
        return before == 0 ? new.formatted() : Words.t("{0} new, {1} already saved", new.formatted(), before.formatted())
    }

    /// The card, or a folder on it: known again next time by the card's own id.
    static func source(_ url: URL, id known: String? = nil) -> PhotoSource {
        _ = url.startAccessingSecurityScopedResource()
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        let name = values?.volumeName ?? (url.lastPathComponent == "DCIM" ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent)
        let id = known ?? values?.volumeUUIDString ?? values?.volumeName ?? url.path
        return PhotoSource(id: id, name: name, url: url, isCard: true)
    }
}

/// The squares' pictures, made one after another in the photos' order, so
/// they appear from the first to the last (0.29.9), and kept while Squeaky runs.
@MainActor
final class Pictures: ObservableObject {
    /// Not published: a picture made redraws its own square alone, never the
    /// whole page, which shook the scrolling while a card loaded (0.34.2, David).
    private(set) var made: [URL: UIImage] = [:]
    private var boxes: [URL: PictureBox] = [:]
    private var queue: [URL] = []
    private var running = false

    /// The square's own holder of its picture.
    func box(_ url: URL) -> PictureBox {
        if let b = boxes[url] { return b }
        let b = PictureBox(made[url])
        boxes[url] = b
        return b
    }

    func make(_ urls: [URL]) {
        queue = urls.filter { made[$0] == nil }
        guard !running else { return }
        running = true
        Task {
            while !queue.isEmpty {
                let url = queue.removeFirst()
                if made[url] != nil { continue }
                if let image = await Task.detached(priority: .userInitiated, operation: { Pictures.picture(url) }).value {
                    made[url] = image
                    boxes[url]?.image = image
                }
            }
            running = false
        }
    }

    /// A JPG's own picture, not the small preview inside it, which carries
    /// black bands; a raw's preview, which has none and is quick.
    nonisolated static func picture(_ url: URL) -> UIImage? {
        if PhotoKinds.isVideo(url) {
            // A RAW video shows as purple with its icon, never a picture (0.33.1, David).
            if PhotoKinds.isRawVideo(url) { return nil }
            return MovieFrames.picture(url, maxPixel: 360).map(UIImage.init(cgImage:))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let jpg = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        let options: [CFString: Any] = [
            jpg ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
    }
}

/// A photo as a square, filled to its edges, cropped from the middle.
struct Square: View {
    let image: UIImage?
    var saved = false
    var failed = false
    var raw = false

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if raw {
                    RawVideoMark(size: 26)
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottomTrailing) {
                if saved || failed {
                    Image(systemName: saved ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, saved ? Color.green : Color.red)
                        .padding(4)
                }
            }
    }
}

/// Asked the first time a card is read and remembered: "Does this SD card
/// belong to David?" (0.29.19).
struct WhoseCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Words.t("Is this your card?")).font(.headline)
            HStack(spacing: 10) {
                Button(Words.t("Yes")) { pick(model.macOwner) }.buttonStyle(WideButton(.blue))
                Button(Words.t("No")) { pick(PhoneFolders.othersId) }.buttonStyle(WideButton(.grey))
            }
        }
        .padding(24)
        .presentationDetents([.height(170)])
    }

    func pick(_ id: UUID?) {
        guard let id, let source = model.askingWhose else { return }
        Task { await model.read(source, for: id) }
    }
}

/// Each photo not saved, by file name, with the whole reason (0.29.28).
struct NotSaved: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var failed: [(String, String)] {
        model.rows.compactMap { row in
            if case .failed(let why)? = model.results[row.id] { return (row.photo.fileName, Words.t(why)) }
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Try again with the card in; without it, what to do (0.29.31, David, 17 November 2026).
                Section {
                    if model.source != nil {
                        Button(Words.t("Try again")) {
                            dismiss()
                            Task { await model.tryUnsavedAgain() }
                        }
                        .buttonStyle(WideButton(.blue)).buttonRow()
                        .disabled(model.saving || model.photosBusy)
                    } else {
                        Text(Words.t("Insert the card to try again"))
                    }
                }.cardRows()
                Section {
                    ForEach(failed, id: \.0) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.0)
                            Sentences(text: item.1).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }.cardRows()
            }
            .navigationTitle(Words.t("Unsaved photos"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(Words.t("Close")) { dismiss() } } }
        }
    }
}

/// The square held, which the panel opens on.
struct Viewing: Identifiable {
    let id: String
}

/// Half the screen from the bottom: the photos and videos larger, one at a time,
/// swiped through sideways, closed by swiping down (0.33.1, David).
struct Viewer: View {
    @ObservedObject var model: AppModel
    /// The grid's small pictures, shown until the large one is ready.
    let pictures: Pictures
    @StateObject private var large = LargePictures()
    /// The squares as they are now: a deleted one is gone at once.
    let framesNow: () -> [PhotoFrame]
    @State var current: String
    @State private var asking = false
    @State private var problem: String?
    /// "Photo deleted", at the top of the panel for two seconds (0.34.3, David).
    @State private var note: String?
    @State private var detent: PresentationDetent = .height(Viewer.height(tall: false))
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let frames = framesNow()
        let frame = frames.first { $0.id == current }
        VStack(spacing: 0) {
            // A strip above the photo, under the panel's corners: they never cut it,
            // and the note that a photo was deleted never covers one (0.34.3, David).
            ZStack {
                if let note {
                    Text(note)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Viewer.topRoom)
            .animation(.easeOut(duration: 0.25), value: note)
            TabView(selection: $current) {
                ForEach(frames) { frame in
                    ViewerPage(frame: frame, shown: frame.id == current, large: large.box(frame.picture),
                               small: pictures.made[frame.picture]).tag(frame.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // The one shown, then the next and the previous, made ready (0.34.3, David).
            .onAppear {
                large.prepare(around: current, in: frames)
                detent = .height(Viewer.height(tall: tall(frames.first { $0.id == current })))
            }
            .onChange(of: current) { _, now in
                let all = framesNow()
                large.prepare(around: now, in: all)
                // Taller for a portrait video than a photo: each fills from side to side.
                withAnimation(.easeInOut(duration: 0.25)) {
                    detent = .height(Viewer.height(tall: tall(all.first { $0.id == now })))
                }
            }
            // Room below the photo for Delete, while the card is in (0.34.2, David).
            ZStack {
                if let frame, onCard(frame) {
                    // Apple's round button, in red (0.34.5, David).
                    Button { asking = true } label: {
                        Image(systemName: "trash").font(.system(size: 20)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .tint(.red)
                    .accessibilityLabel(Words.t("Delete"))
                    .disabled(model.saving || model.photosBusy)
                }
            }
            .frame(height: Viewer.buttonRoom)
        }
        // Lighter than the page, so the panel stands apart from it (0.34.4, David).
        .background(Palette.panel)
        .presentationDetents([.height(Viewer.height(tall: false)), .height(Viewer.height(tall: true))], selection: $detent)
        .presentationCornerRadius(14)
        .alert(Words.t("Are you sure?"), isPresented: $asking) {
            Button(Words.t("Cancel"), role: .cancel) {}
            Button(Words.t("Delete"), role: .destructive) { delete(frames: frames) }
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button(Words.t("Close"), role: .cancel) {}
        }
    }

    static let topRoom: CGFloat = 40
    static let buttonRoom: CGFloat = 64

    /// A portrait photo (2:3), or a portrait video (9:16) when `tall`, fills the
    /// panel's width, with the strip above and Delete below.
    static func height(tall: Bool) -> CGFloat {
        let screen = UIScreen.main.bounds.size
        let bottom = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom ?? 0
        return min(screen.height * 0.95, topRoom + screen.width * (tall ? 16.0 / 9.0 : 1.5) + buttonRoom + bottom)
    }

    /// A video taller than a photo: from its picture's own shape.
    func tall(_ frame: PhotoFrame?) -> Bool {
        guard let frame, frame.isVideo, let image = pictures.made[frame.picture], image.size.width > 0 else { return false }
        return image.size.height / image.size.width > 1.6
    }

    func onCard(_ frame: PhotoFrame) -> Bool {
        guard let source = model.source, !model.saving else { return false }
        return frame.rows.allSatisfy { $0.photo.url.path.hasPrefix(source.url.path) }
    }

    /// Every file of the square from the card, then on to the next one.
    func delete(frames: [PhotoFrame]) {
        guard let i = frames.firstIndex(where: { $0.id == current }) else { return }
        let next = i + 1 < frames.count ? frames[i + 1].id : (i > 0 ? frames[i - 1].id : nil)
        let video = frames[i].isVideo
        problem = model.deleteFromCard(Set(frames[i].rows.map(\.id)))
        guard problem == nil else { return }
        if let next { current = next } else { dismiss(); return }
        let said = video ? Words.t("Video deleted") : Words.t("Photo deleted")
        note = said
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if note == said { note = nil }
        }
    }
}

/// One photo or video in the panel.
struct ViewerPage: View {
    let frame: PhotoFrame
    let shown: Bool
    @ObservedObject var large: PictureBox
    /// The grid's picture, enlarged until the large one is ready: never black.
    let small: UIImage?
    @State private var player: AVPlayer?
    @State private var started = false

    var body: some View {
        ZStack {
            Palette.panel
            if PhotoKinds.isRawVideo(frame.picture) {
                RawVideoMark(size: 64)
            } else {
                if let image = large.image ?? small { Image(uiImage: image).resizable().scaledToFit() }
                // Over the picture, seen only once its first frame shows: no black (0.34.2, David).
                if let player {
                    VideoPlayer(player: player).opacity(started ? 1 : 0)
                }
                if player == nil, frame.playable {
                    Button {
                        let p = AVPlayer(url: frame.picture)
                        player = p
                        started = false
                        p.play()
                        Task { @MainActor in
                            while player === p, p.currentTime().seconds <= 0.05 { try? await Task.sleep(for: .milliseconds(40)) }
                            if player === p { started = true }
                        }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(Circle().fill(Color.black.opacity(0.9)))
                    }
                    .accessibilityLabel(Words.t("Play"))
                }
            }
        }
        // Swiped away: the video stops.
        .onChange(of: shown) { _, now in
            if !now { player?.pause(); player = nil }
        }
        .onDisappear { player?.pause() }
    }

    nonisolated static func large(_ url: URL) -> UIImage? {
        if PhotoKinds.isVideo(url) { return MovieFrames.picture(url, maxPixel: 1600).map(UIImage.init(cgImage:)) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ] as CFDictionary).map(UIImage.init(cgImage:))
    }
}

/// A RAW video, which cannot be shown: purple, with a broken video (0.33.1, David).
struct RawVideoMark: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Color.purple
            Image(systemName: "video.slash.fill")
                .font(.system(size: size))
                .foregroundStyle(.white)
        }
    }
}

/// One square's picture, watched by that square alone (0.34.2).
@MainActor
final class PictureBox: ObservableObject {
    @Published var image: UIImage?
    init(_ image: UIImage?) { self.image = image }
}

/// Where the squares are on screen, for the slide; changing it redraws nothing.
final class SpotBox {
    var all: [String: CGRect] = [:]
}

/// The panel's large pictures: the one shown first, then its neighbours, and
/// the last few seen kept, so a swipe never shows black (0.34.3, David).
@MainActor
final class LargePictures: ObservableObject {
    private var boxes: [URL: PictureBox] = [:]
    private var order: [URL] = []
    private var queue: [URL] = []
    private var running = false
    static let keep = 9

    func box(_ url: URL) -> PictureBox {
        if let b = boxes[url] { return b }
        let b = PictureBox(nil)
        boxes[url] = b
        return b
    }

    func prepare(around id: String, in frames: [PhotoFrame]) {
        guard let i = frames.firstIndex(where: { $0.id == id }) else { return }
        let wanted = [i, i + 1, i - 1, i + 2].filter { frames.indices.contains($0) }.map { frames[$0].picture }
            .filter { !PhotoKinds.isRawVideo($0) }
        queue = wanted.filter { box($0).image == nil }
        for url in wanted { order.removeAll { $0 == url }; order.append(url) }
        // Only the last few kept: the rest let go, to spare the phone's memory.
        while order.count > Self.keep {
            let old = order.removeFirst()
            boxes[old]?.image = nil
            boxes[old] = nil
        }
        guard !running else { return }
        running = true
        Task {
            while !queue.isEmpty {
                let url = queue.removeFirst()
                guard let b = boxes[url], b.image == nil else { continue }
                b.image = await Task.detached(priority: .userInitiated) { ViewerPage.large(url) }.value
            }
            running = false
        }
    }
}
