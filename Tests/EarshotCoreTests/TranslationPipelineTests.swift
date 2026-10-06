import XCTest
@testable import EarshotCore

final class TranslationPipelineTests: XCTestCase {
    func testUtteranceIsTranscribedThenTranslated() async throws {
        let backend = FakeBackend(transcripts: ["Hola, ¿qué tal?"], language: "es")
        let events = await runPipeline(Synth.silence(1) + Synth.tone(1.5) + Synth.silence(1.5), backend: backend)

        let entries = events.finalEntries
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, .done)
        XCTAssertEqual(entry.sourceText, "Hola, ¿qué tal?")
        XCTAssertEqual(entry.sourceLanguage, "es")
        XCTAssertEqual(entry.translations, ["en": "[en] Hola, ¿qué tal?"])
        XCTAssertEqual(entry.targetLanguages, ["en"])
        XCTAssertEqual(entry.startTime, 0.76, accuracy: 0.1)
        XCTAssertEqual(entry.duration, 2.0, accuracy: 0.1)

        // Speech activity brackets the utterance and the translation streamed in pieces.
        XCTAssertEqual(events.first, .speechActivity(true))
        XCTAssertTrue(events.contains(.speechActivity(false)))
        let updates = events.compactMap { event -> String? in
            if case .entryUpdated(let entry) = event { return entry.translation("en") }
            return nil
        }
        XCTAssertEqual(updates.first, "")
        XCTAssertTrue(updates.contains("[en]"))
        let transcribed = await backend.transcribeSampleCounts
        XCTAssertEqual(transcribed.count, 1)
    }

    func testNoiseTranscriptsAreRemoved() async {
        let backend = FakeBackend(transcripts: ["Thank you for watching!"])
        let events = await runPipeline(Synth.silence(1) + Synth.tone(1) + Synth.silence(1.5), backend: backend)
        XCTAssertTrue(events.finalEntries.isEmpty)
        XCTAssertTrue(events.contains { if case .entryRemoved = $0 { return true } else { return false } })
        let translated = await backend.translatedTexts
        XCTAssertTrue(translated.isEmpty)
    }

    func testSpeechAlreadyInTheTargetLanguagePassesThrough() async {
        let backend = FakeBackend(transcripts: ["Good morning"], language: "en")
        let events = await runPipeline(Synth.silence(1) + Synth.tone(1) + Synth.silence(1.5), backend: backend)
        XCTAssertEqual(events.finalEntries.map(\.primaryTranslation), ["Good morning"])
        XCTAssertEqual(events.finalEntries.first?.state, .done)
        let translated = await backend.translatedTexts
        XCTAssertTrue(translated.isEmpty)
    }

    func testPassThroughCanBeTurnedOff() async {
        let backend = FakeBackend(transcripts: ["Good morning"], language: "en")
        let events = await runPipeline(Synth.silence(1) + Synth.tone(1) + Synth.silence(1.5), backend: backend) {
            $0.skipSameLanguage = false
        }
        XCTAssertEqual(events.finalEntries.map(\.primaryTranslation), ["[en] Good morning"])
    }

    func testUtterancesStayInOrderAndBacklogIsMerged() async {
        let backend = FakeBackend(transcripts: ["uno", "dos", "tres"], transcribeDelayNanoseconds: 200_000_000)
        var audio = Synth.silence(1)
        for _ in 0..<4 {
            audio += Synth.tone(0.6) + Synth.silence(1.2)
        }
        let events = await runPipeline(audio, backend: backend)

        let calls = await backend.transcribeSampleCounts
        XCTAssertEqual(calls.count, 2, "the three utterances queued behind the first should be merged into one request")
        XCTAssertEqual(events.finalEntries.map(\.sourceText), ["uno", "dos"])
        let starts = events.finalEntries.map(\.startTime)
        XCTAssertEqual(starts, starts.sorted())
        XCTAssertTrue(events.contains(.backlog(3)))
        XCTAssertEqual(events.last { if case .backlog = $0 { return true } else { return false } }, .backlog(0))
    }

    func testContextFromEarlierUtterancesIsPassedAlong() async {
        actor RecordingBackend: InferenceBackend {
            var histories: [[TranslationTurn]] = []
            var count = 0
            func prepare(configuration: PipelineConfiguration) async throws -> String { "m" }
            func transcribe(_ samples: [Float], configuration: PipelineConfiguration) async throws -> TranscriptionResult {
                count += 1
                return TranscriptionResult(text: "frase \(count)", language: "es")
            }
            func translate(_ request: TranslationRequest, configuration: PipelineConfiguration) async -> AsyncThrowingStream<String, Error> {
                histories.append(request.history)
                let reply = "sentence \(histories.count)"
                return AsyncThrowingStream { $0.yield(reply); $0.finish() }
            }
            func invalidate() async {}
        }
        let backend = RecordingBackend()
        var audio: [Float] = []
        for _ in 0..<3 {
            audio += Synth.silence(0.5) + Synth.tone(0.8) + Synth.silence(1.2)
        }
        _ = await runPipeline(audio, backend: backend) {
            $0.contextTurns = 1
            $0.backlogMergeLimit = 0
        }
        let histories = await backend.histories
        XCTAssertEqual(histories.count, 3)
        XCTAssertEqual(histories.first, [])
        XCTAssertEqual(histories.dropFirst().first, [TranslationTurn(source: "frase 1", translation: "sentence 1")])
        XCTAssertEqual(histories.last, [TranslationTurn(source: "frase 2", translation: "sentence 2")])
    }

    func testFailuresAreReportedAndRecoveryIsAnnounced() async {
        let backend = FakeBackend(transcripts: ["segunda"], failures: 1)
        let audio = Synth.silence(1) + Synth.tone(0.8) + Synth.silence(1.5) + Synth.tone(0.8) + Synth.silence(1.5)
        let events = await runPipeline(audio, backend: backend, pacing: 5_000_000)

        XCTAssertEqual(events.issues.map(\.kind), [.serverUnreachable])
        XCTAssertEqual(events.issues.first?.stage, .transcription)
        XCTAssertTrue(events.contains(.issueResolved(.transcription)))
        XCTAssertEqual(events.finalEntries.map(\.sourceText), ["segunda"])
    }

    func testLivePreviewShowsTheUtteranceInProgress() async {
        let backend = FakeBackend(language: "es")
        let audio = Synth.silence(1) + Synth.tone(3.5) + Synth.silence(1.5)
        let events = await runPipeline(audio, backend: backend, configure: { $0.livePreview = .originalAndTranslation }, pacing: 8_000_000)

        let previews = events.previews
        XCTAssertFalse(previews.isEmpty)
        XCTAssertTrue(previews.contains { $0.translations["en"] == "[en] hola" })
        XCTAssertTrue(previews.allSatisfy { $0.segmentID == 1 })
        // The preview is cleared once the real entry takes over.
        let lastPreviewEvent = events.last { if case .preview = $0 { return true } else { return false } }
        XCTAssertEqual(lastPreviewEvent, .preview(nil))
        XCTAssertEqual(events.finalEntries.count, 1)
        XCTAssertEqual(events.finalEntries.first?.segmentID, 1)
    }

    func testPrepareReportsTheModel() async {
        let pipeline = TranslationPipeline(configuration: PipelineConfiguration(targetLanguages: [Languages.english]), backend: FakeBackend())
        let collector = Task { () -> [PipelineEvent] in
            var events: [PipelineEvent] = []
            for await event in pipeline.events { events.append(event) }
            return events
        }
        await pipeline.start()
        await pipeline.prepare()
        await pipeline.finish()
        let events = await collector.value
        XCTAssertEqual(events.first, .ready(translationModel: "fake-model"))
    }

    func testIssueMessagesAreHelpful() {
        let configuration = PipelineConfiguration(targetLanguages: [Languages.english], translationModel: "qwen3")
        let unreachable = PipelineIssue.from(APIError.unreachable("refused"), stage: .connection, configuration: configuration)
        XCTAssertEqual(unreachable.kind, .serverUnreachable)
        XCTAssertTrue(unreachable.message.contains("127.0.0.1:8080"))

        let audio = PipelineIssue.from(APIError.http(status: 503, message: "mlx-audio not installed. Install with: pip install mlx-audio", code: nil), stage: .transcription, configuration: configuration)
        XCTAssertEqual(audio.kind, .speechUnavailable)

        let missing = PipelineIssue.from(APIError.http(status: 404, message: "Model 'qwen3' not found", code: "model_not_found"), stage: .translation, configuration: configuration)
        XCTAssertEqual(missing.kind, .modelNotFound)
        XCTAssertTrue(missing.message.contains("“qwen3”"))

        let none = PipelineIssue.from(PipelineError.noModelLoaded, stage: .connection, configuration: configuration)
        XCTAssertEqual(none.kind, .noModelLoaded)

        let vision = PipelineIssue.from(
            APIError.http(status: 503, message: "Process exited before becoming ready: TypeError: VisionConfig.__init__() missing 6 required positional arguments", code: "model_load_failed"),
            stage: .translation,
            configuration: configuration
        )
        XCTAssertEqual(vision.kind, .modelLoadFailed)
        XCTAssertTrue(vision.message.contains("Force Off"))
        XCTAssertTrue(APIError.server("bad vision_config").isVisionLoaderFailure)

        let processor = PipelineIssue.from(
            APIError.http(status: 500, message: "Processor not found. Make sure the model was loaded with a HuggingFace processor.", code: nil),
            stage: .transcription,
            configuration: configuration
        )
        XCTAssertEqual(processor.kind, .speechModelIncompatible)
        XCTAssertTrue(processor.message.contains(PipelineConfiguration.defaultSpeechModel))
        XCTAssertTrue(PipelineConfiguration.legacySpeechModels.contains("whisper-large-v3-turbo"))
        XCTAssertFalse(PipelineConfiguration.legacySpeechModels.contains(PipelineConfiguration.defaultSpeechModel))
        XCTAssertFalse(APIError.unreachable("x").isVisionLoaderFailure)
    }

    // MARK: - Several target languages

    func testTargetLanguagesAreDeduplicated() {
        let configuration = PipelineConfiguration(targetLanguages: [Languages.english, Languages.ukrainian, Languages.english])
        XCTAssertEqual(configuration.targetLanguages.map(\.code), ["en", "uk"])
    }

    func testSpeechInOnePinnedLanguageIsTranslatedOnlyIntoTheOther() async {
        let backend = FakeBackend(transcripts: ["Good morning"], language: "en")
        let events = await runPipeline(Synth.silence(1) + Synth.tone(1) + Synth.silence(1.5), backend: backend) {
            $0.targetLanguages = [Languages.english, Languages.ukrainian]
        }
        let entry = events.finalEntries.first
        XCTAssertEqual(entry?.translations, ["en": "Good morning", "uk": "[uk] Good morning"])
        XCTAssertEqual(entry?.targetLanguages, ["en", "uk"])
        XCTAssertEqual(entry?.state, .done)
        let targets = await backend.translatedTargets
        XCTAssertEqual(targets, ["uk"], "English speech should only need the Ukrainian translation")
    }

    func testSpeechInAnotherLanguageIsTranslatedIntoBothInOrder() async {
        let backend = FakeBackend(transcripts: ["Доброе утро"], language: "ru")
        let events = await runPipeline(Synth.silence(1) + Synth.tone(1) + Synth.silence(1.5), backend: backend) {
            $0.targetLanguages = [Languages.english, Languages.ukrainian]
        }
        XCTAssertEqual(events.finalEntries.first?.translations, ["en": "[en] Доброе утро", "uk": "[uk] Доброе утро"])
        let targets = await backend.translatedTargets
        XCTAssertEqual(targets, ["en", "uk"])
    }

    func testContextIsKeptPerTargetLanguage() async {
        let backend = TargetRecordingBackend()
        var audio: [Float] = []
        for _ in 0..<2 {
            audio += Synth.silence(0.5) + Synth.tone(0.8) + Synth.silence(1.2)
        }
        _ = await runPipeline(audio, backend: backend) {
            $0.targetLanguages = [Languages.english, Languages.ukrainian]
            $0.contextTurns = 2
            $0.backlogMergeLimit = 0
        }
        let requests = await backend.requests
        XCTAssertEqual(requests, [
            TargetRecordingBackend.Request(target: "en", history: []),
            TargetRecordingBackend.Request(target: "uk", history: []),
            TargetRecordingBackend.Request(target: "en", history: [TranslationTurn(source: "frase 1", translation: "en 1")]),
            TargetRecordingBackend.Request(target: "uk", history: [TranslationTurn(source: "frase 1", translation: "uk 2")]),
        ])
    }

    func testChangingTheTargetsStartsTheContextOver() async throws {
        let backend = TargetRecordingBackend()
        var configuration = PipelineConfiguration(targetLanguages: [Languages.english], livePreview: .off)
        configuration.backlogMergeLimit = 0
        let pipeline = TranslationPipeline(configuration: configuration, backend: backend)
        let drain = Task { for await _ in pipeline.events {} }
        await pipeline.start()

        pipeline.ingest(Synth.silence(0.5) + Synth.tone(0.8) + Synth.silence(1.2))
        var waited = 0
        while await backend.requests.isEmpty, waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        await pipeline.waitUntilIdle()

        configuration.targetLanguages = [Languages.english, Languages.ukrainian]
        await pipeline.update(configuration: configuration)
        pipeline.ingest(Synth.silence(0.5) + Synth.tone(0.8) + Synth.silence(1.2))
        await pipeline.finish()
        await drain.value

        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.target), ["en", "en", "uk"])
        XCTAssertEqual(requests.dropFirst().first?.history, [], "changing the targets should start the context over")
    }

    func testAFailedTranslationKeepsTheOthers() async {
        let backend = FakeBackend(transcripts: ["Hola"], language: "es", failingTargets: ["uk"])
        let events = await runPipeline(Synth.silence(1) + Synth.tone(1) + Synth.silence(1.5), backend: backend) {
            $0.targetLanguages = [Languages.english, Languages.ukrainian]
        }
        let entry = events.finalEntries.first
        XCTAssertEqual(entry?.translation("en"), "[en] Hola")
        XCTAssertEqual(entry?.translation("uk"), "")
        if case .failed? = entry?.state {} else {
            XCTFail("expected a failed entry, got \(String(describing: entry?.state))")
        }
        XCTAssertEqual(events.issues.map(\.stage), [.translation])
    }

    func testLivePreviewFillsEveryLanguage() async {
        let backend = FakeBackend(language: "es")
        let audio = Synth.silence(1) + Synth.tone(3.5) + Synth.silence(1.5)
        let events = await runPipeline(audio, backend: backend, configure: {
            $0.livePreview = .originalAndTranslation
            $0.targetLanguages = [Languages.english, Languages.ukrainian]
        }, pacing: 8_000_000)
        XCTAssertTrue(events.previews.contains { $0.translations == ["en": "[en] hola", "uk": "[uk] hola"] })
    }

    func testACancelledPreviewStopsBeforeTheNextLanguage() async throws {
        let backend = HangingPreviewBackend()
        let audio = Synth.silence(1) + Synth.tone(3.5) + Synth.silence(1.5)
        _ = await runPipeline(audio, backend: backend, configure: {
            $0.livePreview = .originalAndTranslation
            $0.targetLanguages = [Languages.english, Languages.ukrainian]
        }, pacing: 8_000_000)
        // Give a wrongly continuing preview the chance to send its next request.
        try await Task.sleep(nanoseconds: 200_000_000)
        let requests = await backend.requests
        XCTAssertEqual(requests.first, HangingPreviewBackend.Request(text: "preview", target: "en"))
        XCTAssertFalse(
            requests.contains(HangingPreviewBackend.Request(text: "preview", target: "uk")),
            "a cancelled preview must not request the next language"
        )
        XCTAssertTrue(requests.contains(HangingPreviewBackend.Request(text: "final", target: "uk")))
    }

    func testOneTargetPassThroughEmitsTheSameUpdatesAsBefore() async {
        let backend = FakeBackend(transcripts: ["Good morning"], language: "en")
        let events = await runPipeline(Synth.silence(1) + Synth.tone(1) + Synth.silence(1.5), backend: backend)
        let updates = events.compactMap { event -> TranscriptEntry? in
            if case .entryUpdated(let entry) = event { return entry }
            return nil
        }
        XCTAssertEqual(updates.map(\.state), [.translating, .done])
        XCTAssertEqual(updates.map { $0.translation("en") }, ["", "Good morning"])
    }

    func testOneTargetPassThroughPreviewShowsTheOriginalFirst() async {
        let backend = FakeBackend(language: "en")
        let audio = Synth.silence(1) + Synth.tone(3.5) + Synth.silence(1.5)
        let events = await runPipeline(audio, backend: backend, configure: { $0.livePreview = .originalAndTranslation }, pacing: 8_000_000)
        let previews = events.previews
        XCTAssertEqual(previews.first?.translations, [:], "the source-only preview comes first, as before")
        XCTAssertTrue(previews.contains { $0.translations == ["en": "hola"] })
    }

    func testAFailedLanguageKeepsTheProblemReportedWhenAnotherSucceeds() async {
        let backend = FakeBackend(transcripts: ["Hola"], language: "es", failingTargets: ["en"])
        let events = await runPipeline(Synth.silence(1) + Synth.tone(1) + Synth.silence(1.5), backend: backend) {
            $0.targetLanguages = [Languages.english, Languages.ukrainian]
        }
        XCTAssertEqual(events.issues.map(\.stage), [.translation])
        XCTAssertFalse(events.contains(.issueResolved(.translation)), "the Ukrainian success must not clear the English failure")
        XCTAssertEqual(events.finalEntries.first?.translation("uk"), "[uk] Hola")
    }
}

