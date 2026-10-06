import Foundation

/// A language Earshot can listen to and/or translate into.
public struct Language: Hashable, Identifiable, Sendable {
    /// Stable identifier (BCP 47 style, e.g. "en", "pt-BR", "zh-Hant").
    public let code: String
    /// English name shown in menus.
    public let name: String
    /// The language's own name for itself.
    public let nativeName: String
    /// Whisper's language code, or nil when Whisper cannot recognise it.
    public let whisperCode: String?
    /// Name used inside translation prompts ("Simplified Chinese" rather than "Chinese (Simplified)").
    public let promptName: String
    /// Code TranslateGemma expects for this language.
    public let translateGemmaCode: String

    public var id: String { code }

    public init(code: String, name: String, nativeName: String, whisperCode: String?, promptName: String? = nil, translateGemmaCode: String? = nil) {
        self.code = code
        self.name = name
        self.nativeName = nativeName
        self.whisperCode = whisperCode
        self.promptName = promptName ?? name
        self.translateGemmaCode = translateGemmaCode ?? code
    }

    /// "French — Français", or just the name when both are the same.
    public var menuTitle: String {
        nativeName == name ? name : "\(name) — \(nativeName)"
    }

    /// Short badge text such as "FR" or "ZH-HANT".
    public var badge: String { code.uppercased() }
}

public enum Languages {
    public static let all: [Language] = [
        Language(code: "en", name: "English", nativeName: "English", whisperCode: "en"),
        Language(code: "es", name: "Spanish", nativeName: "Español", whisperCode: "es"),
        Language(code: "fr", name: "French", nativeName: "Français", whisperCode: "fr"),
        Language(code: "de", name: "German", nativeName: "Deutsch", whisperCode: "de"),
        Language(code: "it", name: "Italian", nativeName: "Italiano", whisperCode: "it"),
        Language(code: "pt", name: "Portuguese", nativeName: "Português", whisperCode: "pt"),
        Language(code: "pt-BR", name: "Portuguese (Brazil)", nativeName: "Português (Brasil)", whisperCode: "pt", promptName: "Brazilian Portuguese"),
        Language(code: "nl", name: "Dutch", nativeName: "Nederlands", whisperCode: "nl"),
        Language(code: "sv", name: "Swedish", nativeName: "Svenska", whisperCode: "sv"),
        Language(code: "no", name: "Norwegian", nativeName: "Norsk", whisperCode: "no"),
        Language(code: "da", name: "Danish", nativeName: "Dansk", whisperCode: "da"),
        Language(code: "fi", name: "Finnish", nativeName: "Suomi", whisperCode: "fi"),
        Language(code: "is", name: "Icelandic", nativeName: "Íslenska", whisperCode: "is"),
        Language(code: "pl", name: "Polish", nativeName: "Polski", whisperCode: "pl"),
        Language(code: "cs", name: "Czech", nativeName: "Čeština", whisperCode: "cs"),
        Language(code: "sk", name: "Slovak", nativeName: "Slovenčina", whisperCode: "sk"),
        Language(code: "sl", name: "Slovenian", nativeName: "Slovenščina", whisperCode: "sl"),
        Language(code: "hr", name: "Croatian", nativeName: "Hrvatski", whisperCode: "hr"),
        Language(code: "bs", name: "Bosnian", nativeName: "Bosanski", whisperCode: "bs"),
        Language(code: "sr", name: "Serbian", nativeName: "Српски", whisperCode: "sr"),
        Language(code: "mk", name: "Macedonian", nativeName: "Македонски", whisperCode: "mk"),
        Language(code: "sq", name: "Albanian", nativeName: "Shqip", whisperCode: "sq"),
        Language(code: "hu", name: "Hungarian", nativeName: "Magyar", whisperCode: "hu"),
        Language(code: "ro", name: "Romanian", nativeName: "Română", whisperCode: "ro"),
        Language(code: "bg", name: "Bulgarian", nativeName: "Български", whisperCode: "bg"),
        Language(code: "el", name: "Greek", nativeName: "Ελληνικά", whisperCode: "el"),
        Language(code: "ru", name: "Russian", nativeName: "Русский", whisperCode: "ru"),
        Language(code: "uk", name: "Ukrainian", nativeName: "Українська", whisperCode: "uk"),
        Language(code: "be", name: "Belarusian", nativeName: "Беларуская", whisperCode: "be"),
        Language(code: "lt", name: "Lithuanian", nativeName: "Lietuvių", whisperCode: "lt"),
        Language(code: "lv", name: "Latvian", nativeName: "Latviešu", whisperCode: "lv"),
        Language(code: "et", name: "Estonian", nativeName: "Eesti", whisperCode: "et"),
        Language(code: "ca", name: "Catalan", nativeName: "Català", whisperCode: "ca"),
        Language(code: "eu", name: "Basque", nativeName: "Euskara", whisperCode: "eu"),
        Language(code: "gl", name: "Galician", nativeName: "Galego", whisperCode: "gl"),
        Language(code: "cy", name: "Welsh", nativeName: "Cymraeg", whisperCode: "cy"),
        Language(code: "mt", name: "Maltese", nativeName: "Malti", whisperCode: "mt"),
        Language(code: "la", name: "Latin", nativeName: "Latina", whisperCode: "la"),
        Language(code: "tr", name: "Turkish", nativeName: "Türkçe", whisperCode: "tr"),
        Language(code: "az", name: "Azerbaijani", nativeName: "Azərbaycanca", whisperCode: "az"),
        Language(code: "kk", name: "Kazakh", nativeName: "Қазақ тілі", whisperCode: "kk"),
        Language(code: "uz", name: "Uzbek", nativeName: "Oʻzbekcha", whisperCode: "uz"),
        Language(code: "hy", name: "Armenian", nativeName: "Հայերեն", whisperCode: "hy"),
        Language(code: "ka", name: "Georgian", nativeName: "ქართული", whisperCode: "ka"),
        Language(code: "ar", name: "Arabic", nativeName: "العربية", whisperCode: "ar"),
        Language(code: "he", name: "Hebrew", nativeName: "עברית", whisperCode: "he"),
        Language(code: "fa", name: "Persian", nativeName: "فارسی", whisperCode: "fa"),
        Language(code: "ur", name: "Urdu", nativeName: "اردو", whisperCode: "ur"),
        Language(code: "hi", name: "Hindi", nativeName: "हिन्दी", whisperCode: "hi"),
        Language(code: "bn", name: "Bengali", nativeName: "বাংলা", whisperCode: "bn"),
        Language(code: "pa", name: "Punjabi", nativeName: "ਪੰਜਾਬੀ", whisperCode: "pa"),
        Language(code: "gu", name: "Gujarati", nativeName: "ગુજરાતી", whisperCode: "gu"),
        Language(code: "mr", name: "Marathi", nativeName: "मराठी", whisperCode: "mr"),
        Language(code: "ne", name: "Nepali", nativeName: "नेपाली", whisperCode: "ne"),
        Language(code: "ta", name: "Tamil", nativeName: "தமிழ்", whisperCode: "ta"),
        Language(code: "te", name: "Telugu", nativeName: "తెలుగు", whisperCode: "te"),
        Language(code: "kn", name: "Kannada", nativeName: "ಕನ್ನಡ", whisperCode: "kn"),
        Language(code: "ml", name: "Malayalam", nativeName: "മലയാളം", whisperCode: "ml"),
        Language(code: "si", name: "Sinhala", nativeName: "සිංහල", whisperCode: "si"),
        Language(code: "th", name: "Thai", nativeName: "ไทย", whisperCode: "th"),
        Language(code: "lo", name: "Lao", nativeName: "ລາວ", whisperCode: "lo"),
        Language(code: "km", name: "Khmer", nativeName: "ខ្មែរ", whisperCode: "km"),
        Language(code: "my", name: "Burmese", nativeName: "မြန်မာ", whisperCode: "my"),
        Language(code: "vi", name: "Vietnamese", nativeName: "Tiếng Việt", whisperCode: "vi"),
        Language(code: "id", name: "Indonesian", nativeName: "Bahasa Indonesia", whisperCode: "id"),
        Language(code: "ms", name: "Malay", nativeName: "Bahasa Melayu", whisperCode: "ms"),
        Language(code: "tl", name: "Filipino", nativeName: "Filipino", whisperCode: "tl", promptName: "Filipino (Tagalog)"),
        Language(code: "zh-Hans", name: "Chinese (Simplified)", nativeName: "简体中文", whisperCode: "zh", promptName: "Simplified Chinese", translateGemmaCode: "zh-CN"),
        Language(code: "zh-Hant", name: "Chinese (Traditional)", nativeName: "繁體中文", whisperCode: "zh", promptName: "Traditional Chinese", translateGemmaCode: "zh-TW"),
        Language(code: "yue", name: "Cantonese", nativeName: "粵語", whisperCode: "yue"),
        Language(code: "ja", name: "Japanese", nativeName: "日本語", whisperCode: "ja"),
        Language(code: "ko", name: "Korean", nativeName: "한국어", whisperCode: "ko"),
        Language(code: "mn", name: "Mongolian", nativeName: "Монгол", whisperCode: "mn"),
        Language(code: "sw", name: "Swahili", nativeName: "Kiswahili", whisperCode: "sw"),
        Language(code: "af", name: "Afrikaans", nativeName: "Afrikaans", whisperCode: "af"),
        Language(code: "yo", name: "Yoruba", nativeName: "Yorùbá", whisperCode: "yo"),
        Language(code: "ha", name: "Hausa", nativeName: "Hausa", whisperCode: "ha"),
        Language(code: "so", name: "Somali", nativeName: "Soomaali", whisperCode: "so"),
    ]

