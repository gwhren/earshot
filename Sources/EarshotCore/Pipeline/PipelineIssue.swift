import Foundation

/// A problem worth telling the user about, phrased for humans.
public struct PipelineIssue: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case connection
        case transcription
        case translation
    }

    public enum Kind: Equatable, Sendable {
        case serverUnreachable
        case noModelLoaded
        case modelNotFound
        case speechUnavailable
        case speechModelIncompatible
        case modelLoadFailed
        case timeout
        case other
    }

    public var stage: Stage
    public var kind: Kind
    public var message: String

    public init(stage: Stage, kind: Kind, message: String) {
        self.stage = stage
        self.kind = kind
        self.message = message
    }

    public static func from(_ error: Error, stage: Stage, configuration: PipelineConfiguration) -> PipelineIssue {
        let endpoint = stage == .transcription ? configuration.speechEndpoint : configuration.translationEndpoint
        if let pipelineError = error as? PipelineError {
            switch pipelineError {
            case .noModelLoaded:
                return PipelineIssue(
                    stage: stage,
                    kind: .noModelLoaded,
                    message: "No model is loaded on \(endpoint.displayName). Load a translation model in MLX Studio (for example TranslateGemma 12B), then try again."
                )
            }
        }
        guard let apiError = error as? APIError else {
            return PipelineIssue(stage: stage, kind: .other, message: error.localizedDescription)
        }
        if apiError.isVisionLoaderFailure {
            return PipelineIssue(
                stage: stage,
                kind: .modelLoadFailed,
                message: "MLX Studio tried to load the model as a vision model and failed. For TranslateGemma (and other Gemma 3 models) open the session's settings in MLX Studio, set Multimodal Support (VLM) to Force Off, and restart it."
            )
        }
        switch apiError {
        case .unreachable:
            return PipelineIssue(
                stage: stage,
                kind: .serverUnreachable,
                message: "Can't reach \(endpoint.displayName). Is MLX Studio running with a model loaded? Its API gateway listens on port 8080; a plain `vmlx serve` uses 8000."
            )
        case .timedOut:
            return PipelineIssue(
                stage: stage,
                kind: .timeout,
                message: "\(endpoint.displayName) took too long to answer. The very first request can take minutes while the model downloads."
            )
        case let .http(status, message, _):
            let lowered = message.lowercased()
            if stage == .transcription, lowered.contains("processor not found") {
                return PipelineIssue(
                    stage: stage,
                    kind: .speechModelIncompatible,
                    message: "MLX Studio's speech engine can't use the “\(configuration.speechModel)” download (it has no tokenizer files). In Settings → Models set the speech model to \(PipelineConfiguration.defaultSpeechModel)."
                )
            }
            if stage == .transcription, status == 503 || lowered.contains("mlx-audio") || lowered.contains("mlx_audio") {
                return PipelineIssue(
                    stage: stage,
                    kind: .speechUnavailable,
                    message: "\(endpoint.displayName) can't transcribe speech (mlx-audio is missing). MLX Studio ships with it; for vMLX run `pip install 'vmlx[audio]'`."
                )
            }
            if apiError.isModelNotFound {
                let name = stage == .transcription ? configuration.speechModel : configuration.translationModel
                return PipelineIssue(
                    stage: stage,
                    kind: .modelNotFound,
                    message: stage == .transcription
                        ? "\(endpoint.displayName) could not route the speech request. Load a model in MLX Studio, or point the speech server at one that serves Whisper."
                        : "\(endpoint.displayName) has no model named “\(name)”. Pick one of the loaded models in Settings → Models."
                )
            }
            let what = stage == .transcription ? "Transcription" : (stage == .translation ? "Translation" : "Request")
            return PipelineIssue(stage: stage, kind: .other, message: "\(what) failed (HTTP \(status)): \(message)")
        case .cancelled:
            return PipelineIssue(stage: stage, kind: .other, message: "Cancelled.")
        default:
            return PipelineIssue(stage: stage, kind: .other, message: apiError.localizedDescription)
        }
    }
}

public enum PipelineError: Error, Equatable, LocalizedError {
    case noModelLoaded

    public var errorDescription: String? {
        switch self {
        case .noModelLoaded: return "The server has no models loaded."
        }
    }
}
