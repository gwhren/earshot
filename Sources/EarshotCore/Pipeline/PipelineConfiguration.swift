import Foundation

/// What to show while someone is still talking.
public enum LivePreviewMode: String, CaseIterable, Sendable, Identifiable {
    case off
    /// Re-transcribe the utterance so far about once a second.
    case original
    /// …and translate each preview too (more GPU work, much livelier).
    case originalAndTranslation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .original: return "Original only"
        case .originalAndTranslation: return "Original and translation"
        }
    }
}

/// Everything the pipeline needs to know. Value type: the app rebuilds it from
/// its settings and hands the new copy over whenever something changes.
public struct PipelineConfiguration: Equatable, Sendable {
    /// Server for `/v1/audio/transcriptions`.
    public var speechEndpoint: ServerEndpoint
    /// Server for `/v1/chat/completions` and `/v1/completions`.
    public var translationEndpoint: ServerEndpoint
    /// Speech model name or alias (vMLX understands `whisper-large-v3-turbo`, `parakeet-v3`, …).
    public var speechModel: String
    /// Translation model id; empty means "the first chat model the server lists".
    public var translationModel: String
    public var promptStyle: PromptStyle
    /// Language being spoken; nil lets the speech model detect it.
    public var sourceLanguage: Language?
    /// Languages to translate into, in display order. `init` drops duplicates;
    /// there is always at least one.
    public var targetLanguages: [Language]
    /// How many earlier utterances chat models see for continuity.
    public var contextTurns: Int
    /// Extra instructions appended to the chat system prompt.
    public var instructions: String
    public var temperature: Double
    /// Ask hybrid reasoning models (Qwen3 and friends) not to think first.
    public var disableThinking: Bool
    public var livePreview: LivePreviewMode
    /// Show speech that is already in the target language as-is instead of "translating" it.
    public var skipSameLanguage: Bool
    public var segmenter: SegmenterConfiguration
    /// Per-request timeout. Generous because the first request may download a model.
    public var requestTimeout: TimeInterval
    /// When utterances queue up, merge up to this many seconds of them into one request.
    public var backlogMergeLimit: TimeInterval

    /// The mlx-audio conversion of Whisper large-v3 turbo. MLX Studio's own
    /// `whisper-large-v3-turbo` alias points at an older download without the
    /// tokenizer/processor files its speech engine needs.
    public static let defaultSpeechModel = "mlx-community/whisper-large-v3-turbo-asr-fp16"

    /// Speech model names that MLX Studio resolves to downloads its speech engine cannot use.
    public static let legacySpeechModels: Set<String> = [
        "whisper-large-v3-turbo", "whisper-large-v3", "whisper-medium", "whisper-small",
        "mlx-community/whisper-large-v3-turbo", "mlx-community/whisper-large-v3-mlx",
        "mlx-community/whisper-medium-mlx", "mlx-community/whisper-small-mlx",
    ]

    public init(
        targetLanguages: [Language],
        sourceLanguage: Language? = nil,
        speechEndpoint: ServerEndpoint = .mlxStudioGateway,
        translationEndpoint: ServerEndpoint? = nil,
        speechModel: String = PipelineConfiguration.defaultSpeechModel,
        translationModel: String = "",
        promptStyle: PromptStyle = .automatic,
        contextTurns: Int = 2,
        instructions: String = "",
        temperature: Double = 0.1,
        disableThinking: Bool = true,
        livePreview: LivePreviewMode = .originalAndTranslation,
        skipSameLanguage: Bool = true,
        segmenter: SegmenterConfiguration = SegmenterConfiguration(),
        requestTimeout: TimeInterval = 600,
        backlogMergeLimit: TimeInterval = 24
    ) {
        var seen = Set<String>()
        let unique = targetLanguages.filter { seen.insert($0.code).inserted }
        precondition(!unique.isEmpty, "PipelineConfiguration needs at least one target language")
        self.targetLanguages = unique
        self.sourceLanguage = sourceLanguage
        self.speechEndpoint = speechEndpoint
        self.translationEndpoint = translationEndpoint ?? speechEndpoint
        self.speechModel = speechModel
        self.translationModel = translationModel
        self.promptStyle = promptStyle
        self.contextTurns = contextTurns
        self.instructions = instructions
        self.temperature = temperature
        self.disableThinking = disableThinking
        self.livePreview = livePreview
        self.skipSameLanguage = skipSameLanguage
        self.segmenter = segmenter
        self.requestTimeout = requestTimeout
        self.backlogMergeLimit = backlogMergeLimit
    }

    /// True when changing from `other` to `self` invalidates cached server knowledge.
    func changesServerSetup(from other: PipelineConfiguration) -> Bool {
        speechEndpoint != other.speechEndpoint
            || translationEndpoint != other.translationEndpoint
            || speechModel != other.speechModel
            || translationModel != other.translationModel
    }
}
