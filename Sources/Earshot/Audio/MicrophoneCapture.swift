import AVFoundation
import EarshotCore

/// Captures the default input device and delivers 16 kHz mono float samples.
final class MicrophoneCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noInputDevice
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone is available. Connect one or pick an input in System Settings → Sound."
            case .unsupportedFormat: return "The microphone's audio format is not supported."
            }
        }
    }

    /// Called on the audio thread with each converted chunk.
    var onSamples: (@Sendable ([Float]) -> Void)?
    /// Input level 0…1, delivered on the main actor.
    var onLevel: (@MainActor @Sendable (Double) -> Void)?
    /// Capture stopped unexpectedly (device unplugged, …), delivered on the main actor.
    var onFailure: (@MainActor @Sendable (String) -> Void)?

    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var configurationObserver: NSObjectProtocol?
    private(set) var isRunning = false

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    static var defaultInputName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    func start() throws {
        guard !isRunning else { return }
        try installTap()
        engine.prepare()
        try engine.start()
        isRunning = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func installTap() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.unsupportedFormat
        }
        let outputFormat = self.outputFormat
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.deliver(buffer, converter: converter, outputFormat: outputFormat)
        }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // The converter keeps its resampling state between calls, so hand it this
        // buffer once and then report "no data for now".
        let handedOver = OneShot()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if handedOver.fired {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handedOver.fired = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0,
              let channel = output.floatChannelData?[0] else { return }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        onSamples?(samples)

        if let onLevel {
            let decibels = AudioLevel.decibels(fromRMS: AudioLevel.rms(samples))
            let level = Double(AudioLevel.meterValue(decibels: decibels))
            Task { @MainActor in onLevel(level) }
        }
    }

    private final class OneShot: @unchecked Sendable {
        var fired = false
    }

    /// The default input changed (headset plugged in, AirPods connected…): rebuild the tap.
    private func restartAfterConfigurationChange() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try installTap()
            engine.prepare()
            try engine.start()
        } catch {
            isRunning = false
            if let configurationObserver {
                NotificationCenter.default.removeObserver(configurationObserver)
            }
            configurationObserver = nil
            let message = "The microphone stopped: \(error.localizedDescription)"
            if let onFailure {
                Task { @MainActor in onFailure(message) }
            }
        }
    }
}
