import XCTest
@testable import EarshotCore

final class SpeechSegmenterTests: XCTestCase {
    func testSilenceProducesNothing() {
        var segmenter = SpeechSegmenter()
        let events = segmenter.process(Synth.silence(5)) + segmenter.flush()
        XCTAssertTrue(events.isEmpty, "\(events)")
        XCTAssertFalse(segmenter.isSpeaking)
    }

    func testSingleUtteranceIsSegmentedAtThePause() {
        var segmenter = SpeechSegmenter()
        let events = segmenter.process(Synth.silence(1) + Synth.tone(1.5) + Synth.silence(1.5))

        XCTAssertEqual(events.starts, [1])
        let segments = events.segments
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.reason, .silence)
        // pre-roll (0.3 s) + speech (1.5 s) + kept tail (0.25 s), give or take a frame
        let duration = Double(segments.first?.samples.count ?? 0) / Double(Synth.rate)
        XCTAssertEqual(duration, 2.0, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(events.previewCount, 1)
        XCTAssertFalse(segmenter.isSpeaking)
    }

    func testPreRollKeepsTheStartOfSpeech() throws {
        var segmenter = SpeechSegmenter()
        let events = segmenter.process(Synth.silence(1) + Synth.tone(1) + Synth.silence(1.5))
        let samples = try XCTUnwrap(events.segments.first?.samples)
        // The first 0.2 s are pre-roll silence, and the tone must follow right after.
        let firstLoud = try XCTUnwrap(samples.firstIndex { abs($0) > 0.1 })
        XCTAssertEqual(Double(firstLoud) / Double(Synth.rate), 0.24, accuracy: 0.05)
    }

    func testShortClickIsDiscarded() {
        var segmenter = SpeechSegmenter()
        let events = segmenter.process(Synth.silence(2) + Synth.tone(0.08) + Synth.silence(2))
        XCTAssertEqual(events.starts, [1])
        XCTAssertEqual(events.discardedIDs, [1])
        XCTAssertTrue(events.segments.isEmpty)
    }

    func testMonologueIsCutAtQuietPointsWithinTheMaximumLength() {
        var segmenter = SpeechSegmenter()
        let events = segmenter.process(Synth.silence(1) + Synth.monologue(30) + Synth.silence(1.5))
        let segments = events.segments

        XCTAssertGreaterThanOrEqual(segments.count, 3)
        XCTAssertEqual(segments.last?.reason, .silence)
        for segment in segments.dropLast() {
            XCTAssertEqual(segment.reason, .maximumLength)
            let duration = Double(segment.samples.count) / Double(Synth.rate)
            XCTAssertLessThanOrEqual(duration, 12.01)
            XCTAssertGreaterThanOrEqual(duration, 9.9)
            // Cut right after a dip, so the chunk ends quietly.
            let tail = Array(segment.samples.suffix(160))
            XCTAssertLessThan(AudioLevel.rms(tail), 0.01)
        }
        // Continuations get fresh ids and nothing is lost.
        XCTAssertEqual(segments.map(\.id), Array(1...segments.count))
        let total = segments.reduce(0) { $0 + $1.samples.count }
        XCTAssertEqual(Double(total) / Double(Synth.rate), 30.55, accuracy: 0.4)
        XCTAssertLessThanOrEqual(segmenter.noiseFloor, -25)
    }

    func testFlushClosesTheUtteranceInProgress() {
        var segmenter = SpeechSegmenter()
        let first = segmenter.process(Synth.silence(1) + Synth.tone(1))
        XCTAssertTrue(segmenter.isSpeaking)
        XCTAssertTrue(first.segments.isEmpty)
        let flushed = segmenter.flush()
        XCTAssertEqual(flushed.segments.first?.reason, .flush)
        XCTAssertFalse(segmenter.isSpeaking)
    }

