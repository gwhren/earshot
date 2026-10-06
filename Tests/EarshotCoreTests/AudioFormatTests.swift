import XCTest
@testable import EarshotCore

final class AudioFormatTests: XCTestCase {
    func testPCM16RoundTrip() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.25, 2, -3, .nan]
        let data = WAVFile.encodePCM16(samples, sampleRate: 16_000)
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")

        let decoded = try WAVFile.decode(data)
        XCTAssertEqual(decoded.sampleRate, 16_000)
        let expected: [Float] = [0, 0.5, -0.5, 1, -1, 0.25, 1, -1, 0]
        XCTAssertEqual(decoded.samples.count, expected.count)
        for (value, target) in zip(decoded.samples, expected) {
            XCTAssertEqual(value, target, accuracy: 1.0 / 16_000)
        }
    }

    func testDecodesStereoFloatAndSkipsUnknownChunks() throws {
        var data = Data("RIFF".utf8)
        data.appendLittleEndian(UInt32(0))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("LIST".utf8))
        data.appendLittleEndian(UInt32(3))
        data.append(contentsOf: [1, 2, 3, 0])  // odd-sized chunk plus its pad byte
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(3))      // IEEE float
        data.appendLittleEndian(UInt16(2))      // stereo
        data.appendLittleEndian(UInt32(48_000))
        data.appendLittleEndian(UInt32(48_000 * 8))
        data.appendLittleEndian(UInt16(8))
        data.appendLittleEndian(UInt16(32))
        data.append(contentsOf: Array("data".utf8))
        let frames: [(Float, Float)] = [(1, 0), (0.5, 0.5), (-1, -0.5)]
        data.appendLittleEndian(UInt32(frames.count * 8))
        for (left, right) in frames {
            data.appendLittleEndian(left.bitPattern)
            data.appendLittleEndian(right.bitPattern)
        }

        let decoded = try WAVFile.decode(data)
        XCTAssertEqual(decoded.sampleRate, 48_000)
        XCTAssertEqual(decoded.samples, [0.5, 0.5, -0.75])
    }

    func testRejectsNonWAVData() {
        XCTAssertThrowsError(try WAVFile.decode(Data("hello world, not audio".utf8))) { error in
            XCTAssertEqual(error as? WAVError, .notRIFF)
        }
    }

    func testResamplerKeepsDurationAndShape() {
        let source = Synth.tone(1, amplitude: 0.5, frequency: 100).map { $0 }  // 16 kHz
        let up = Resampler.resample(source, from: 16_000, to: 48_000)
        XCTAssertEqual(up.count, 48_000)
        let down = Resampler.resample(up, from: 48_000, to: 16_000)
        XCTAssertEqual(down.count, 16_000)
        XCTAssertEqual(AudioLevel.rms(down), AudioLevel.rms(source), accuracy: 0.01)
        XCTAssertEqual(Resampler.resample(source, from: 16_000, to: 16_000), source)
    }

    func testLevels() {
        XCTAssertEqual(AudioLevel.rms([Float]()), 0)
        XCTAssertEqual(AudioLevel.rms([1, -1, 1, -1]), 1, accuracy: 1e-6)
        XCTAssertEqual(AudioLevel.decibels(fromRMS: 1), 0, accuracy: 1e-4)
        XCTAssertEqual(AudioLevel.decibels(fromRMS: 0.1), -20, accuracy: 1e-3)
        XCTAssertEqual(AudioLevel.decibels(fromRMS: 0), -100)
        XCTAssertEqual(AudioLevel.meterValue(decibels: -30), 0.5, accuracy: 1e-6)
        XCTAssertEqual(AudioLevel.meterValue(decibels: -90), 0)
        XCTAssertEqual(AudioLevel.meterValue(decibels: 6), 1)
    }
}