/// Answers every translation with "<code> <n>" and records what each request carried.
private actor TargetRecordingBackend: InferenceBackend {
    struct Request: Equatable {
        var target: String
        var history: [TranslationTurn]
    }

    private(set) var requests: [Request] = []
    private var transcribed = 0

    func prepare(configuration: PipelineConfiguration) async throws -> String { "m" }

    func transcribe(_ samples: [Float], configuration: PipelineConfiguration) async throws -> TranscriptionResult {
        transcribed += 1
        return TranscriptionResult(text: "frase \(transcribed)", language: "es")
    }

    func translate(_ request: TranslationRequest, configuration: PipelineConfiguration) async -> AsyncThrowingStream<String, Error> {
        requests.append(Request(target: request.target.code, history: request.history))
        let reply = "\(request.target.code) \(requests.count)"
        return AsyncThrowingStream { $0.yield(reply); $0.finish() }
    }

    func invalidate() async {}
}

/// Hangs the live preview's translation until the preview is cancelled, so a test can see
/// whether a cancelled preview goes on to request the next language.
private actor HangingPreviewBackend: InferenceBackend {
    struct Request: Equatable {
        var text: String
        var target: String
    }

    private(set) var requests: [Request] = []
    private var transcribed = 0

    func prepare(configuration: PipelineConfiguration) async throws -> String { "m" }

    func transcribe(_ samples: [Float], configuration: PipelineConfiguration) async throws -> TranscriptionResult {
        transcribed += 1
        // The first transcription is the live preview; the final pass comes once the speech ends.
        return TranscriptionResult(text: transcribed == 1 ? "preview" : "final", language: "es")
    }

    func translate(_ request: TranslationRequest, configuration: PipelineConfiguration) async -> AsyncThrowingStream<String, Error> {
        requests.append(Request(text: request.text, target: request.target.code))
        if request.text == "preview" {
            // Never finishes by itself: only the preview's cancellation ends it.
            return AsyncThrowingStream { $0.yield("[\(request.target.code)] preview") }
        }
        let reply = "[\(request.target.code)] \(request.text)"
        return AsyncThrowingStream { $0.yield(reply); $0.finish() }
    }

    func invalidate() async {}
}
