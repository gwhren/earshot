import Foundation

/// Tuning knobs for `SpeechSegmenter`. Durations are in seconds, levels in dBFS.
public struct SegmenterConfiguration: Equatable, Sendable {
    /// Sample rate of the audio handed to `process(_:)`.
    public var sampleRate: Int = 16_000
    /// Length of one analysis frame.
    public var frameDuration: Double = 0.02
    /// How far above the tracked noise floor a frame must be to count as speech.
    public var onsetMargin: Float = 9
    /// Nothing quieter than this is ever treated as speech.
    public var minimumSpeechLevel: Float = -55
    /// Once an utterance is running, frames stay "voiced" down to this many dB below the onset threshold.
    public var releaseHysteresis: Float = 3
    /// Consecutive loud audio needed before an utterance starts.
    public var onsetDuration: Double = 0.06
    /// Quiet needed before an utterance is considered finished.
    public var endSilence: Double = 0.7
    /// Trailing quiet kept at the end of a finished utterance (Whisper likes a little padding).
    public var trailingSilenceKept: Double = 0.25
    /// Audio kept from just before the onset so first syllables are not clipped.
    public var preRoll: Double = 0.3
    /// Utterances with less voiced audio than this are dropped as clicks and bumps.
    public var minimumSpeech: Double = 0.25
    /// Long stretches of speech are cut into chunks no longer than this.
    public var maximumSegment: Double = 12
    /// How far back to look for a quiet spot when a chunk has to be cut.
    public var cutSearchWindow: Double = 2
    /// How often an utterance in progress is offered for a live preview (0 disables previews).
    public var previewInterval: Double = 1.0
    /// Minimum utterance length before the first preview.
    public var minimumPreview: Double = 0.8
    /// Window used to estimate the background noise level.
    public var noiseWindow: Double = 5
    /// Percentile of recent frame levels treated as the noise floor.
    public var noisePercentile: Double = 0.15
    /// Skip voice detection and cut the audio into fixed `maximumSegment` chunks instead.
    public var continuous: Bool = false

    public init() {}

    /// Maps a 0...1 "sensitivity" slider onto the onset margin and absolute speech floor.
    public mutating func applySensitivity(_ sensitivity: Double) {
        let s = Float(min(max(sensitivity, 0), 1))
        onsetMargin = 15 - 10 * s          // 15 dB (strict) ... 5 dB (eager)
        minimumSpeechLevel = -45 - 17 * s  // -45 dBFS ... -62 dBFS
    }
}

/// Why a chunk of audio was closed off.
public enum SegmentEndReason: String, Equatable, Sendable {
    /// The speaker paused.
    case silence
    /// The utterance ran past `maximumSegment` and was cut at the quietest nearby point.
    case maximumLength
    /// `flush()` was called (for example when listening stops).
    case flush
}

public enum SegmenterEvent: Equatable, Sendable {
    /// An utterance (or the continuation of a long one) began.
    case speechStarted(id: Int)
    /// Audio of the utterance so far, for a live preview.
    case preview(id: Int, samples: [Float])
    /// A finished chunk that should be transcribed.
    case segment(id: Int, samples: [Float], reason: SegmentEndReason)
    /// The utterance was too short to be speech and was dropped.
    case discarded(id: Int)
}

/// Energy-based voice activity detection that turns a continuous stream of
/// mono samples into utterance-sized chunks.
///
/// The noise floor is a low percentile of the recent frame levels, so it
/// follows the room (a fan, a busy café) without ever needing calibration.
/// A frame is speech when it is `onsetMargin` dB above that floor. Utterances
/// end after `endSilence` of quiet; monologues are cut at the quietest frame
/// near `maximumSegment` so words are not chopped in half.
public struct SpeechSegmenter {
    public private(set) var configuration: SegmenterConfiguration
    public private(set) var isSpeaking = false
    /// Identifier of the current (or most recent) utterance. Increases monotonically.
    public private(set) var currentID = 0
    public private(set) var noiseFloor: Float = -70
    public private(set) var lastFrameLevel: Float = -100

    private var frameLength = 320
    private var onsetFrames = 3
    private var endSilenceFrames = 35
    private var trailingKeptFrames = 12
    private var preRollFrames = 15
    private var minimumSpeechFrames = 12
    private var maximumSegmentFrames = 600
    private var cutSearchFrames = 100
    private var previewIntervalFrames = 50
    private var minimumPreviewFrames = 40
    private var historyCapacity = 250
    private let minimumHistory = 25

    private var pending: [Float] = []
    private var levelHistory: [Float] = []
    private var historyIndex = 0
    private var framesSinceFloorUpdate = 0

    private var preRollSamples: [Float] = []
    private var preRollLevels: [Float] = []
    private var onsetRun = 0