    /// Languages offered as translation targets, sorted by name.
    public static let targets: [Language] = all.sorted { $0.name < $1.name }

    /// Languages the speech recognizer can be told to expect, sorted by name.
    public static let sources: [Language] = all.filter { $0.whisperCode != nil }.sorted { $0.name < $1.name }

    public static let english = all[0]

    public static func language(code: String) -> Language? {
        let lowered = code.lowercased()
        return all.first { $0.code.lowercased() == lowered }
    }

    /// Resolves whatever a speech recognizer reported ("en", "english", "zh", …).
    public static func language(recognized value: String) -> Language? {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return nil }
        if let exact = all.first(where: { $0.code.lowercased() == lowered }) { return exact }
        if let whisper = all.first(where: { $0.whisperCode == lowered }) { return whisper }
        return all.first { $0.name.lowercased() == lowered || $0.promptName.lowercased() == lowered }
    }

    /// Lenient lookup for command-line arguments: code, Whisper code, English or native name.
    public static func find(_ query: String) -> Language? {
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return nil }
        if let match = language(recognized: lowered) { return match }
        return all.first { $0.nativeName.lowercased() == lowered }
    }

    /// A sensible first target: English for non-English speakers, Spanish otherwise.
    public static func defaultTarget(preferredLanguages: [String]) -> Language {
        let first = preferredLanguages.first?.lowercased() ?? "en"
        if first.hasPrefix("en") {
            return language(code: "es")!
        }
        return english
    }
}
