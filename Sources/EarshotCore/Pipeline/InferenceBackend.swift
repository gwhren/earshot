import Foundation

/// A translation job handed to a backend.
public struct TranslationRequest: Equatable, Sendable {
    public var text: String
    public var source: Language?
    public var target: Language
    public var history: [TranslationTurn]

    public init(text: String, source: Language?, target: Language, history: [TranslationTurn] = []) {
        self.text = text
        self.source = source
        self.target = target
        self.history = history
    }
}

/// The model-facing half of the pipeline. `OpenAIBackend` is the real one;
/// tests swap in fakes.
public protocol InferenceBackend: Sendable {
    /// Checks the server and returns the translation model that will be used.
    func prepare(configuration: PipelineConfiguration) async throws -> String
    /// Mono samples at `configuration.segmenter.sampleRate` in, text out.
    func transcribe(_ samples: [Float], configuration: PipelineConfiguration) async throws -> TranscriptionResult
    /// Streams the translation as text deltas.
    func translate(_ request: TranslationRequest, configuration: PipelineConfiguration) async -> AsyncThrowingStream<String, Error>
    /// Forgets anything learned about the server (called when the setup changes).
    func invalidate() async
}

/// Talks to MLX Studio / vMLX (or any OpenAI-compatible server).
public actor OpenAIBackend: InferenceBackend {
    private let client: OpenAICompatibleClient
    private var resolvedModel: (key: String, model: String)?
    /// Learned when MLX Studio's gateway cannot route by the speech model's name.
    private var speechRoutingModel: String?
    /// Set when the server has no `/v1/completions`, so TranslateGemma goes through chat instead.
    private var completionsUnsupported = false

    public init(client: OpenAICompatibleClient = OpenAICompatibleClient()) {
        self.client = client
    }

    public func invalidate() {
        resolvedModel = nil
        speechRoutingModel = nil
        completionsUnsupported = false
    }

    public func prepare(configuration: PipelineConfiguration) async throws -> String {
        let models = try await client.listModels(at: configuration.translationEndpoint)
        let configured = configuration.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model: String
        if !configured.isEmpty {
            // Servers resolve aliases and partial names themselves, so trust the setting.
            model = configured
        } else if let pick = Self.pickTranslationModel(from: models) {
            model = pick
        } else {
            throw PipelineError.noModelLoaded
        }
        resolvedModel = (Self.cacheKey(configuration), model)
        return model
    }

    public func transcribe(_ samples: [Float], configuration: PipelineConfiguration) async throws -> TranscriptionResult {
        let wav = WAVFile.encodePCM16(samples, sampleRate: configuration.segmenter.sampleRate)
        var options = TranscriptionOptions(
            model: configuration.speechModel,
            language: configuration.sourceLanguage?.whisperCode,
            routingModel: speechRoutingModel
        )
        do {
            return try await client.transcribe(wav: wav, options: options, at: configuration.speechEndpoint, timeout: configuration.requestTimeout)
        } catch let error as APIError where error.isModelNotFound && options.routingModel == nil {
            // MLX Studio's gateway picks a model session by the request's `model`
            // field and has no session called "whisper-…". Route the request to the
            // translation model's session; its engine loads Whisper on demand.
            let routeVia = try await translationModel(for: configuration)
            guard routeVia != configuration.speechModel else { throw error }
            options.routingModel = routeVia
            let result = try await client.transcribe(wav: wav, options: options, at: configuration.speechEndpoint, timeout: configuration.requestTimeout)
            speechRoutingModel = routeVia
            return result
        }
    }

    public func translate(_ request: TranslationRequest, configuration: PipelineConfiguration) async -> AsyncThrowingStream<String, Error> {
        let model: String
        do {
            model = try await translationModel(for: configuration)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let endpoint = configuration.translationEndpoint
        let timeout = configuration.requestTimeout
        let maxTokens = PromptBuilder.maxTokens(forSource: request.text)
        let client = self.client

        switch configuration.promptStyle.resolved(forModel: model) {
        case .translateGemma:
            let structuredChat: @Sendable () -> AsyncThrowingStream<String, Error> = {
                client.streamChat(
                    model: model,
                    messages: PromptBuilder.translateGemmaMessages(text: request.text, source: request.source, target: request.target),
                    temperature: 0,
                    maxTokens: maxTokens,
                    disableThinking: false,
                    at: endpoint,
                    timeout: timeout
                )
            }
            if completionsUnsupported {
                return structuredChat()
            }
            let completion = client.streamCompletion(
                model: model,
                prompt: PromptBuilder.translateGemmaPrompt(text: request.text, source: request.source, target: request.target),
                temperature: 0,
                maxTokens: maxTokens,
                stop: PromptBuilder.translateGemmaStops,
                at: endpoint,
                timeout: timeout
            )
            return withFallback(primary: completion, fallback: structuredChat)
        case .chat, .automatic:
            return client.streamChat(
                model: model,
                messages: PromptBuilder.chatMessages(
                    text: request.text,
                    source: request.source,
                    target: request.target,
                    history: request.history,
                    instructions: configuration.instructions
                ),
                temperature: configuration.temperature,
                maxTokens: maxTokens,
                disableThinking: configuration.disableThinking,
                at: endpoint,
                timeout: timeout
            )
        }
    }

    // MARK: - Helpers

    private func translationModel(for configuration: PipelineConfiguration) async throws -> String {
        let configured = configuration.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        if let resolvedModel, resolvedModel.key == Self.cacheKey(configuration) {
            return resolvedModel.model
        }
        return try await prepare(configuration: configuration)
    }

    private func markCompletionsUnsupported() {
        completionsUnsupported = true
    }

    /// Runs `primary`; if it fails before producing anything because the endpoint
    /// does not exist, switches to `fallback` and remembers that choice.
    private func withFallback(
        primary: AsyncThrowingStream<String, Error>,
        fallback: @escaping @Sendable () -> AsyncThrowingStream<String, Error>
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var produced = false
                do {
                    do {
                        for try await delta in primary {
                            produced = true
                            continuation.yield(delta)
                        }
                    } catch let error as APIError where !produced && Self.isMissingEndpoint(error) {
                        self.markCompletionsUnsupported()
                        for try await delta in fallback() {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func isMissingEndpoint(_ error: APIError) -> Bool {
        guard case let .http(status, _, _) = error, !error.isModelNotFound else { return false }
        return status == 404 || status == 405 || status == 501
    }

    /// Picks something that looks like a text model from `/v1/models`.
    public static func pickTranslationModel(from models: [String]) -> String? {
        let nonText = ["whisper", "parakeet", "kokoro", "tts", "embed", "rerank", "flux", "diffusion", "sdxl", "z-image", "e5-", "bge-"]
        let textModels = models.filter { name in
            let lowered = name.lowercased()
            return !nonText.contains { lowered.contains($0) }
        }
        // Prefer a dedicated translation model if one is loaded.
        return textModels.first { $0.lowercased().contains("translategemma") } ?? textModels.first
    }

    private static func cacheKey(_ configuration: PipelineConfiguration) -> String {
        configuration.translationEndpoint.baseURL.absoluteString
    }
}
