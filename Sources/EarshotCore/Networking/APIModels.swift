import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors surfaced by `OpenAICompatibleClient`.
public enum APIError: Error, Equatable, LocalizedError, Sendable {
    /// The server answered with a non-2xx status.
    case http(status: Int, message: String, code: String?)
    /// Nothing is listening at the endpoint (connection refused, host not found…).
    case unreachable(String)
    /// The request timed out.
    case timedOut
    /// Any other transport problem.
    case transport(String)
    /// The response could not be understood.
    case decoding(String)
    /// The server reported an error inside an otherwise successful stream.
    case server(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .http(status, message, _):
            return message.isEmpty ? "The server returned HTTP \(status)." : "HTTP \(status): \(message)"
        case .unreachable(let detail): return "Could not connect to the server (\(detail))."
        case .timedOut: return "The server took too long to answer."
        case .transport(let detail): return detail
        case .decoding(let detail): return "Unexpected response from the server: \(detail)"
        case .server(let message): return message
        case .cancelled: return "Cancelled."
        }
    }

    /// The server does not know the requested model (MLX Studio's gateway answers 404 `model_not_found`).
    public var isModelNotFound: Bool {
        guard case let .http(status, message, code) = self else { return false }
        if code == "model_not_found" { return true }
        return status == 404 && message.lowercased().contains("model")
    }

    /// MLX Studio routed a model to its vision (mlx-vlm) loader, which crashed on an
    /// incomplete `vision_config` — typical for text-only TranslateGemma downloads.
    public var isVisionLoaderFailure: Bool {
        let text: String
        switch self {
        case let .http(_, message, _): text = message
        case let .server(message): text = message
        default: return false
        }
        return text.contains("VisionConfig") || text.contains("vision_config")
    }

    public var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }

    static func from(status: Int, body: Data) -> APIError {
        let (message, code) = parseErrorBody(body)
        return .http(status: status, message: message, code: code)
    }

    static func from(transportError error: Error) -> APIError {
        if let apiError = error as? APIError { return apiError }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
                return .unreachable(urlError.localizedDescription)
            default:
                return .transport(urlError.localizedDescription)
            }
        }
        if error is CancellationError { return .cancelled }
        return .transport(error.localizedDescription)
    }

    /// Pulls a readable message out of OpenAI, FastAPI or gateway style error bodies.
    static func parseErrorBody(_ data: Data) -> (message: String, code: String?) {
        let fallback = String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else {
            return (fallback, nil)
        }
        var message: String?
        var code: String?
        if let error = dictionary["error"] as? [String: Any] {
            message = error["message"] as? String
            code = (error["code"] as? String) ?? (error["type"] as? String)
        } else if let error = dictionary["error"] as? String {
            message = error
        }
        if let detail = dictionary["detail"] as? String {
            message = detail
        } else if let details = dictionary["detail"] as? [[String: Any]] {
            message = details.compactMap { $0["msg"] as? String }.joined(separator: "; ")
        }
        if message == nil, let text = dictionary["message"] as? String {
            message = text
        }
        return (message ?? fallback, code)
    }
}

/// A chat message whose content is either plain text or a list of typed parts
/// (TranslateGemma's template wants `source_lang_code`/`target_lang_code` on its part).
public struct ChatMessage: Equatable, Sendable, Encodable {
    public enum Content: Equatable, Sendable {
        case text(String)
        case parts([[String: String]])
    }

    public var role: String
    public var content: Content

    public init(role: String, content: Content) {
        self.role = role
        self.content = content
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", content: .text(text)) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: .text(text)) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: "assistant", content: .text(text)) }

    /// The text content, joined if the message uses parts.
    public var text: String {
        switch content {
        case .text(let text): return text
        case .parts(let parts): return parts.compactMap { $0["text"] }.joined(separator: "\n")
        }
    }

    private enum CodingKeys: String, CodingKey { case role, content }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        switch content {
        case .text(let text): try container.encode(text, forKey: .content)
        case .parts(let parts): try container.encode(parts, forKey: .content)
        }
    }
}

struct ChatCompletionBody: Encodable {
    var model: String
    var messages: [ChatMessage]
    var stream: Bool
    var temperature: Double?
    var maxTokens: Int?
    var stop: [String]?
    var enableThinking: Bool?
    var chatTemplateKwargs: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, stop
        case maxTokens = "max_tokens"
        case enableThinking = "enable_thinking"
        case chatTemplateKwargs = "chat_template_kwargs"
    }
}

struct CompletionBody: Encodable {
    var model: String
    var prompt: String
    var stream: Bool
    var temperature: Double?
    var maxTokens: Int?
    var stop: [String]?

    enum CodingKeys: String, CodingKey {
        case model, prompt, stream, temperature, stop
        case maxTokens = "max_tokens"
    }
}

/// One streamed chunk from `/v1/chat/completions` or `/v1/completions`
/// (also used for the equivalent non-streamed response).
struct CompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let delta: Message?
        let message: Message?
        let text: String?
    }

    let choices: [Choice]?
    let error: ErrorPayload?

    /// The generated text in this chunk, if any.
    var text: String? {
        guard let choice = choices?.first else { return nil }
        return choice.delta?.content ?? choice.message?.content ?? choice.text
    }
}

/// `error` may be a string or an object with a `message`.
struct ErrorPayload: Decodable {
    let message: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            message = text
            return
        }
        struct Object: Decodable { let message: String? }
        let object = try container.decode(Object.self)
        message = object.message ?? "Unknown server error"
    }
}

struct ModelList: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]?
    let models: [Model]?
}

/// What a transcription endpoint returned.
public struct TranscriptionResult: Equatable, Sendable {
    public var text: String
    /// Language the model detected (usually an ISO 639-1 code such as "en").
    public var language: String?
    public var duration: Double?

    public init(text: String, language: String? = nil, duration: Double? = nil) {
        self.text = text
        self.language = language
        self.duration = duration
    }

    static func decode(_ data: Data, contentType: String?) throws -> TranscriptionResult {
        let isJSON = contentType?.lowercased().contains("json") ?? true
        if isJSON || data.first == UInt8(ascii: "{") {
            if let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] {
                guard let text = dictionary["text"] as? String else {
                    throw APIError.decoding("transcription response has no \"text\" field")
                }
                let language = (dictionary["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let duration = (dictionary["duration"] as? Double) ?? (dictionary["duration"] as? NSNumber)?.doubleValue
                return TranscriptionResult(text: text, language: language, duration: duration)
            }
            if isJSON, contentType != nil {
                throw APIError.decoding(String(decoding: data.prefix(200), as: UTF8.self))
            }
        }
        // `response_format=text` servers just send the words.
        return TranscriptionResult(text: String(decoding: data, as: UTF8.self))
    }
}
