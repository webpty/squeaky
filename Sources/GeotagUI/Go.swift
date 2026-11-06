import AppKit
import SwiftUI
import GeotagCore

/// Command and a number for each sidebar page in order, Settings keeping
/// its Command-comma: Photos 1, Queue 2, History 3, then Tracks 4 to
/// Download 7 (David, 6 November 2026).
public enum Shortcuts {
    public static let pages: [Screen] = Screen.sidebar.filter { $0 != .settings } + Screen.tools

    public static func key(_ screen: Screen) -> KeyEquivalent? {
        pages.firstIndex(of: screen).map { KeyEquivalent(Character("\($0 + 1)")) }
    }
}

/// The shortcuts, listed in the Mac's View menu.
public struct GoMenu: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ForEach(Shortcuts.pages) { screen in
            Button(screen.title) {
                model.show(screen)
                Windows.bringForward()
            }
            .keyboardShortcut(Shortcuts.key(screen)!, modifiers: .command)
        }
        Divider()
    }
}

/// Download: a disk image that installs Geotag on another Mac, for either
/// kind (0.25.0, David, 6 November 2026).
struct DownloadScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            ScreenTitle(text: "Download")
            Text("Makes a disk image that installs Geotag on another Mac. It is saved to Downloads.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Style.gap) {
                ForEach(Installer.Chip.allCases, id: \.self) { chip in
                    Button {
                        Task { await model.saveDownload(chip) }
                    } label: {
                        Text("Download for \(chip.title)").buttonLabel()
                    }
                    .fixedSize()
                    .disabled(model.makingDownload)
                }
            }
            StatusLine(text: model.downloadLine, busy: model.makingDownload)
            Spacer()
        }
        .padding(Style.pad * 1.5)
    }
}
