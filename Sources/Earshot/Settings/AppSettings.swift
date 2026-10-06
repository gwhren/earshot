import AppKit
import Combine
import EarshotCore
import SwiftUI

/// Every user preference, persisted in `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    // MARK: Server & models

    @Published var serverURL: String { didSet { store(serverURL, "serverURL") } }
    @Published var useSeparateSpeechServer: Bool { didSet { store(useSeparateSpeechServer, "useSeparateSpeechServer") } }
    @Published var speechServerURL: String { didSet { store(speechServerURL, "speechServerURL") } }
    @Published var apiKey: String { didSet { store(apiKey, "apiKey") } }
    @Published var speechModel: String { didSet { store(speechModel, "speechModel") } }
    /// Empty means "whatever model MLX Studio has loaded".
    @Published var translationModel: String { didSet { store(translationModel, "translationModel") } }
    @Published var promptStyle: PromptStyle { didSet { store(promptStyle.rawValue, "promptStyle") } }
    @Published var disableThinking: Bool { didSet { store(disableThinking, "disableThinking") } }
    @Published var temperature: Double { didSet { store(temperature, "temperature") } }
    @Published var instructions: String { didSet { store(instructions, "instructions") } }
    @Published var contextTurns: Int { didSet { store(contextTurns, "contextTurns") } }

    // MARK: Languages

    /// Empty means "detect automatically".
    @Published var sourceLanguageCode: String { didSet { store(sourceLanguageCode, "sourceLanguage") } }
    @Published var targetLanguageCode: String {
        didSet {
            store(targetLanguageCode, "targetLanguage")
            if secondTargetLanguageCode == targetLanguageCode { secondTargetLanguageCode = "" }
        }
    }
    /// A second language to show alongside the first; empty means none.
    @Published var secondTargetLanguageCode: String {
        didSet {
            // The same language twice would just be one column; treat it as none.
            if !secondTargetLanguageCode.isEmpty, secondTargetLanguageCode == targetLanguageCode {
                secondTargetLanguageCode = ""
            }
            store(secondTargetLanguageCode, "secondTargetLanguage")
        }
    }
    @Published var skipSameLanguage: Bool { didSet { store(skipSameLanguage, "skipSameLanguage") } }

    // MARK: Listening

    @Published var sensitivity: Double { didSet { store(sensitivity, "sensitivity") } }
    @Published var pauseLength: Double { didSet { store(pauseLength, "pauseLength") } }
    @Published var maximumSegment: Double { didSet { store(maximumSegment, "maximumSegment") } }
    @Published var continuousMode: Bool { didSet { store(continuousMode, "continuousMode") } }
    @Published var livePreview: LivePreviewMode { didSet { store(livePreview.rawValue, "livePreview") } }

    // MARK: Display

    @Published var displayStyle: DisplayStyle { didSet { store(displayStyle.rawValue, "displayStyle") } }
    @Published var themeID: ThemeID { didSet { store(themeID.rawValue, "theme") } }
    @Published var fontFamily: String { didSet { store(fontFamily, "fontFamily") } }
    @Published var fontSize: Double { didSet { store(fontSize, "fontSize") } }
    @Published var fontWeight: FontWeightOption { didSet { store(fontWeight.rawValue, "fontWeight") } }
    @Published var textAlignment: TextAlignmentOption { didSet { store(textAlignment.rawValue, "textAlignment") } }
    @Published var lineSpacing: Double { didSet { store(lineSpacing, "lineSpacing") } }
    @Published var showOriginal: Bool { didSet { store(showOriginal, "showOriginal") } }
    @Published var backgroundOpacity: Double { didSet { store(backgroundOpacity, "backgroundOpacity") } }
    @Published var customTextColor: String { didSet { store(customTextColor, "customTextColor") } }
    @Published var customBackgroundColor: String { didSet { store(customBackgroundColor, "customBackgroundColor") } }
    @Published var customAccentColor: String { didSet { store(customAccentColor, "customAccentColor") } }
    @Published var subtitleLines: Int { didSet { store(subtitleLines, "subtitleLines") } }
    @Published var tickerSpeed: Double { didSet { store(tickerSpeed, "tickerSpeed") } }
    @Published var tickerUppercase: Bool { didSet { store(tickerUppercase, "tickerUppercase") } }
    @Published var teleprompterMirror: Bool { didSet { store(teleprompterMirror, "teleprompterMirror") } }

    // MARK: Startup

    @Published var listenAtLaunch: Bool { didSet { store(listenAtLaunch, "listenAtLaunch") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func string(_ key: String, _ fallback: String) -> String { defaults.string(forKey: key) ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { (defaults.object(forKey: key) as? Bool) ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { (defaults.object(forKey: key) as? Double) ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { (defaults.object(forKey: key) as? Int) ?? fallback }

        serverURL = string("serverURL", "http://127.0.0.1:8080")
        useSeparateSpeechServer = bool("useSeparateSpeechServer", false)
        speechServerURL = string("speechServerURL", "http://127.0.0.1:8000")
        apiKey = string("apiKey", "")
        let storedSpeechModel = string("speechModel", PipelineConfiguration.defaultSpeechModel)
        speechModel = PipelineConfiguration.legacySpeechModels.contains(storedSpeechModel)
            ? PipelineConfiguration.defaultSpeechModel
            : storedSpeechModel
        translationModel = string("translationModel", "")
        promptStyle = PromptStyle(rawValue: string("promptStyle", "")) ?? .automatic
        disableThinking = bool("disableThinking", true)
        temperature = double("temperature", 0.1)
        instructions = string("instructions", "")
        contextTurns = int("contextTurns", 2)

        sourceLanguageCode = string("sourceLanguage", "")
        targetLanguageCode = string("targetLanguage", Languages.defaultTarget(preferredLanguages: Locale.preferredLanguages).code)
        secondTargetLanguageCode = string("secondTargetLanguage", "")
        skipSameLanguage = bool("skipSameLanguage", true)

        sensitivity = double("sensitivity", 0.5)
        pauseLength = double("pauseLength", 0.7)
        maximumSegment = double("maximumSegment", 12)
        continuousMode = bool("continuousMode", false)
        livePreview = LivePreviewMode(rawValue: string("livePreview", "")) ?? .originalAndTranslation

        displayStyle = DisplayStyle(rawValue: string("displayStyle", "")) ?? .subtitles
        themeID = ThemeID(rawValue: string("theme", "")) ?? .midnight
        fontFamily = string("fontFamily", FontCatalog.system)
        fontSize = double("fontSize", 26)
        fontWeight = FontWeightOption(rawValue: string("fontWeight", "")) ?? .semibold
        textAlignment = TextAlignmentOption(rawValue: string("textAlignment", "")) ?? .center
        lineSpacing = double("lineSpacing", 2)
        showOriginal = bool("showOriginal", false)
        backgroundOpacity = double("backgroundOpacity", 0.88)
        customTextColor = string("customTextColor", "#FFFFFF")
        customBackgroundColor = string("customBackgroundColor", "#1B1030")
        customAccentColor = string("customAccentColor", "#FF6B6B")
        subtitleLines = int("subtitleLines", 2)
        tickerSpeed = double("tickerSpeed", 90)
        tickerUppercase = bool("tickerUppercase", false)
        teleprompterMirror = bool("teleprompterMirror", false)

        listenAtLaunch = bool("listenAtLaunch", false)
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: Derived values

    var theme: Theme {
        Theme.preset(
            themeID,
            customText: Color(hex: customTextColor) ?? .white,
            customBackground: Color(hex: customBackgroundColor) ?? .black,
            customAccent: Color(hex: customAccentColor) ?? .red
        )
    }

    var targetLanguage: Language {
        Languages.language(code: targetLanguageCode) ?? Languages.english
    }

    var sourceLanguage: Language? {
        sourceLanguageCode.isEmpty ? nil : Languages.language(code: sourceLanguageCode)
    }

    /// The second pinned language, unless it's unset or the same as the first.
    var secondTargetLanguage: Language? {
        guard let second = Languages.language(code: secondTargetLanguageCode), second.code != targetLanguage.code else { return nil }
        return second
    }

    /// The languages captions are shown in, in display order.
    var targetLanguages: [Language] {
        [targetLanguage] + (secondTargetLanguage.map { [$0] } ?? [])
    }

    /// What the display shows, left to right (top to bottom in the ticker): each
    /// target language, with the original first when it's switched on and there's
    /// only one target.
    var panes: [DisplayPane] {
        let translations = targetLanguages.map { DisplayPane.translation($0.code) }
        guard showOriginal, translations.count == 1 else { return translations }
        return [.original] + translations
    }

    /// "AUTO → FR", or "AUTO → EN + UK" with two languages pinned.
    var languagePairLabel: String {
        "\(sourceLanguage?.badge ?? "AUTO") → \(targetLanguages.map(\.badge).joined(separator: " + "))"
    }

    var translationEndpoint: ServerEndpoint {
        ServerEndpoint(string: serverURL, apiKey: apiKey) ?? .mlxStudioGateway
    }

    var speechEndpoint: ServerEndpoint {
        guard useSeparateSpeechServer else { return translationEndpoint }
        return ServerEndpoint(string: speechServerURL, apiKey: apiKey) ?? translationEndpoint
    }

    func font(size: CGFloat, weight: FontWeightOption? = nil) -> Font {
        FontCatalog.font(family: fontFamily, size: size, weight: weight ?? fontWeight)
    }

    func nsFont(size: CGFloat, weight: FontWeightOption? = nil) -> NSFont {
        FontCatalog.nsFont(family: fontFamily, size: size, weight: weight ?? fontWeight)
    }

    /// Base font size scaled for the current display style.
    var styledFontSize: CGFloat {
        CGFloat(fontSize) * displayStyle.fontScale
    }

    func pipelineConfiguration() -> PipelineConfiguration {
        var segmenter = SegmenterConfiguration()
        segmenter.applySensitivity(sensitivity)
        segmenter.endSilence = pauseLength
        segmenter.maximumSegment = maximumSegment
        segmenter.continuous = continuousMode
        segmenter.previewInterval = livePreview == .off ? 0 : 1.0
        return PipelineConfiguration(
            targetLanguages: targetLanguages,
            sourceLanguage: sourceLanguage,
            speechEndpoint: speechEndpoint,
            translationEndpoint: translationEndpoint,
            speechModel: speechModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? PipelineConfiguration.defaultSpeechModel
                : speechModel.trimmingCharacters(in: .whitespacesAndNewlines),
            translationModel: translationModel.trimmingCharacters(in: .whitespacesAndNewlines),
            promptStyle: promptStyle,
            contextTurns: contextTurns,
            instructions: instructions,
            temperature: temperature,
            disableThinking: disableThinking,
            livePreview: livePreview,
            skipSameLanguage: skipSameLanguage,
            segmenter: segmenter
        )
    }

    func adjustFontSize(by delta: Double) {
        fontSize = min(120, max(12, fontSize + delta))
    }
}
