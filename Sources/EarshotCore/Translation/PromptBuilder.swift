import Foundation

/// How translation requests are phrased for the model.
public enum PromptStyle: String, CaseIterable, Sendable, Identifiable {
    /// Pick from the model name: TranslateGemma gets its native prompt, everything else chat.
    case automatic
    /// A system prompt plus the text as a user message. Works with any instruction-tuned model.
    case chat
    /// TranslateGemma's own prompt, sent to `/v1/completions` so no chat template gets in the way.
    case translateGemma

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .chat: return "Chat (any instruction model)"
        case .translateGemma: return "TranslateGemma"
        }
    }

    public func resolved(forModel model: String) -> PromptStyle {
        guard self == .automatic else { return self }
        return model.lowercased().contains("translategemma") ? .translateGemma : .chat
    }
}

/// An earlier utterance and its translation, given to chat models for continuity.
public struct TranslationTurn: Equatable, Sendable {
    public var source: String
    public var translation: String

    public init(source: String, translation: String) {
        self.source = source
        self.translation = translation
    }
}

public enum PromptBuilder {
    /// Tokens that end a TranslateGemma answer when the raw completion endpoint is used.
    public static let translateGemmaStops = ["<end_of_turn>", "<eos>"]

    public static func systemPrompt(source: Language?, target: Language, instructions: String = "") -> String {
        let targetName = target.promptName
        let speech = source.map { " of \($0.promptName) speech" } ?? ""
        var lines = [
            "You are a simultaneous interpreter. Translate every message you receive into \(targetName).",
            "Messages are live speech-recognition transcripts\(speech): they may be fragments, lack punctuation or contain misheard words, so translate what the speaker meant.",
            "Reply with the \(targetName) translation only: no quotes, notes, explanations, alternatives or romanization.",
            "Keep names, numbers and technical terms accurate and keep the speaker's tone.",
            "If a message is already in \(targetName), repeat it unchanged.",
        ]
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            lines.append(extra)
        }
        return lines.joined(separator: "\n")
    }

    /// Chat messages for a general instruction model, with recent turns as context.
    public static func chatMessages(
        text: String,
        source: Language?,
        target: Language,
        history: [TranslationTurn] = [],
        instructions: String = ""
    ) -> [ChatMessage] {
        var messages = [ChatMessage.system(systemPrompt(source: source, target: target, instructions: instructions))]
        for turn in history where !turn.source.isEmpty && !turn.translation.isEmpty {
            messages.append(.user(turn.source))
            messages.append(.assistant(turn.translation))
        }
        messages.append(.user(text))
        return messages
    }

    /// The instruction TranslateGemma was trained on.
    public static func translateGemmaInstruction(text: String, source: Language?, target: Language) -> String {
        let targetName = target.promptName
        let targetCode = target.translateGemmaCode
        guard let source else {
            return "You are a professional translator into \(targetName) (\(targetCode)). "
                + "Your goal is to accurately convey the meaning and nuances of the original text while adhering to \(targetName) grammar, vocabulary, and cultural sensitivities.\n"
                + "Produce only the \(targetName) translation, without any additional explanations or commentary. "
                + "Please translate the following text into \(targetName):\n\n\n\(text)"
        }
        let sourceName = source.promptName
        let sourceCode = source.translateGemmaCode
        return "You are a professional \(sourceName) (\(sourceCode)) to \(targetName) (\(targetCode)) translator. "
            + "Your goal is to accurately convey the meaning and nuances of the original \(sourceName) text while adhering to \(targetName) grammar, vocabulary, and cultural sensitivities.\n"
            + "Produce only the \(targetName) translation, without any additional explanations or commentary. "
            + "Please translate the following \(sourceName) text into \(targetName):\n\n\n\(text)"
    }

    /// A complete Gemma turn for `/v1/completions`. The server adds `<bos>` itself.
    public static func translateGemmaPrompt(text: String, source: Language?, target: Language) -> String {
        "<start_of_turn>user\n\(translateGemmaInstruction(text: text, source: source, target: target))<end_of_turn>\n<start_of_turn>model\n"
    }

    /// TranslateGemma's structured chat message, for servers that pass content parts through to its template.
    public static func translateGemmaMessages(text: String, source: Language?, target: Language) -> [ChatMessage] {
        let part: [String: String] = [
            "type": "text",
            "source_lang_code": (source ?? Languages.english).translateGemmaCode,
            "target_lang_code": target.translateGemmaCode,
            "text": text,
        ]
        return [ChatMessage(role: "user", content: .parts([part]))]
    }

    /// A generous output budget: translations rarely need more than twice the source length in tokens.
    public static func maxTokens(forSource text: String) -> Int {
        min(1024, max(64, text.count * 2 + 32))
    }
}
