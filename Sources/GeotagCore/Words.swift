import Foundation

/// Geotag's words in the phone's language (David, 15 November 2026: the
/// phone app in English, Spanish, French and both Chinese, as Countries).
/// Every text shown is written as an English template, "{0} of {1}", with
/// what goes in it after. The phone sets `table` at launch from its own
/// word lists; the Mac never does, so it shows the templates as written.
public enum Words {
    nonisolated(unsafe) public static var table: [String: String] = [:]

    private static let slot = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)

    public static func t(_ template: String, _ args: Any...) -> String {
        let text = table[template] ?? template
        guard !args.isEmpty else { return text }
        // In one pass, so nothing put in is read as a slot itself.
        var out = ""
        var at = text.startIndex
        let ns = text as NSString
        for m in slot.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: text), let n = Int(ns.substring(with: m.range(at: 1))), n < args.count else { continue }
            out += text[at..<r.lowerBound]
            out += "\(args[n])"
            at = r.upperBound
        }
        return out + text[at...]
    }
}
