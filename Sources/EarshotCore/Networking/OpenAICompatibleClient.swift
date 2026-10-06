import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Options for one `/v1/audio/transcriptions` call.
public struct TranscriptionOptions: Equatable, Sendable {
    /// Speech model, e.g. `whisper-large-v3-turbo`.
    public var model: String
    /// ISO 639-1 language hint; nil lets the model detect it.
    public var language: String?
    /// Optional text to condition the recognizer on (ignored by some servers).
    public var prompt: String?
    /// Value for the multipart `model` field when it must differ from `model`.
    ///
    /// MLX Studio's gateway routes a request to a loaded model session by the
    /// body's `model` field, while the vMLX engine behind it reads the speech
    /// model from the query string. When the gateway cannot place the speech
    /// model's name, sending the translation model's name here routes the
    /// request to that session, which then transcribes with `model`.
    public var routingModel: String?

    public init(model: String, language: String? = nil, prompt: String? = nil, routingModel: String? = nil) {
        self.model = model
        self.language = language
        self.prompt = prompt
        self.routingModel = routingModel
    }
}

/// Builds the HTTP requests. Kept separate from the client so tests can inspect them.
public enum RequestFactory {
    public static func models(at endpoint: ServerEndpoint, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint.url("models"), timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request, endpoint)
        return request
    }

    public static func transcription(wav: Data, options: TranscriptionOptions, at endpoint: ServerEndpoint, timeout: TimeInterval) -> URLRequest {
        // vMLX declares these as query parameters; OpenAI-style servers read the
        // form fields. Sending both works everywhere.
        var query = [URLQueryItem(name: "model", value: options.model)]
        if let language = options.language, !language.isEmpty {
            query.append(URLQueryItem(name: "language", value: language))
        }
        query.append(URLQueryItem(name: "response_format", value: "json"))

        var form = MultipartFormData()
        form.addField(name: "model", value: options.routingModel ?? options.model)
        if let language = options.language, !language.isEmpty {
            form.addField(name: "language", value: language)
        }
        form.addField(name: "response_format", value: "json")
        form.addField(name: "temperature", value: "0")
        if let prompt = options.prompt, !prompt.isEmpty {
            form.addField(name: "prompt", value: prompt)
        }
        form.addFile(name: "file", filename: "speech.wav", contentType: "audio/wav", data: wav)

        var request = URLRequest(url: endpoint.url("audio/transcriptions", query: query), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request, endpoint)
        request.httpBody = form.finalized()
        return request
    }

    static func chat(_ body: ChatCompletionBody, at endpoint: ServerEndpoint, timeout: TimeInterval) throws -> URLRequest {
        try json(path: "chat/completions", body: body, streaming: body.stream, at: endpoint, timeout: timeout)
    }

    static func completion(_ body: CompletionBody, at endpoint: ServerEndpoint, timeout: TimeInterval) throws -> URLRequest {
        try json(path: "completions", body: body, streaming: body.stream, at: endpoint, timeout: timeout)
    }

    private static func json<Body: Encodable>(path: String, body: Body, streaming: Bool, at endpoint: ServerEndpoint, timeout: TimeInterval) throws -> URLRequest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var request = URLRequest(url: endpoint.url(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        authorize(&request, endpoint)
        request.httpBody = try encoder.encode(body)
        return request
    }

    private static func authorize(_ request: inout URLRequest, _ endpoint: ServerEndpoint) {
        if let key = endpoint.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }
}

