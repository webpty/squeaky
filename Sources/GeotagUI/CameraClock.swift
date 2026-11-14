#if os(macOS)
import AppKit
import SwiftUI
import GeotagCore

/// How to set the date, time and zone on one camera, from its maker's manual.
public struct CameraGuide: Identifiable, Sendable {
    public struct Step: Sendable {
        let text: String
        /// A picture of the camera's screen at this step, from the manual,
        /// kept in Geotag at Resources/CameraClock/<camera>/<file>.
        let picture: String?
    }

    public let id: String
    public let name: String
    /// Where the setting lives in the camera's menus.
    let path: String
    let steps: [Step]
    /// Anything else the manual says that matters for the clock.
    let notes: [String]
    /// The manual the steps come from.
    let source: URL

    /// Where the pictures are: inside the app, or the repo's own folder for
    /// pictures of the window made off-screen.
    public static var pictures = Bundle.main.resourceURL?.appendingPathComponent("CameraClock")

    func pictureURL(_ step: Step) -> URL? {
        guard let file = step.picture else { return nil }
        return Self.pictures?.appendingPathComponent("\(id)/\(file)")
    }
}

/// The window Camera clocks opens: the chosen camera's steps, with the pictures of
/// its screens.
public struct CameraClockWindow: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    private var guide: CameraGuide {
        CameraGuide.all.first { $0.id == model.cameraGuide } ?? CameraGuide.all[0]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            Picker("", selection: Binding(get: { guide.id }, set: { model.cameraGuide = $0 })) {
                ForEach(CameraGuide.all) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            ScrollView {
                VStack(alignment: .leading, spacing: Style.gap) {
                    ScreenTitle(text: guide.name)
                    Text(guide.path).font(.headline).textSelection(.enabled)
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                        GuideStepView(number: index + 1, step: step, picture: guide.pictureURL(step))
                    }
                    ForEach(guide.notes, id: \.self) { note in
                        Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Link("From \(guide.source.host ?? "the maker's manual")", destination: guide.source)
                        .font(.callout)
                        .handCursor()
                }
                .padding(.bottom, Style.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Style.pad * 1.5)
        .textSelection(.enabled)
    }
}

struct GuideStepView: View {
    let number: Int
    let step: CameraGuide.Step
    let picture: URL?

    var body: some View {
        HStack(alignment: .top, spacing: Style.gap) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color(nsColor: .controlColor)))
                .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor)))
            VStack(alignment: .leading, spacing: 8) {
                Text(step.text).fixedSize(horizontal: false, vertical: true)
                if let picture, let image = NSImage(contentsOf: picture) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: min(image.size.width * 2, 420), alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The window on its own, for pictures made off-screen.
public struct CameraClockProbe: View {
    public init() {}
    public var body: some View { CameraClockWindow() }
}

#endif