    private var segment: [Float] = []
    private var segmentLevels: [Float] = []
    private var voicedFrames = 0
    private var silentRun = 0
    private var framesSincePreview = 0

    public init(configuration: SegmenterConfiguration = SegmenterConfiguration()) {
        self.configuration = configuration
        recomputeFrameCounts()
    }

    /// The level a frame must reach to count as speech right now.
    public var speechThreshold: Float {
        max(noiseFloor + configuration.onsetMargin, configuration.minimumSpeechLevel)
    }

    /// Seconds of audio in the utterance currently being collected.
    public var currentSegmentDuration: Double {
        Double(segment.count) / Double(configuration.sampleRate)
    }

    /// Changes tuning without losing the noise estimate or the utterance in progress.
    public mutating func update(configuration newConfiguration: SegmenterConfiguration) {
        let sampleRateChanged = newConfiguration.sampleRate != configuration.sampleRate
            || newConfiguration.frameDuration != configuration.frameDuration
        let modeChanged = newConfiguration.continuous != configuration.continuous
        configuration = newConfiguration
        recomputeFrameCounts()
        if sampleRateChanged || modeChanged {
            reset()
        }
    }

    /// Drops all state (including the utterance in progress) but keeps the id counter.
    public mutating func reset() {
        pending.removeAll()
        levelHistory.removeAll()
        historyIndex = 0
        framesSinceFloorUpdate = 0
        noiseFloor = -70
        preRollSamples.removeAll()
        preRollLevels.removeAll()
        onsetRun = 0
        clearSegment()
    }

    /// Feeds samples (any chunk size) and returns what happened.
    public mutating func process(_ samples: [Float]) -> [SegmenterEvent] {
        var events: [SegmenterEvent] = []
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= frameLength {
            let frame = Array(pending[offset..<(offset + frameLength)])
            offset += frameLength
            processFrame(frame, events: &events)
        }
        if offset > 0 {
            pending.removeFirst(offset)
        }
        return events
    }

    /// Closes the utterance in progress, if any.
    public mutating func flush() -> [SegmenterEvent] {
        var events: [SegmenterEvent] = []
        if isSpeaking {
            segment.append(contentsOf: pending)
            finishSegment(reason: .flush, events: &events)
        }
        pending.removeAll()
        preRollSamples.removeAll()
        preRollLevels.removeAll()
        onsetRun = 0
        return events
    }

    // MARK: - Frame handling

    private mutating func processFrame(_ frame: [Float], events: inout [SegmenterEvent]) {
        let level = AudioLevel.decibels(fromRMS: AudioLevel.rms(frame))
        lastFrameLevel = level
        recordLevel(level)

        if configuration.continuous {
            processContinuousFrame(frame, level: level, events: &events)
            return
        }

        let threshold = speechThreshold
        guard isSpeaking else {
            appendPreRoll(frame, level: level)
            onsetRun = level >= threshold ? onsetRun + 1 : 0
            if onsetRun >= onsetFrames {
                beginSegment(voicedFrames: onsetRun, events: &events)
            }
            return
        }

        segment.append(contentsOf: frame)
        segmentLevels.append(level)
        if level >= threshold - configuration.releaseHysteresis {
            silentRun = 0
            voicedFrames += 1
        } else {
            silentRun += 1
        }

        if silentRun >= endSilenceFrames {
            finishSegment(reason: .silence, events: &events)
        } else if segmentLevels.count >= maximumSegmentFrames {
            splitLongSegment(events: &events)
        } else {
            framesSincePreview += 1
            offerPreview(events: &events)
        }
    }

    private mutating func processContinuousFrame(_ frame: [Float], level: Float, events: inout [SegmenterEvent]) {
        if !isSpeaking {
            isSpeaking = true
            currentID += 1
            events.append(.speechStarted(id: currentID))
        }
        segment.append(contentsOf: frame)
        segmentLevels.append(level)
        if level >= configuration.minimumSpeechLevel {
            voicedFrames += 1
        }
        if segmentLevels.count >= maximumSegmentFrames {
            finishSegment(reason: .maximumLength, events: &events)
        } else {
            framesSincePreview += 1
            offerPreview(events: &events)
        }
    }

    private mutating func beginSegment(voicedFrames onsetVoiced: Int, events: inout [SegmenterEvent]) {
        isSpeaking = true
        currentID += 1
        segment = preRollSamples
        segmentLevels = preRollLevels
        preRollSamples.removeAll(keepingCapacity: true)
        preRollLevels.removeAll(keepingCapacity: true)
        voicedFrames = onsetVoiced
        silentRun = 0
        onsetRun = 0
        framesSincePreview = segmentLevels.count
        events.append(.speechStarted(id: currentID))
    }

