import Foundation

/// Everything the pipeline reports, in order, on `TranslationPipeline.events`.
public enum PipelineEvent: Equatable, Sendable {
    /// The server answered and this translation model will be used.
    case ready(translationModel: String)
    /// Someone started (true) or stopped (false) talking.
    case speechActivity(Bool)
    /// The utterance in progress, or nil to clear it.
    case preview(LivePreview?)
    case entryAdded(TranscriptEntry)
    case entryUpdated(TranscriptEntry)
    /// The entry turned out to be silence or noise.
    case entryRemoved(UUID)
    /// Finished utterances waiting for the server.
    case backlog(Int)
    case issue(PipelineIssue)
    /// A stage that previously reported an issue works again.
    case issueResolved(PipelineIssue.Stage)
}

/// Mic audio in, translated transcript events out.
///
/// Audio is cut into utterances by `SpeechSegmenter`. Each finished utterance
/// is transcribed and then translated (streaming) strictly in order, so the
/// transcript never reshuffles. While someone is still speaking, the audio so
/// far is periodically transcribed (and optionally translated) as a live
/// preview — but only when no finished utterance is waiting, so previews never
/// slow the real thing down.
public actor TranslationPipeline {
    private enum Input: Sendable {
        case samples([Float])
        case endUtterance
    }

    private struct PendingUtterance {
        var segmentID: Int
        var samples: [Float]
        var startTime: TimeInterval
        var duration: TimeInterval
    }

    public nonisolated let events: AsyncStream<PipelineEvent>
    private nonisolated let eventContinuation: AsyncStream<PipelineEvent>.Continuation
    private nonisolated let inputContinuation: AsyncStream<Input>.Continuation
    private let inputStream: AsyncStream<Input>

    private var configuration: PipelineConfiguration
    private let backend: InferenceBackend
    private var segmenter: SpeechSegmenter
    private var inputTask: Task<Void, Never>?

    private var samplesSeen = 0
    private var speakingSegmentID: Int?
    private var pending: [PendingUtterance] = []
    private var isProcessing = false
    /// Recent turns for each target language, keyed by code, so one language's
    /// context never leaks into another's prompts.
    private var history: [String: [TranslationTurn]] = [:]
    private var failingStages = Set<PipelineIssue.Stage>()
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var previewSegmentID: Int?

    public init(configuration: PipelineConfiguration, backend: InferenceBackend = OpenAIBackend()) {
        self.configuration = configuration
        self.backend = backend
        self.segmenter = SpeechSegmenter(configuration: configuration.segmenter)
        (events, eventContinuation) = AsyncStream.makeStream(of: PipelineEvent.self)
        (inputStream, inputContinuation) = AsyncStream.makeStream(of: Input.self)
    }

    // MARK: - Feeding audio (safe from any thread)

    /// Queues mono samples at `configuration.segmenter.sampleRate`.
    public nonisolated func ingest(_ samples: [Float]) {
        inputContinuation.yield(.samples(samples))
    }

    /// Closes the utterance in progress once the audio queued before it has been processed.
    public nonisolated func endUtterance() {
        inputContinuation.yield(.endUtterance)
    }

    // MARK: - Control

    /// Starts consuming audio. Call once.
    public func start() {
        guard inputTask == nil else { return }
        let stream = inputStream
        inputTask = Task {
            for await input in stream {
                self.handle(input)
            }
        }
    }

    /// Checks the server and reports `.ready` or an issue.
    public func prepare() async {
        do {
            let model = try await backend.prepare(configuration: configuration)
            resolve(.connection)
            emit(.ready(translationModel: model))
        } catch {
            report(error, stage: .connection)
        }
    }

    public func update(configuration newConfiguration: PipelineConfiguration) async {
        guard newConfiguration != configuration else { return }
        let old = configuration
        configuration = newConfiguration
        segmenter.update(configuration: newConfiguration.segmenter)
        if newConfiguration.targetLanguages != old.targetLanguages || newConfiguration.sourceLanguage != old.sourceLanguage {
            history.removeAll()
        }
        if newConfiguration.livePreview == .off {
            cancelPreview()
            emit(.preview(nil))
        }
        if newConfiguration.changesServerSetup(from: old) {
            await backend.invalidate()
        }
    }

    /// Stops taking audio, finishes everything queued and closes `events`.
    public func finish() async {
        inputContinuation.finish()
        await inputTask?.value
        for event in segmenter.flush() {
            handle(event)
        }
        await waitUntilIdle()
        eventContinuation.finish()
    }

    /// Suspends until no utterance is queued or being processed.
    public func waitUntilIdle() async {
        guard isProcessing || !pending.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - Audio → utterances

    private func handle(_ input: Input) {
        switch input {
        case .samples(let samples):
            samplesSeen += samples.count
            for event in segmenter.process(samples) {
                handle(event)
            }
        case .endUtterance:
            for event in segmenter.flush() {
                handle(event)
            }
        }
    }

    private func handle(_ event: SegmenterEvent) {
        switch event {
        case .speechStarted(let id):
            if speakingSegmentID == nil {
                emit(.speechActivity(true))
            }
            speakingSegmentID = id
        case let .preview(id, samples):
            schedulePreview(segmentID: id, samples: samples)
        case let .segment(id, samples, reason):
            if reason != .maximumLength {
                speakingSegmentID = nil
                emit(.speechActivity(false))
            }
            if previewSegmentID == id {
                cancelPreview()
            }
            let rate = Double(configuration.segmenter.sampleRate)
            let duration = Double(samples.count) / rate
            var end = Double(samplesSeen) / rate
            if reason == .silence {
                end -= max(0, configuration.segmenter.endSilence - configuration.segmenter.trailingSilenceKept)
            }
            enqueue(PendingUtterance(segmentID: id, samples: samples, startTime: max(0, end - duration), duration: duration))
        case .discarded(let id):
            speakingSegmentID = nil
            emit(.speechActivity(false))
            if previewSegmentID == id {
                cancelPreview()
                previewSegmentID = nil
                emit(.preview(nil))
            }
        }
    }

    // MARK: - Finished utterances

    private func enqueue(_ utterance: PendingUtterance) {
        pending.append(utterance)
        processNextIfIdle()
    }

    private func processNextIfIdle() {
        guard !isProcessing else {
            emit(.backlog(pending.count))
            return
        }
        guard !pending.isEmpty else {
            emit(.backlog(0))
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return
        }
        isProcessing = true
        var batch = [pending.removeFirst()]
        if !pending.isEmpty {
            // Falling behind: merge what is waiting so the server catches up in one go.
            var total = batch[0].duration
            while let next = pending.first, total + next.duration <= configuration.backlogMergeLimit {
                batch.append(pending.removeFirst())
                total += next.duration
            }
        }
        emit(.backlog(pending.count))
        let configuration = self.configuration
        Task {
            await self.process(batch, configuration: configuration)
            self.isProcessing = false
            self.processNextIfIdle()
        }
    }

    private func process(_ batch: [PendingUtterance], configuration: PipelineConfiguration) async {
        guard let first = batch.first, let last = batch.last else { return }
        let rate = configuration.segmenter.sampleRate
        var samples: [Float] = []
        for (index, utterance) in batch.enumerated() {
            if index > 0 {
                samples.append(contentsOf: [Float](repeating: 0, count: rate / 5))
            }
            samples.append(contentsOf: utterance.samples)
        }

        var entry = TranscriptEntry(
            segmentID: first.segmentID,
            startTime: first.startTime,
            duration: max(first.duration, last.startTime + last.duration - first.startTime),
            sourceLanguage: configuration.sourceLanguage?.code,
            targetLanguages: configuration.targetLanguages.map(\.code)
        )
        emit(.entryAdded(entry))
        if let previewSegmentID, batch.contains(where: { $0.segmentID == previewSegmentID }) {
            self.previewSegmentID = nil
            emit(.preview(nil))
        }

        let result: TranscriptionResult
        do {
            result = try await backend.transcribe(samples, configuration: configuration)
            resolve(.transcription)
            resolve(.connection)
        } catch {
            report(error, stage: .transcription)
            emit(.entryRemoved(entry.id))
            return
        }

        let text = TextCleanup.cleanTranscript(result.text)
        guard !text.isEmpty else {
            emit(.entryRemoved(entry.id))
            return
        }
        let detected = result.language.flatMap(Languages.language(recognized:))
        let source = configuration.sourceLanguage ?? detected
        entry.sourceText = text
        entry.sourceLanguage = (detected ?? configuration.sourceLanguage)?.code ?? result.language
        entry.state = .translating
        emit(.entryUpdated(entry))
        // Targets in the language being spoken show what was heard, as-is.
        var passedThrough = false
        for target in configuration.targetLanguages where shouldPassThrough(source: source, target: target, configuration: configuration) {
            entry.translations[target.code] = text
            remember(TranslationTurn(source: text, translation: text), for: target, limit: configuration.contextTurns)
            passedThrough = true
        }
        let remaining = configuration.targetLanguages.filter { entry.translations[$0.code] == nil }
        // With nothing left to translate, the final update below shows the pass-through text.
        if passedThrough, !remaining.isEmpty {
            emit(.entryUpdated(entry))
        }

        // The rest one after another, in pinned order. A failure doesn't stop the others.
        var failure: String?
        var requestFailed = false
        for target in remaining {
            let request = TranslationRequest(
                text: text,
                source: source,
                target: target,
                history: context(for: target, limit: configuration.contextTurns)
            )
            var raw = ""
            do {
                let stream = await backend.translate(request, configuration: configuration)
                for try await delta in stream {
                    raw += delta
                    let visible = TextCleanup.cleanTranslation(raw)
                    if visible != entry.translation(target.code) {
                        entry.translations[target.code] = visible
                        emit(.entryUpdated(entry))
                    }
                }
            } catch {
                requestFailed = true
                let issue = PipelineIssue.from(error, stage: .translation, configuration: configuration)
                report(issue)
                entry.translations[target.code] = TextCleanup.cleanTranslation(raw)
                failure = failure ?? issue.message
                continue
            }
            let translation = TextCleanup.cleanTranslation(raw)
            entry.translations[target.code] = translation
            if translation.isEmpty {
                failure = failure ?? "The model returned an empty translation."
            } else {
                remember(TranslationTurn(source: text, translation: translation), for: target, limit: configuration.contextTurns)
            }
        }
        // Clear an earlier translation problem only once every request in this utterance worked.
        if !remaining.isEmpty, !requestFailed {
            resolve(.translation)
        }
        entry.state = failure.map { TranscriptEntry.State.failed($0) } ?? .done
        emit(.entryUpdated(entry))
    }

    private func shouldPassThrough(source: Language?, target: Language, configuration: PipelineConfiguration) -> Bool {
        guard configuration.skipSameLanguage, let source else { return false }
        return source.code == target.code
    }

    private func remember(_ turn: TranslationTurn, for target: Language, limit: Int) {
        guard limit > 0 else {
            history.removeAll()
            return
        }
        var turns = history[target.code] ?? []
        turns.append(turn)
        if turns.count > limit {
            turns.removeFirst(turns.count - limit)
        }
        history[target.code] = turns
    }

    private func context(for target: Language, limit: Int) -> [TranslationTurn] {
        Array((history[target.code] ?? []).suffix(limit))
    }

    // MARK: - Live preview

    private func schedulePreview(segmentID: Int, samples: [Float]) {
        let configuration = self.configuration
        guard configuration.livePreview != .off, previewTask == nil, !isProcessing, pending.isEmpty else { return }
        previewGeneration += 1
        let generation = previewGeneration
        previewSegmentID = segmentID
        previewTask = Task {
            await self.runPreview(segmentID: segmentID, samples: samples, configuration: configuration)
            if self.previewGeneration == generation {
                self.previewTask = nil
            }
        }
    }

    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewGeneration += 1
    }

    private func isPreviewCurrent(_ segmentID: Int) -> Bool {
        !Task.isCancelled && previewSegmentID == segmentID && speakingSegmentID == segmentID
    }

    private func runPreview(segmentID: Int, samples: [Float], configuration: PipelineConfiguration) async {
        do {
            let result = try await backend.transcribe(samples, configuration: configuration)
            guard isPreviewCurrent(segmentID) else { return }
            let text = TextCleanup.cleanTranscript(result.text)
            guard !text.isEmpty else { return }
            var preview = LivePreview(segmentID: segmentID, sourceText: text)
            emit(.preview(preview))
            guard configuration.livePreview == .originalAndTranslation else { return }
            let source = configuration.sourceLanguage ?? result.language.flatMap(Languages.language(recognized:))
            var passedThrough = false
            for target in configuration.targetLanguages where shouldPassThrough(source: source, target: target, configuration: configuration) {
                preview.translations[target.code] = text
                passedThrough = true
            }
            if passedThrough {
                emit(.preview(preview))
            }

            for target in configuration.targetLanguages where preview.translations[target.code] == nil {
                // A preview cancelled while translating into an earlier language must not start the next request.
                guard isPreviewCurrent(segmentID) else { return }
                let request = TranslationRequest(
                    text: text,
                    source: source,
                    target: target,
                    history: context(for: target, limit: configuration.contextTurns)
                )
                var raw = ""
                let stream = await backend.translate(request, configuration: configuration)
                for try await delta in stream {
                    guard isPreviewCurrent(segmentID) else { return }
                    raw += delta
                    let visible = TextCleanup.cleanTranslation(raw)
                    if visible != preview.translations[target.code] {
                        preview.translations[target.code] = visible
                        emit(.preview(preview))
                    }
                }
            }
        } catch {
            // Previews are best effort; the final pass reports real problems.
        }
    }

    // MARK: - Reporting

    private func emit(_ event: PipelineEvent) {
        eventContinuation.yield(event)
    }

    private func report(_ error: Error, stage: PipelineIssue.Stage) {
        report(PipelineIssue.from(error, stage: stage, configuration: configuration))
    }

    private func report(_ issue: PipelineIssue) {
        failingStages.insert(issue.stage)
        emit(.issue(issue))
    }

    private func resolve(_ stage: PipelineIssue.Stage) {
        guard failingStages.remove(stage) != nil else { return }
        emit(.issueResolved(stage))
    }
}
