#if os(macOS)
import SwiftUI

/// Ordering a table by any column (David, 6 November 2026): a click sorts
/// ascending, the next descending, with the Mac's arrow at the right of the
/// heading. The column doing it has its heading in the accent colour and a
/// faint tint down its cells.
struct SortColumns<Row> {
    /// Each sortable column's id and how it orders.
    let all: [(id: String, comparator: KeyPathComparator<Row>)]

    /// The column the order is by, if any.
    func id(of order: [KeyPathComparator<Row>]) -> String? {
        guard let first = order.first else { return nil }
        return all.first { $0.comparator.keyPath == first.keyPath }?.id
    }

    /// The order a remembered choice stands for.
    func order(_ id: String?, ascending: Bool) -> [KeyPathComparator<Row>] {
        guard var comparator = all.first(where: { $0.id == id })?.comparator else { return [] }
        comparator.order = ascending ? .forward : .reverse
        return [comparator]
    }
}

extension Text {
    /// A heading, in the accent colour while its column orders the table.
    func sortHeading(_ on: Bool) -> Text {
        on ? self.foregroundColor(.accentColor).bold() : self
    }
}

extension View {
    /// The faint tint down the column that orders the table.
    func sortTint(_ on: Bool) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                if on { Color.accentColor.opacity(0.07).padding(.horizontal, -6).padding(.vertical, -4) }
            }
    }
}

#endif
