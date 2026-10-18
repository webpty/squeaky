import Foundation

/// The cameras' own software: the version each photo records, and where each
/// maker offers the latest (David, 18 October 2026).
public enum Firmware {
    /// "1.1.1" from what ExifTool reads: Canon's "Firmware Version 1.1.1", an
    /// older Canon's "1.0.2", Nikon's "COOLPIX P950   V1.0".
    public static func version(_ texts: [String?]) -> String? {
        for text in texts.compactMap({ $0 }) {
            if let range = text.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) { return String(text[range]) }
        }
        return nil
    }

    /// "1.10.0" is newer than "1.9.9": part by part, as numbers.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// The maker's download page for a model, as its photos name it. Canon's
    /// pages show the firmware under Software & Drivers.
    public static func page(forModel model: String) -> URL? {
        let pages: [String: String] = [
            "canon eos r5m2": "https://www.usa.canon.com/support/p/eos-r5-mark-ii",
            "canon eos r7": "https://www.usa.canon.com/support/p/eos-r7",
            "canon eos rebel t3i": "https://www.usa.canon.com/support/p/eos-rebel-t3i",
            "canon eos 600d": "https://www.usa.canon.com/support/p/eos-rebel-t3i",
            "coolpix p950": "https://downloadcenter.nikonimglib.com/en/download/fw/523.html",
        ]
        return pages[model.trimmingCharacters(in: .whitespaces).lowercased()].flatMap(URL.init(string:))
    }
}