/// A small client for the parts of the OpenAI API that MLX Studio / vMLX,
/// LM Studio, `mlx_lm.server`, `mlx_audio.server` and friends all speak.
public final class OpenAICompatibleClient: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Model ids from `GET /v1/models`.
    public func listModels(at endpoint: ServerEndpoint, timeout: TimeInterval = 10) async throws -> [String] {
        let (data, response) = try await perform(RequestFactory.models(at: endpoint, timeout: timeout))
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.from(status: response.statusCode, body: data)
        }
        do {
            let list = try JSONDecoder().decode(ModelList.self, from: data)
            var seen = Set<String>()
            return (list.data ?? list.models ?? []).map(\.id).filter { seen.insert($0).inserted }
        } catch {
            throw APIError.decoding("could not read the model list")
        }
    }

    /// Sends a WAV file to `POST /v1/audio/transcriptions`.
    public func transcribe(wav: Data, options: TranscriptionOptions, at endpoint: ServerEndpoint, timeout: TimeInterval) async throws -> TranscriptionResult {
        let request = RequestFactory.transcription(wav: wav, options: options, at: endpoint, timeout: timeout)
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.from(status: response.statusCode, body: data)
        }
        return try TranscriptionResult.decode(data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
    }

    /// Streams generated text from `POST /v1/chat/completions`.
    public func streamChat(
        model: String,
        messages: [ChatMessage],
        temperature: Double?,
        maxTokens: Int?,
        stop: [String]? = nil,
        disableThinking: Bool,
        at endpoint: ServerEndpoint,
        timeout: TimeInterval
    ) -> AsyncThrowingStream<String, Error> {
        let body = ChatCompletionBody(
            model: model,
            messages: messages,
            stream: true,
            temperature: temperature,
            maxTokens: maxTokens,
            stop: stop,
            enableThinking: disableThinking ? false : nil,
            chatTemplateKwargs: disableThinking ? ["enable_thinking": false] : nil
        )
        return streamText(timeout: timeout) { try RequestFactory.chat(body, at: endpoint, timeout: timeout) }
    }

    /// Streams generated text from `POST /v1/completions` (raw prompt, no chat template).
    public func streamCompletion(
        model: String,
        prompt: String,
        temperature: Double?,
        maxTokens: Int?,
        stop: [String]? = nil,
        at endpoint: ServerEndpoint,
        timeout: TimeInterval
    ) -> AsyncThrowingStream<String, Error> {
        let body = CompletionBody(model: model, prompt: prompt, stream: true, temperature: temperature, maxTokens: maxTokens, stop: stop)
        return streamText(timeout: timeout) { try RequestFactory.completion(body, at: endpoint, timeout: timeout) }
    }

    // MARK: - Transport

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handle = TaskHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: APIError.from(transportError: error))
                    } else if let http = response as? HTTPURLResponse {
                        continuation.resume(returning: (data ?? Data(), http))
                    } else {
                        continuation.resume(throwing: APIError.transport("The server sent no HTTP response."))
                    }
                }
                if handle.adopt(task) {
                    task.resume()
                } else {
                    continuation.resume(throwing: APIError.cancelled)
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private func streamText(timeout: TimeInterval, makeRequest: () throws -> URLRequest) -> AsyncThrowingStream<String, Error> {
        let request: URLRequest
        do {
            request = try makeRequest()
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: APIError.transport("Could not encode the request: \(error)")) }
        }
        return AsyncThrowingStream { continuation in
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = max(timeout * 3, 900)
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            let delegate = StreamingDelegate(continuation: continuation)
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }
}

/// Lets `withTaskCancellationHandler` cancel a data task that may not exist yet.
private final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    /// Returns false if cancellation already happened; the task must then not be started.
    func adopt(_ task: URLSessionTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        self.task = task
        return true
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// Turns an OpenAI-style server-sent-event stream into text deltas.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var lines = LineBuffer()
    private var status = 200
    private var errorBody = Data()
    private var plainBody = Data()
    private var sawEvents = false
    private var finished = false

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 200
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard (200..<300).contains(status) else {
            errorBody.append(data)
            return
        }
        for line in lines.append(data) {
            handle(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        guard !finished else { return }
        if let error {
            finish(APIError.from(transportError: error))
            return
        }
        guard (200..<300).contains(status) else {
            finish(APIError.from(status: status, body: errorBody))
            return
        }
        for line in lines.finish() {
            handle(line)
        }
        if !finished, !sawEvents, !plainBody.isEmpty,
           let chunk = try? JSONDecoder().decode(CompletionChunk.self, from: plainBody) {
            // The server ignored `stream: true` and answered with a single JSON document.
            if let message = chunk.error?.message {
                finish(APIError.server(message))
                return
            }
            if let text = chunk.text, !text.isEmpty {
                continuation.yield(text)
            }
        }
        finish(nil)
    }

    private func handle(_ line: String) {
        guard !finished else { return }
        switch ServerSentEvents.parse(line) {
        case .done:
            sawEvents = true
            finish(nil)
        case .data(let payload):
            sawEvents = true
            guard let chunk = try? JSONDecoder().decode(CompletionChunk.self, from: Data(payload.utf8)) else { return }
            if let message = chunk.error?.message {
                finish(APIError.server(message))
            } else if let text = chunk.text, !text.isEmpty {
                continuation.yield(text)
            }
        case .other:
            if !sawEvents {
                plainBody.append(contentsOf: Array((line + "\n").utf8))
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
