import Foundation

public enum WAVError: Error, Equatable, LocalizedError {
    case notRIFF
    case missingFormat
    case missingData
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .notRIFF: return "Not a RIFF/WAVE file."
        case .missingFormat: return "The WAV file has no fmt chunk."
        case .missingData: return "The WAV file has no data chunk."
        case .unsupportedFormat(let detail): return "Unsupported WAV format: \(detail)."
        }
    }
}

/// Minimal RIFF/WAVE reading and writing — enough to ship speech to a
/// transcription endpoint and to read test recordings.
public enum WAVFile {
    /// Encodes mono float samples (-1...1) as 16-bit PCM.
    public static func encodePCM16(_ samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data()
        data.reserveCapacity(44 + dataSize)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))                 // PCM
        data.appendLittleEndian(UInt16(1))                 // mono
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2))    // byte rate
        data.appendLittleEndian(UInt16(2))                 // block align
        data.appendLittleEndian(UInt16(16))                // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(UInt32(dataSize))

        var pcm = [UInt8]()
        pcm.reserveCapacity(dataSize)
        for sample in samples {
            let clamped = sample.isFinite ? min(max(sample, -1), 1) : 0
            let value = UInt16(bitPattern: Int16((clamped * 32767).rounded()))
            pcm.append(UInt8(value & 0xFF))
            pcm.append(UInt8(value >> 8))
        }
        data.append(contentsOf: pcm)
        return data
    }

    /// Decodes PCM (8/16/24/32-bit) or 32/64-bit float WAV data, mixing down to mono.
    public static func decode(_ data: Data) throws -> (samples: [Float], sampleRate: Int) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else {
            throw WAVError.notRIFF
        }

        var formatTag: UInt16?
        var channels = 0
        var sampleRate = 0
        var bitsPerSample = 0
        var payload: ArraySlice<UInt8>?

        var cursor = 12
        while cursor + 8 <= bytes.count {
            let chunkID = String(decoding: bytes[cursor..<(cursor + 4)], as: UTF8.self)
            let chunkSize = Int(readUInt32(bytes, at: cursor + 4))
            let bodyStart = cursor + 8
            let bodyEnd = min(bytes.count, bodyStart + chunkSize)
            switch chunkID {
            case "fmt ":
                guard bodyEnd - bodyStart >= 16 else { throw WAVError.missingFormat }
                var tag = readUInt16(bytes, at: bodyStart)
                channels = Int(readUInt16(bytes, at: bodyStart + 2))
                sampleRate = Int(readUInt32(bytes, at: bodyStart + 4))
                bitsPerSample = Int(readUInt16(bytes, at: bodyStart + 14))
                if tag == 0xFFFE, bodyEnd - bodyStart >= 26 {
                    // WAVE_FORMAT_EXTENSIBLE: the real format is the first two bytes of the sub-format GUID.
                    tag = readUInt16(bytes, at: bodyStart + 24)
                }
                formatTag = tag
            case "data":
                payload = bytes[bodyStart..<bodyEnd]
            default:
                break
            }
            cursor = bodyStart + chunkSize + (chunkSize & 1)
        }

        guard let tag = formatTag else { throw WAVError.missingFormat }
        guard let body = payload else { throw WAVError.missingData }
        guard channels > 0, sampleRate > 0 else { throw WAVError.unsupportedFormat("\(channels) channels at \(sampleRate) Hz") }

        let bytesPerSample = bitsPerSample / 8
        guard bytesPerSample > 0 else { throw WAVError.unsupportedFormat("\(bitsPerSample)-bit samples") }
        let frameSize = bytesPerSample * channels
        let frameCount = body.count / frameSize
        var samples = [Float](repeating: 0, count: frameCount)
        let base = body.startIndex

        func sample(at offset: Int) throws -> Float {
            switch (tag, bitsPerSample) {
            case (1, 8):
                return (Float(body[offset]) - 128) / 128
            case (1, 16):
                return Float(Int16(bitPattern: readUInt16(bytes, at: offset))) / 32768
            case (1, 24):
                let raw = Int32(body[offset]) | Int32(body[offset + 1]) << 8 | Int32(body[offset + 2]) << 16
                let signed = (raw << 8) >> 8
                return Float(signed) / 8_388_608
            case (1, 32):
                return Float(Int32(bitPattern: readUInt32(bytes, at: offset))) / 2_147_483_648
            case (3, 32):
                return Float(bitPattern: readUInt32(bytes, at: offset))
            case (3, 64):
                let low = UInt64(readUInt32(bytes, at: offset))
                let high = UInt64(readUInt32(bytes, at: offset + 4))
                return Float(Double(bitPattern: low | high << 32))
            default:
                throw WAVError.unsupportedFormat("format \(tag), \(bitsPerSample)-bit")
            }
        }

        for frame in 0..<frameCount {
            var mixed: Float = 0
            for channel in 0..<channels {
                mixed += try sample(at: base + frame * frameSize + channel * bytesPerSample)
            }
            samples[frame] = mixed / Float(channels)
        }
        return (samples, sampleRate)
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

/// Linear-interpolation resampling. Good enough for speech recognition input.
public enum Resampler {
    public static func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        guard sourceRate > 0, targetRate > 0, sourceRate != targetRate, !samples.isEmpty else { return samples }
        let ratio = Double(sourceRate) / Double(targetRate)
        let outputCount = Int((Double(samples.count) / ratio).rounded(.down))
        guard outputCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let position = Double(index) * ratio
            let lower = Int(position)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            output[index] = samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
        return output
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