    func testAdaptsToSteadyBackgroundNoise() {
        var segmenter = SpeechSegmenter()
        _ = segmenter.process(Synth.noise(3, amplitude: 0.02, seed: 3))
        let settled = segmenter.process(Synth.noise(3, amplitude: 0.02, seed: 4))
        XCTAssertTrue(settled.starts.isEmpty, "steady noise should not look like speech once the floor adapts")
        XCTAssertFalse(segmenter.isSpeaking)
        XCTAssertGreaterThan(segmenter.noiseFloor, -45)

        let speech = segmenter.process(
            zip(Synth.tone(1), Synth.noise(1, amplitude: 0.02, seed: 5)).map { $0 + $1 }
                + Synth.noise(1.5, amplitude: 0.02, seed: 6)
        )
        XCTAssertEqual(speech.starts.count, 1)
        XCTAssertEqual(speech.segments.count, 1)
        XCTAssertEqual(speech.segments.first?.reason, .silence)
    }

    func testContinuousModeCutsFixedChunks() {
        var configuration = SegmenterConfiguration()
        configuration.continuous = true
        configuration.maximumSegment = 2
        var segmenter = SpeechSegmenter(configuration: configuration)
        let events = segmenter.process(Synth.tone(5)) + segmenter.flush()
        let segments = events.segments
        XCTAssertEqual(segments.map(\.reason), [.maximumLength, .maximumLength, .flush])
        XCTAssertEqual(segments.map { $0.samples.count }, [32_000, 32_000, 16_000])
    }

    func testContinuousModeDropsPureSilence() {
        var configuration = SegmenterConfiguration()
        configuration.continuous = true
        configuration.maximumSegment = 2
        var segmenter = SpeechSegmenter(configuration: configuration)
        let events = segmenter.process(Synth.silence(4))
        XCTAssertTrue(events.segments.isEmpty)
        XCTAssertEqual(events.discardedIDs.count, 2)
    }

    func testPreviewsCanBeDisabled() {
        var configuration = SegmenterConfiguration()
        configuration.previewInterval = 0
        var segmenter = SpeechSegmenter(configuration: configuration)
        let events = segmenter.process(Synth.silence(1) + Synth.tone(4) + Synth.silence(1.5))
        XCTAssertEqual(events.previewCount, 0)
        XCTAssertEqual(events.segments.count, 1)
    }

    func testSensitivityMapping() {
        var configuration = SegmenterConfiguration()
        configuration.applySensitivity(0)
        XCTAssertEqual(configuration.onsetMargin, 15, accuracy: 0.001)
        XCTAssertEqual(configuration.minimumSpeechLevel, -45, accuracy: 0.001)
        configuration.applySensitivity(1)
        XCTAssertEqual(configuration.onsetMargin, 5, accuracy: 0.001)
        XCTAssertEqual(configuration.minimumSpeechLevel, -62, accuracy: 0.001)
        configuration.applySensitivity(7)
        XCTAssertEqual(configuration.onsetMargin, 5, accuracy: 0.001)
    }

    func testOddChunkSizesGiveTheSameResult() {
        let audio = Synth.silence(1) + Synth.tone(1.5) + Synth.silence(1.5)
        var whole = SpeechSegmenter()
        let expected = whole.process(audio)

        var pieces = SpeechSegmenter()
        var events: [SegmenterEvent] = []
        var offset = 0
        var size = 1
        while offset < audio.count {
            let end = min(offset + size, audio.count)
            events += pieces.process(Array(audio[offset..<end]))
            offset = end
            size = size * 3 % 997 + 1
        }
        XCTAssertEqual(events, expected)
    }

    func testUpdateKeepsTheNoiseEstimate() {
        var segmenter = SpeechSegmenter()
        _ = segmenter.process(Synth.noise(3, amplitude: 0.02, seed: 9))
        let floor = segmenter.noiseFloor
        var configuration = segmenter.configuration
        configuration.endSilence = 1.2
        segmenter.update(configuration: configuration)
        XCTAssertEqual(segmenter.noiseFloor, floor)
        XCTAssertEqual(segmenter.configuration.endSilence, 1.2)
    }
}