    private mutating func finishSegment(reason: SegmentEndReason, events: inout [SegmenterEvent]) {
        if reason == .silence {
            let dropFrames = silentRun - trailingKeptFrames
            if dropFrames > 0, dropFrames < segmentLevels.count {
                segment.removeLast(min(segment.count, dropFrames * frameLength))
                segmentLevels.removeLast(dropFrames)
            }
        }
        if voicedFrames >= minimumSpeechFrames, !segment.isEmpty {
            events.append(.segment(id: currentID, samples: segment, reason: reason))
        } else {
            events.append(.discarded(id: currentID))
        }
        clearSegment()
    }

    /// Cuts an over-long utterance at the quietest frame in the last
    /// `cutSearchWindow` and keeps the rest as the start of the next chunk.
    private mutating func splitLongSegment(events: inout [SegmenterEvent]) {
        let frameCount = segmentLevels.count
        let searchStart = max(frameCount / 2, frameCount - cutSearchFrames)
        var cutFrame = frameCount
        var quietest = Float.greatestFiniteMagnitude
        if searchStart < frameCount {
            for index in searchStart..<frameCount where segmentLevels[index] <= quietest {
                quietest = segmentLevels[index]
                cutFrame = index + 1
            }
        }
        let cutSample = min(cutFrame * frameLength, segment.count)
        let chunk = Array(segment[..<cutSample])
        let remainder = Array(segment[cutSample...])
        let remainderLevels = Array(segmentLevels[min(cutFrame, frameCount)...])

        events.append(.segment(id: currentID, samples: chunk, reason: .maximumLength))
        currentID += 1
        events.append(.speechStarted(id: currentID))

        let release = speechThreshold - configuration.releaseHysteresis
        segment = remainder
        segmentLevels = remainderLevels
        voicedFrames = remainderLevels.filter { $0 >= release }.count
        silentRun = 0
        for level in remainderLevels.reversed() {
            guard level < release else { break }
            silentRun += 1
        }
        framesSincePreview = remainderLevels.count
    }

    private mutating func offerPreview(events: inout [SegmenterEvent]) {
        guard previewIntervalFrames > 0,
              segmentLevels.count >= minimumPreviewFrames,
              framesSincePreview >= previewIntervalFrames else { return }
        framesSincePreview = 0
        events.append(.preview(id: currentID, samples: segment))
    }

    private mutating func clearSegment() {
        isSpeaking = false
        segment.removeAll(keepingCapacity: true)
        segmentLevels.removeAll(keepingCapacity: true)
        voicedFrames = 0
        silentRun = 0
        framesSincePreview = 0
    }

    private mutating func appendPreRoll(_ frame: [Float], level: Float) {
        preRollSamples.append(contentsOf: frame)
        preRollLevels.append(level)
        if preRollLevels.count > preRollFrames {
            preRollLevels.removeFirst()
            preRollSamples.removeFirst(frameLength)
        }
    }

    // MARK: - Noise floor

    private mutating func recordLevel(_ level: Float) {
        if levelHistory.count < historyCapacity {
            levelHistory.append(level)
        } else {
            levelHistory[historyIndex] = level
            historyIndex = (historyIndex + 1) % historyCapacity
        }
        framesSinceFloorUpdate += 1
        // Re-estimating every 100 ms is plenty and keeps the sort cheap.
        guard levelHistory.count >= minimumHistory, framesSinceFloorUpdate >= 5 else { return }
        framesSinceFloorUpdate = 0
        let sorted = levelHistory.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * configuration.noisePercentile))
        noiseFloor = min(max(sorted[index], -90), -25)
    }

    private mutating func recomputeFrameCounts() {
        let rate = Double(max(configuration.sampleRate, 1))
        let frameSeconds = max(configuration.frameDuration, 0.005)
        func frames(_ seconds: Double) -> Int { Int((seconds / frameSeconds).rounded()) }

        frameLength = max(1, Int((rate * frameSeconds).rounded()))
        onsetFrames = max(1, frames(configuration.onsetDuration))
        endSilenceFrames = max(1, frames(configuration.endSilence))
        trailingKeptFrames = max(0, frames(configuration.trailingSilenceKept))
        preRollFrames = max(onsetFrames, frames(configuration.preRoll))
        minimumSpeechFrames = max(1, frames(configuration.minimumSpeech))
        maximumSegmentFrames = max(onsetFrames + 1, frames(configuration.maximumSegment))
        cutSearchFrames = max(1, frames(configuration.cutSearchWindow))
        previewIntervalFrames = configuration.previewInterval > 0 ? max(1, frames(configuration.previewInterval)) : 0
        minimumPreviewFrames = max(1, frames(configuration.minimumPreview))

        let newCapacity = max(minimumHistory, frames(configuration.noiseWindow))
        if newCapacity != historyCapacity {
            historyCapacity = newCapacity
            levelHistory.removeAll()
            historyIndex = 0
        }
    }
}
