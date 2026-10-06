import Foundation

/// Tidies speech-recognition and model output before it reaches the screen.
public enum TextCleanup {
    // Phrases Whisper is notorious for inventing over silence, music or noise.
    private static let hallucinationMarkers = [
        "amara.org",
        "dimatorzok",
        "субтитры сделал",
        "субтитры создавал",
        "редактор субтитров",
        "продолжение следует",
        "untertitel im auftrag",
        "明鏡與點點",
        "明镜与点点",
        "字幕由",
        "ご視聴ありがとうございました",
        "시청해주셔서 감사합니다",
        "mbc 뉴스",
        "thanks for watching",
        "thank you for watching",
        "thank you so much for watching",
        "please subscribe",
        "subscribe to my channel",
        "like and subscribe",
    ]

    private static let hallucinationExact: Set<String> = ["you", "bye bye", "thank you for listening"]

    private static let endTokens = [
        "<end_of_turn>", "<start_of_turn>", "<eos>", "<|im_end|>", "<|im_start|>", "<|endoftext|>",
        "<|eot_id|>", "<|end|>", "</s>",
    ]

    /// Collapses whitespace runs (including newlines) into single spaces.
    public static func normalizeWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Removes sound annotations such as `[Music]`, `(applause)` or `♪`.
    public static func removeSoundTags(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\[[^\\]]{0,40}\\]", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "\\((?:[a-z ]{0,20}(?:music|applause|laughter|laughs|laughing|silence|inaudible|noise|coughs?|coughing|sighs?|breathing|static|beep|chuckles?))\\)",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(of: "[♪♫🎵🎶]+", with: " ", options: .regularExpression)
        return result
    }

    /// True for transcripts that are almost certainly not real speech.
    public static func isNoise(_ transcript: String) -> Bool {
        let stripped = normalizeWhitespace(removeSoundTags(transcript))
        guard stripped.contains(where: { $0.isLetter || $0.isNumber }) else { return true }
        let lowered = stripped.lowercased()
        if hallucinationMarkers.contains(where: { lowered.contains($0) }) { return true }
        let bare = lowered.unicodeScalars
            .filter { CharacterSet.letters.contains($0) || $0 == " " }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return hallucinationExact.contains(bare)
    }

    /// Cleans a raw transcript; returns an empty string when it is noise.
    public static func cleanTranscript(_ transcript: String) -> String {
        guard !isNoise(transcript) else { return "" }
        return collapseRepetitions(normalizeWhitespace(removeSoundTags(transcript)))
    }

    /// Hides reasoning (`<think>…</think>`, even while still open) and anything after an end-of-turn token.
    public static func visibleModelOutput(_ text: String) -> String {
        var result = text
        for token in endTokens {
            if let range = result.range(of: token) {
                result = String(result[..<range.lowerBound])
            }
        }
        while let open = result.range(of: "<think>") {
            if let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result = String(result[..<open.lowerBound])
            }
        }
        // Some templates open the reasoning block in the prompt, so only the closing tag shows up.
        if let close = result.range(of: "</think>", options: .backwards) {
            result = String(result[close.upperBound...])
        }
        return result
    }

    /// Final polish for a translation: no reasoning, labels, wrapping quotes or stray whitespace.
    public static func cleanTranslation(_ text: String) -> String {
        var result = visibleModelOutput(text).trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(
            of: "^(?:here is the translation|here's the translation|translation|translated text|[\\p{L} ]{1,30} translation)\\s*(?:\\([^)]{0,30}\\))?\\s*[:：]\\s*",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        result = stripWrappingQuotes(result.trimmingCharacters(in: .whitespacesAndNewlines))
        return collapseRepetitions(normalizeWhitespace(result))
    }

    /// Collapses a sentence or short phrase repeated back-to-back (a common Whisper loop).
    public static func collapseRepetitions(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return text }

        func key(_ word: String) -> String {
            word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }

        var changed = false
        var phraseLength = 1
        while phraseLength <= 12, phraseLength * 3 <= words.count {
            let minimumRepeats = phraseLength == 1 ? 4 : 3
            var index = 0
            while index + phraseLength * minimumRepeats <= words.count {
                let phrase = words[index..<(index + phraseLength)].map(key)
                var repeats = 1
                while index + phraseLength * (repeats + 1) <= words.count {
                    let start = index + phraseLength * repeats
                    guard words[start..<(start + phraseLength)].map(key) == phrase else { break }
                    repeats += 1
                }
                if repeats >= minimumRepeats {
                    words.removeSubrange((index + phraseLength)..<(index + phraseLength * repeats))
                    changed = true
                }
                index += 1
            }
            phraseLength += 1
        }
        return changed ? words.joined(separator: " ") : text
    }

    private static func stripWrappingQuotes(_ text: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»"), ("„", "“"), ("「", "」"), ("『", "』"), ("'", "'")]
        guard text.count >= 2, let first = text.first, let last = text.last else { return text }
        for (open, close) in pairs where first == open && last == close {
            let inner = text.dropFirst().dropLast()
            if !inner.contains(open), !inner.contains(close) {
                return String(inner).trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }
}
