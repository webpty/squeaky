import Foundation
#if os(macOS)
import AppKit
#endif
import Combine

/// What Geotag is busy with, for the icon in the menu bar: one line for each
/// thing going on, and how far the first of them has got (David, 18 October
/// 2026). Nothing going on, no icon.
@MainActor
public final class WorkStatus: ObservableObject {
    /// "Saving 340 of 3,630", "Sending to the NAS: 12 of 200".
    @Published public private(set) var lines: [String] = []
    /// 0 to 1, in fortieths so the icon is not drawn again for every photo;
    /// nil when it cannot be said.
    @Published public private(set) var fraction: Double?

    public var shown: Bool { !lines.isEmpty }

    public init() {}

    func set(lines: [String], fraction: Double?) {
        let steps = fraction.map { (min(max($0, 0), 1) * 40).rounded(.down) / 40 }
        if self.lines != lines { self.lines = lines }
        if self.fraction != steps { self.fraction = steps }
    }
}

#if os(macOS)
/// The menu bar's icon: a pin in a ring that fills as the work goes, drawn
/// as a template so it takes the menu bar's own colour, light or dark.
public enum WorkIcon {
    public static let size = NSSize(width: 18, height: 18)

    public static func image(_ fraction: Double?) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let centre = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 7.3
            let ring = NSBezierPath()
            ring.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
            ring.lineWidth = 1.6
            NSColor.black.withAlphaComponent(0.3).setStroke()
            ring.stroke()
            if let fraction, fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: centre, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(min(fraction, 1)), clockwise: true)
                arc.lineWidth = 1.6
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            if let pin = NSImage(systemSymbolName: "mappin", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)) {
                let s = pin.size
                pin.draw(in: NSRect(x: centre.x - s.width / 2, y: centre.y - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Geotag"
        return image
    }
}

/// The icon in the menu bar while Geotag works, with its menu: what is going
/// on, then Open Geotag. One for the app, started with its window.
@MainActor
public final class MenuBarIcon: NSObject {
    private static var current: MenuBarIcon?

    private let work: WorkStatus
    private var item: NSStatusItem?
    private var watching: [AnyCancellable] = []

    /// Starts showing the icon whenever this work is going on. Called again,
    /// it changes nothing.
    public static func watch(_ work: WorkStatus) {
        guard current?.work !== work else { return }
        current = MenuBarIcon(work: work)
    }

    private init(work: WorkStatus) {
        self.work = work
        super.init()
        watching.append(work.$lines.combineLatest(work.$fraction).receive(on: RunLoop.main).sink { [weak self] lines, fraction in
            self?.show(lines: lines, fraction: fraction)
        })
    }

    private func show(lines: [String], fraction: Double?) {
        guard !lines.isEmpty else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = self.item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        item.button?.image = WorkIcon.image(fraction)
        item.menu = Self.menu(lines: lines, target: self)
    }

    /// The lines, greyed as a menu shows what cannot be chosen, then Open Geotag.
    public static func menu(lines: [String], target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for line in lines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Geotag", action: #selector(MenuBarIcon.openGeotag), keyEquivalent: "")
        open.target = target
        menu.addItem(open)
        return menu
    }

    @objc func openGeotag() {
        Windows.bringForward()
    }
}

#endif
