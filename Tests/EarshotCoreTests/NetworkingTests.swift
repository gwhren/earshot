import XCTest
@testable import EarshotCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class NetworkingTests: XCTestCase {
    // MARK: Endpoints

    func testEndpointNormalisation() throws {
        let cases: [(String, String)] = [
            ("http://127.0.0.1:8080", "http://127.0.0.1:8080"),
            ("127.0.0.1:8080", "http://127.0.0.1:8080"),
            ("http://localhost:8000/v1", "http://localhost:8000"),
            ("http://localhost:8000/v1/", "http://localhost:8000"),
            ("  https://studio.local/V1  ", "https://studio.local"),
            ("http://box:9000/proxy/v1", "http://box:9000/proxy"),
        ]
        for (input, expected) in cases {
            let endpoint = try XCTUnwrap(ServerEndpoint(string: input), input)
            XCTAssertEqual(endpoint.baseURL.absoluteString, expected, input)
        }
        XCTAssertNil(ServerEndpoint(string: ""))
        XCTAssertNil(ServerEndpoint(string: "ftp://example.com"))
        XCTAssertNil(ServerEndpoint(string: "http://"))

        let endpoint = try XCTUnwrap(ServerEndpoint(string: "http://box:9000/proxy/", apiKey: "  "))
        XCTAssertNil(endpoint.apiKey)
        XCTAssertEqual(endpoint.url("models").absoluteString, "http://box:9000/proxy/v1/models")
        XCTAssertEqual(endpoint.displayName, "box:9000")
        XCTAssertEqual(ServerEndpoint.mlxStudioGateway.url("/chat/completions").absoluteString, "http://127.0.0.1:8080/v1/chat/completions")
    }

    // MARK: Line splitting and SSE

    func testLineBufferHandlesSplitsAndMultibyteCharacters() {
        var buffer = LineBuffer()
        let text = "data: {\"a\":\"é漢\"}\r\n\ndata: [DONE]\n"
        let bytes = Array(text.utf8)
        var lines: [String] = []
        for byte in bytes {
            lines += buffer.append(Data([byte]))
        }
        lines += buffer.finish()
        XCTAssertEqual(lines, ["data: {\"a\":\"é漢\"}", "", "data: [DONE]"])

        var tail = LineBuffer()
        XCTAssertEqual(tail.append(Data("partial".utf8)), [])
        XCTAssertEqual(tail.finish(), ["partial"])
        XCTAssertEqual(tail.finish(), [])
    }

    func testServerSentEventParsing() {
        XCTAssertEqual(ServerSentEvents.parse("data: {\"x\":1}"), .data("{\"x\":1}"))
        XCTAssertEqual(ServerSentEvents.parse("data:{\"x\":1}"), .data("{\"x\":1}"))
        XCTAssertEqual(ServerSentEvents.parse("data: [DONE]"), .done)
        XCTAssertEqual(ServerSentEvents.parse(": keep-alive"), .other)
        XCTAssertEqual(ServerSentEvents.parse("event: message"), .other)
        XCTAssertEqual(ServerSentEvents.parse("data: "), .other)
    }

    func testCompletionChunkDecoding() throws {
        func text(_ json: String) throws -> String? {
            try JSONDecoder().decode(CompletionChunk.self, from: Data(json.utf8)).text
        }
        XCTAssertEqual(try text(#"{"choices":[{"delta":{"content":"Bon"}}]}"#), "Bon")
        XCTAssertEqual(try text(#"{"choices":[{"delta":{"role":"assistant","content":null}}]}"#), nil)
        XCTAssertEqual(try text(#"{"choices":[{"text":"jour","index":0}]}"#), "jour")
        XCTAssertEqual(try text(#"{"choices":[{"message":{"content":"Salut"}}]}"#), "Salut")
        XCTAssertEqual(try text(#"{"choices":[]}"#), nil)

        let objectError = try JSONDecoder().decode(CompletionChunk.self, from: Data(#"{"error":{"message":"boom"}}"#.utf8))
        XCTAssertEqual(objectError.error?.message, "boom")
        let stringError = try JSONDecoder().decode(CompletionChunk.self, from: Data(#"{"error":"nope"}"#.utf8))
        XCTAssertEqual(stringError.error?.message, "nope")
    }

    // MARK: Multipart

    func testMultipartLayout() {
        var form = MultipartFormData(boundary: "XYZ")
        form.addField(name: "model", value: "whisper-large-v3-turbo")
        form.addFile(name: "file", filename: "speech.wav", contentType: "audio/wav", data: Data([0, 1, 2, 255]))
        let body = form.finalized()
        var expected = Data("--XYZ\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n".utf8)
        expected.append(Data("--XYZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        expected.append(Data([0, 1, 2, 255]))
        expected.append(Data("\r\n--XYZ--\r\n".utf8))
        XCTAssertEqual(body, expected)
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=XYZ")
    }

    // MARK: Requests

    func testTranscriptionRequestSendsModelInQueryAndForm() throws {
        let endpoint = try XCTUnwrap(ServerEndpoint(string: "http://127.0.0.1:8080", apiKey: "secret"))
        let wav = WAVFile.encodePCM16([0, 0.1, -0.1], sampleRate: 16_000)
        let options = TranscriptionOptions(model: "whisper-large-v3-turbo", language: "es", routingModel: "translategemma-12b-it-4bit")
        let request = RequestFactory.transcription(wav: wav, options: options, at: endpoint, timeout: 30)

        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/v1/audio/transcriptions")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["model"], "whisper-large-v3-turbo")
        XCTAssertEqual(query["language"], "es")
        XCTAssertEqual(query["response_format"], "json")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        // The form's model field routes through MLX Studio's gateway…
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\ntranslategemma-12b-it-4bit\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nes\r\n"))
        XCTAssertTrue(body.contains("filename=\"speech.wav\""))
        XCTAssertTrue(body.hasSuffix("--\r\n"))
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    func testTranscriptionRequestWithoutLanguage() throws {
        let options = TranscriptionOptions(model: "parakeet-v3")
        let request = RequestFactory.transcription(wav: Data(), options: options, at: .mlxStudioGateway, timeout: 5)
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertFalse(url.contains("language="))
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nparakeet-v3\r\n"))
        XCTAssertFalse(body.contains("name=\"language\""))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testChatRequestBody() throws {
        let body = ChatCompletionBody(
            model: "qwen3-8b",
            messages: [.system("be brief"), .user("hola")],
            stream: true,
            temperature: 0.1,
            maxTokens: 64,
            stop: nil,
            enableThinking: false,
            chatTemplateKwargs: ["enable_thinking": false]
        )
        let request = try RequestFactory.chat(body, at: .mlxStudioGateway, timeout: 60)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8080/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "qwen3-8b")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 64)
        XCTAssertEqual(json["enable_thinking"] as? Bool, false)
        XCTAssertEqual((json["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
        XCTAssertNil(json["stop"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages.last?["content"] as? String, "hola")
    }

    func testStructuredContentEncodesParts() throws {
        let message = PromptBuilder.translateGemmaMessages(text: "Hallo", source: Languages.language(code: "de"), target: Languages.english)[0]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        let parts = try XCTUnwrap(json["content"] as? [[String: String]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0]["type"], "text")
        XCTAssertEqual(parts[0]["source_lang_code"], "de")
        XCTAssertEqual(parts[0]["target_lang_code"], "en")
        XCTAssertEqual(parts[0]["text"], "Hallo")
        XCTAssertEqual(message.text, "Hallo")
    }

    // MARK: Responses and errors

    func testTranscriptionResultDecoding() throws {
        let json = try TranscriptionResult.decode(Data(#"{"text":" Hola ","language":"es","duration":2.5}"#.utf8), contentType: "application/json")
        XCTAssertEqual(json, TranscriptionResult(text: " Hola ", language: "es", duration: 2.5))
        let plain = try TranscriptionResult.decode(Data("Bonjour".utf8), contentType: "text/plain; charset=utf-8")
        XCTAssertEqual(plain.text, "Bonjour")
        let emptyLanguage = try TranscriptionResult.decode(Data(#"{"text":"x","language":""}"#.utf8), contentType: nil)
        XCTAssertNil(emptyLanguage.language)
        XCTAssertThrowsError(try TranscriptionResult.decode(Data(#"{"detail":"x"}"#.utf8), contentType: "application/json"))
    }

    func testErrorBodyParsing() {
        func parse(_ json: String) -> (String, String?) {
            let result = APIError.parseErrorBody(Data(json.utf8))
            return (result.message, result.code)
        }
        XCTAssertEqual(parse(#"{"error":{"message":"Model 'x' not found","code":"model_not_found"}}"#).0, "Model 'x' not found")
        XCTAssertEqual(parse(#"{"error":{"message":"m","code":"model_not_found"}}"#).1, "model_not_found")
        XCTAssertEqual(parse(#"{"detail":"mlx-audio not installed"}"#).0, "mlx-audio not installed")
        XCTAssertEqual(parse(#"{"detail":[{"msg":"field required"},{"msg":"bad"}]}"#).0, "field required; bad")
        XCTAssertEqual(parse(#"{"error":"No running models"}"#).0, "No running models")
        XCTAssertEqual(parse("Internal Server Error").0, "Internal Server Error")
    }

    func testErrorClassification() {
        XCTAssertTrue(APIError.http(status: 404, message: "Model 'whisper' not found. Available: [a]", code: "model_not_found").isModelNotFound)
        XCTAssertTrue(APIError.http(status: 404, message: "The model does not exist", code: nil).isModelNotFound)
        XCTAssertFalse(APIError.http(status: 404, message: "Not Found", code: nil).isModelNotFound)
        XCTAssertFalse(APIError.http(status: 500, message: "boom", code: nil).isModelNotFound)
        XCTAssertTrue(OpenAIBackend.isMissingEndpoint(.http(status: 404, message: "Not Found", code: nil)))
        XCTAssertTrue(OpenAIBackend.isMissingEndpoint(.http(status: 405, message: "Method Not Allowed", code: nil)))
        XCTAssertFalse(OpenAIBackend.isMissingEndpoint(.http(status: 404, message: "m", code: "model_not_found")))
        XCTAssertFalse(OpenAIBackend.isMissingEndpoint(.unreachable("x")))

        XCTAssertEqual(APIError.from(transportError: URLError(.cannotConnectToHost)), .unreachable(URLError(.cannotConnectToHost).localizedDescription))
        XCTAssertEqual(APIError.from(transportError: URLError(.timedOut)), .timedOut)
        XCTAssertEqual(APIError.from(transportError: URLError(.cancelled)), .cancelled)
        XCTAssertEqual(APIError.from(transportError: CancellationError()), .cancelled)
    }

    func testModelPicking() {
        XCTAssertEqual(OpenAIBackend.pickTranslationModel(from: ["whisper-large-v3-turbo", "Qwen3-8B-4bit"]), "Qwen3-8B-4bit")
        XCTAssertEqual(OpenAIBackend.pickTranslationModel(from: ["Qwen3-8B-4bit", "translategemma-12b-it-4bit"]), "translategemma-12b-it-4bit")
        XCTAssertEqual(OpenAIBackend.pickTranslationModel(from: ["kokoro", "bge-m3"]), nil)
        XCTAssertEqual(OpenAIBackend.pickTranslationModel(from: []), nil)
    }
}
