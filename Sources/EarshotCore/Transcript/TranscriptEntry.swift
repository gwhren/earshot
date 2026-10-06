import Foundation

/// One utterance: what was heard and what it became in each target language.
public struct TranscriptEntry: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Audio is on its way to the speech model.
        case transcribing
        /// Text is known; the translations are streaming in.
        case translating
        case done
        /// Something went wrong; `sourceText` and any translations that arrived may still be useful.
        case failed(String)
    }

    public let id: UUID
    /// The segmenter id of the (first) utterance behind this entry; stable across preview → final.
    public let segmentID: Int
    /// Offset from the start of the listening session, in seconds.
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var createdAt: Date
    public var sourceText: String
    /// Language code reported by the recognizer (or the configured source language).
    public var sourceLanguage: String?
    /// Translations keyed by language code. A target in the language being spoken
    /// holds what was heard, as-is.
    public var translations: [String: String]
    /// Codes of the languages this entry is translated into, in display order.
    public var targetLanguages: [String]
    public var state: State

    public init(
        id: UUID = UUID(),
        segmentID: Int,
        startTime: TimeInterval,
        duration: TimeInterval,
        createdAt: Date = Date(),
        sourceText: String = "",
        sourceLanguage: String? = nil,
        translations: [String: String] = [:],
        targetLanguages: [String],
        state: State = .transcribing
    ) {
        self.id = id
        self.segmentID = segmentID
        self.startTime = startTime
        self.duration = duration
        self.createdAt = createdAt
        self.sourceText = sourceText
        self.sourceLanguage = sourceLanguage
        self.translations = translations
        self.targetLanguages = targetLanguages
        self.state = state
    }

    public var isFinished: Bool {
        switch state {
        case .done, .failed: return true
        case .transcribing, .translating: return false
        }
    }

    /// The translation into `code`, or "" while there is none.
    public func translation(_ code: String) -> String {
        translations[code] ?? ""
    }

    /// The translation into the first target language.
    public var primaryTranslation: String {
        targetLanguages.first.map { translation($0) } ?? ""
    }

    /// Best text to show: the first translation that has arrived, falling back to what was heard.
    public var displayText: String {
        targetLanguages.lazy.map { translation($0) }.first { !$0.isEmpty } ?? sourceText
    }
}

/// The utterance still being spoken, transcribed (and optionally translated) on the fly.
public struct LivePreview: Equatable, Sendable {
    public var segmentID: Int
    public var sourceText: String
    /// Translations so far, keyed by language code.
    public var translations: [String: String]

    public init(segmentID: Int, sourceText: String, translations: [String: String] = [:]) {
        self.segmentID = segmentID
        self.sourceText = sourceText
        self.translations = translations
    }
}

/// Writes transcripts out as text, Markdown or SubRip subtitles.
public enum TranscriptExporter {
    public enum Format: String, CaseIterable, Sendable {
        case plainText
        case markdown
        case srt

        public var fileExtension: String {
            switch self {
            case .plainText: return "txt"
            case .markdown: return "md"
            case .srt: return "srt"
            }
        }

        public var title: String {
            switch self {
            case .plainText: return "Plain Text"
            case .markdown: return "Markdown (bilingual)"
            case .srt: return "Subtitles (SRT)"
            }
        }
    }

    public static func export(_ entries: [TranscriptEntry], as format: Format, includeSource: Bool = true) -> String {
        let finished = entries.filter { !$0.displayText.isEmpty }
        switch format {
        case .plainText:
            // Entries in several languages take several lines, so leave a blank line between them.
            let separator = finished.contains { $0.targetLanguages.count > 1 } ? "\n\n" : "\n"
            return finished.map { plainText($0, includeSource: includeSource) }.joined(separator: separator) + "\n"
        case .markdown:
            var lines = ["# Earshot transcript", ""]
            for entry in finished {
                let targets = entry.targetLanguages.map { $0.uppercased() }.joined(separator: ", ")
                let language = entry.sourceLanguage.map { " · \($0.uppercased()) → \(targets)" } ?? ""
                lines.append("**\(clock(entry.startTime))**\(language)")
                lines.append("")
                if entry.targetLanguages.count > 1 {
                    let translations = labelledTranslations(entry)
                    if translations.isEmpty {
                        lines.append(entry.sourceText)
                        lines.append("")
                    } else {
                        if let source = extraSource(entry, includeSource: includeSource) {
                            lines.append("> \(source)")
                            lines.append("")
                        }
                        for translation in translations {
                            lines.append("**\(translation.label)** \(translation.text)")
                            lines.append("")
                        }
                    }
                } else {
                    if includeSource, !entry.sourceText.isEmpty, entry.sourceText != entry.primaryTranslation {
                        lines.append("> \(entry.sourceText)")
                        lines.append("")
                    }
                    lines.append(entry.displayText)
                    lines.append("")
                }
            }
            return lines.joined(separator: "\n")
        case .srt:
            var blocks: [String] = []
            for (index, entry) in finished.enumerated() {
                let end = entry.startTime + max(entry.duration, 1)
                var block = "\(index + 1)\n\(srtTimestamp(entry.startTime)) --> \(srtTimestamp(end))\n"
                if entry.targetLanguages.count > 1 {
                    let texts = labelledTranslations(entry).map(\.text)
                    block += (texts.isEmpty ? [entry.sourceText] : texts).joined(separator: "\n")
                    if !texts.isEmpty, let source = extraSource(entry, includeSource: includeSource) {
                        block += "\n\(source)"
                    }
                } else {
                    block += entry.displayText
                    if includeSource, !entry.primaryTranslation.isEmpty, entry.sourceText != entry.primaryTranslation {
                        block += "\n\(entry.sourceText)"
                    }
                }
                blocks.append(block)
            }
            return blocks.joined(separator: "\n\n") + "\n"
        }
    }

    private static func plainText(_ entry: TranscriptEntry, includeSource: Bool) -> String {
        guard entry.targetLanguages.count > 1 else {
            let translation = entry.primaryTranslation
            return includeSource && entry.sourceText != translation && !translation.isEmpty
                ? "\(translation)\n    (\(entry.sourceText))"
                : entry.displayText
        }
        var lines = labelledTranslations(entry).map { "\($0.label): \($0.text)" }
        if lines.isEmpty {
            lines = [entry.sourceText]
        } else if let source = extraSource(entry, includeSource: includeSource) {
            lines.append("    (\(source))")
        }
        return lines.joined(separator: "\n")
    }

    /// Each translation that arrived, labelled with its language badge, in display order.
    private static func labelledTranslations(_ entry: TranscriptEntry) -> [(label: String, text: String)] {
        entry.targetLanguages.compactMap { code in
            let text = entry.translation(code)
            return text.isEmpty ? nil : (code.uppercased(), text)
        }
    }

    /// The original, when it's wanted and isn't already one of the translations.
    private static func extraSource(_ entry: TranscriptEntry, includeSource: Bool) -> String? {
        guard includeSource, !entry.sourceText.isEmpty,
              !entry.targetLanguages.contains(where: { entry.translation($0) == entry.sourceText }) else { return nil }
        return entry.sourceText
    }

    /// `HH:MM:SS,mmm`
    public static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let totalMilliseconds = Int((max(0, seconds) * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let secs = (totalMilliseconds / 1000) % 60
        let millis = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    /// `M:SS` or `H:MM:SS`
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
