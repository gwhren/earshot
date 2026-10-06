import Foundation
@testable import EarshotCore

/// Deterministic synthetic audio at 16 kHz.
enum Synth {
    static let rate = 16_000

    /// Near-silence: faint noise around -70 dBFS, like a quiet room.
    static func silence(_ seconds: Double) -> [Float] {
        noise(seconds, amplitude: 0.0005, seed: 7)
    }

    /// A steady tone; amplitude 0.3 is roughly -13.5 dBFS RMS, i.e. clear speech level.
    static func tone(_ seconds: Double, amplitude: Float = 0.3, frequency: Double = 220) -> [Float] {
        let count = Int(seconds * Double(rate))
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / Double(rate)))
        }
    }

    static func noise(_ seconds: Double, amplitude: Float, seed: UInt64) -> [Float] {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        let count = Int(seconds * Double(rate))
        return (0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let unit = Float(state >> 40) / Float(1 << 24)
            return amplitude * (unit * 2 - 1)
        }
    }

    /// Continuous "speech" with a short quiet dip every `dipEvery` seconds — no pause long enough to end an utterance.
    static func monologue(_ seconds: Double, dipEvery: Double = 1.7, dipLength: Double = 0.1) -> [Float] {
        var samples = tone(seconds)
        let period = Int(dipEvery * Double(rate))
        let dip = Int(dipLength * Double(rate))
        var start = period
        while start + dip < samples.count {
            for index in start..<(start + dip) {
                samples[index] *= 0.003
            }
            start += period
        }
        return samples
    }
}

extension Array where Element == SegmenterEvent {
    var segments: [(id: Int, samples: [Float], reason: SegmentEndReason)] {
        compactMap { event in
            if case let .segment(id, samples, reason) = event { return (id, samples, reason) }
            return nil
        }
    }

    var starts: [Int] {
        compactMap { event in
            if case let .speechStarted(id) = event { return id }
            return nil
        }
    }

    var previewCount: Int {
        filter { event in
            if case .preview = event { return true }
            return false
        }.count
    }

    var discardedIDs: [Int] {
        compactMap { event in
            if case let .discarded(id) = event { return id }
            return nil
        }
    }
}

/// A scripted stand-in for the MLX Studio server.
actor FakeBackend: InferenceBackend {
    var transcripts: [String]
    var language: String?
    var transcribeDelayNanoseconds: UInt64
    var failuresRemaining: Int
    /// Translations into these language codes fail.
    var failingTargets: Set<String>
    private(set) var transcribeSampleCounts: [Int] = []
    private(set) var translatedTexts: [String] = []
    /// The target language code of every translation request, in order.
    private(set) var translatedTargets: [String] = []

    init(
        transcripts: [String] = [],
        language: String? = "es",
        transcribeDelayNanoseconds: UInt64 = 0,
        failures: Int = 0,
        failingTargets: Set<String> = []
    ) {
        self.transcripts = transcripts
        self.language = language
        self.transcribeDelayNanoseconds = transcribeDelayNanoseconds
        self.failuresRemaining = failures
        self.failingTargets = failingTargets
    }

    func prepare(configuration: PipelineConfiguration) async throws -> String {
        "fake-model"
    }

    func transcribe(_ samples: [Float], configuration: PipelineConfiguration) async throws -> TranscriptionResult {
        transcribeSampleCounts.append(samples.count)
        if transcribeDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: transcribeDelayNanoseconds)
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw APIError.unreachable("test")
        }
        let text = transcripts.isEmpty ? "hola" : transcripts.removeFirst()
        return TranscriptionResult(text: text, language: language)
    }

    func translate(_ request: TranslationRequest, configuration: PipelineConfiguration) async -> AsyncThrowingStream<String, Error> {
        translatedTexts.append(request.text)
        translatedTargets.append(request.target.code)
        if failingTargets.contains(request.target.code) {
            return AsyncThrowingStream { $0.finish(throwing: APIError.unreachable("test")) }
        }
        let deltas = ["[", request.target.code, "] ", request.text]
        return AsyncThrowingStream { continuation in
            for delta in deltas {
                continuation.yield(delta)
            }
            continuation.finish()
        }
    }

    func invalidate() async {}
}

extension Languages {
    static let ukrainian = language(code: "uk")!
}

/// Runs audio through a pipeline and returns every event it produced.
func runPipeline(
    _ audio: [Float],
    backend: InferenceBackend,
    configure: (inout PipelineConfiguration) -> Void = { _ in },
    pacing: UInt64 = 0
) async -> [PipelineEvent] {
    var configuration = PipelineConfiguration(targetLanguages: [Languages.english], livePreview: .off)
    configure(&configuration)
    let pipeline = TranslationPipeline(configuration: configuration, backend: backend)
    let collector = Task { () -> [PipelineEvent] in
        var events: [PipelineEvent] = []
        for await event in pipeline.events {
            events.append(event)
        }
        return events
    }
    await pipeline.start()
    let chunk = 1_600
    var offset = 0
    while offset < audio.count {
        let end = min(offset + chunk, audio.count)
        pipeline.ingest(Array(audio[offset..<end]))
        offset = end
        if pacing > 0 {
            try? await Task.sleep(nanoseconds: pacing)
        }
    }
    await pipeline.finish()
    return await collector.value
}

extension Array where Element == PipelineEvent {
    /// The last state of every entry that was not removed, in order of creation.
    var finalEntries: [TranscriptEntry] {
        var order: [UUID] = []
        var latest: [UUID: TranscriptEntry] = [:]
        var removed = Set<UUID>()
        for event in self {
            switch event {
            case .entryAdded(let entry):
                order.append(entry.id)
                latest[entry.id] = entry
            case .entryUpdated(let entry):
                latest[entry.id] = entry
            case .entryRemoved(let id):
                removed.insert(id)
            default:
                break
            }
        }
        return order.filter { !removed.contains($0) }.compactMap { latest[$0] }
    }

    var previews: [LivePreview] {
        compactMap { event in
            if case .preview(let preview?) = event { return preview }
            return nil
        }
    }

    var issues: [PipelineIssue] {
        compactMap { event in
            if case .issue(let issue) = event { return issue }
            return nil
        }
    }
}
