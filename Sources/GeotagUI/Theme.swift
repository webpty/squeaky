import AppKit
import SwiftUI

/// One corner radius, one padding, used everywhere.
public enum Style {
    public static let radius: CGFloat = 10
    public static let pad: CGFloat = 16
    public static let gap: CGFloat = 12
}

public struct Card<Content: View>: View {
    let title: String
    let content: Content

    public init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            if !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
            }
            content
        }
        .padding(Style.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Style.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Style.radius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

public struct ScreenTitle: View {
    let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.title)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A line that is always there, so nothing shifts when a message appears.
public struct StatusLine: View {
    let text: String
    let lines: Int

    public init(text: String, lines: Int = 1) {
        self.text = text
        self.lines = lines
    }

    /// Its height is kept whether there is anything to say or not.
    public var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(text.isEmpty ? .clear : .secondary)
            .lineLimit(lines, reservesSpace: true)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(alignment: .topLeading)
    }
}

public extension View {
    /// One line, with room on all four sides, for every button label.
    func buttonLabel() -> some View {
        self.lineLimit(1).padding(.vertical, 3).padding(.horizontal, 6).handCursor()
    }

    /// The pointing hand over anything that can be clicked.
    func handCursor() -> some View {
        modifier(HandCursor())
    }
}

struct HandCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(.link)
        } else {
            content.onHover { inside in
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
        }
    }
}

public enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
