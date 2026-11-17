import Foundation
import GeotagCore

/// The phone's language for Geotag's words: the first of the phone's own
/// languages Geotag has, else English (David, 15 November 2026: English,
/// Spanish, French, Simplified and Traditional Chinese, as Countries;
/// Traditional Chinese only from 0.29.37).
enum PhoneWords {
    static func language(_ preferred: [String] = Locale.preferredLanguages) -> String {
        for tag in preferred {
            let id = Locale(identifier: tag)
            let code = id.language.languageCode?.identifier ?? ""
            switch code {
            case "en", "es", "fr": return code
            // Traditional Chinese only; a phone in Simplified reads it too (0.29.37).
            case "zh": return "zh-Hant"
            default: continue
            }
        }
        return "en"
    }

    static func load() {
        let name = "words-" + language()
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        Words.table = table
    }
}
