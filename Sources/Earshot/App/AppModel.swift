import AppKit
import Combine
import EarshotCore
import SwiftUI
import UniformTypeIdentifiers

/// One column of the display (or one ticker band).
enum DisplayPane: Hashable {
    /// What was heard.
    case original
    /// The translation into this language code.
    case translation(String)

    /// Stable text for view identities.
    var key: String {
        switch self {
        case .original: return "original"
        case .translation(let code): return "translation-\(code)"
        }
    }
}

/// What one pane shows for a line.
struct ShownText: Equatable {
    var text: String
    /// A stand-in ("…") while the real text is on its way.
    var isPlaceholder: Bool
}

/// One utterance as the display styles see it.
struct DisplayLine: Identifiable, Equatable {
    /// Stable across preview → final so views can animate in place.
    let id: String
    /// What was heard (empty while it is still being transcribed).
    var original: String
    /// Translations by language code (missing or empty while still being translated).
    var translations: [String: String]
    var sourceLanguage: String?
    var timestamp: TimeInterval
    /// Still being spoken (live preview).
    var isPreview: Bool
    /// Transcription or translation still running.
    var isPending: Bool
    var failure: String?

    /// The text for one pane. Never falls back to another language, so a
    /// translation pane cannot flash the original before the translation lands.
    func shown(in pane: DisplayPane) -> ShownText? {
        switch pane {
        case .original:
            if !original.isEmpty { return ShownText(text: original, isPlaceholder: false) }
        case .translation(let code):
            if let text = translations[code], !text.isEmpty { return ShownText(text: text, isPlaceholder: false) }
            if failure != nil { return ShownText(text: "Couldn't translate this", isPlaceholder: true) }
        }
        return isPending ? ShownText(text: "…", isPlaceholder: true) : nil
    }
}

/// A line ready to draw in one pane.
struct PaneLine: Identifiable, Equatable {
    let id: String
    let text: String
    let isPlaceholder: Bool
    let isPreview: Bool
    let isPending: Bool
    let timestamp: TimeInterval
}

/// A short message shown at the bottom of the captions.
struct Banner: Identifiable, Equatable {
    enum Kind { case info, warning, error }
    enum Action: Equatable { case openSettings, openMicrophonePrivacy, retry }

    let id = UUID()
    var kind: Kind
    var message: String
    var action: Action?
    var stage: PipelineIssue.Stage?
}

enum ConnectionState: Equatable {
    case unknown
    case checking
    case connected(model: String, modelCount: Int)
    case failed(String)
}

/// App-wide state: the transcript, listening status and server health.
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings

    @Published private(set) var entries: [TranscriptEntry] = []
    @Published private(set) var preview: LivePreview?
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var level: Double = 0
    @Published private(set) var backlog = 0
    @Published private(set) var serverModels: [String] = []
    @Published private(set) var connection: ConnectionState = .unknown
    @Published private(set) var inputDeviceName = ""
    @Published var banner: Banner?
    /// True while the captions are on screen.
    @Published var captionsVisible = true
    /// Bumped whenever visible text changes, so views can follow along.
    @Published private(set) var revision = 0

    private let pipeline: TranslationPipeline
    private let capture = MicrophoneCapture()
    private let client = OpenAICompatibleClient()
    private var eventsTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?
    private var previewCache: [Int: LivePreview] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var lastConfiguration: PipelineConfiguration
    private let maximumEntries = 500

    init(settings: AppSettings) {
        self.settings = settings
        let configuration = settings.pipelineConfiguration()
        lastConfiguration = configuration
        pipeline = TranslationPipeline(configuration: configuration)

        let pipeline = self.pipeline
        capture.onSamples = { samples in
            pipeline.ingest(samples)
        }
        capture.onLevel = { [weak self] level in
            self?.level = level
        }
        capture.onFailure = { [weak self] message in
            self?.captureFailed(message)
        }

        eventsTask = Task { [weak self] in
            await pipeline.start()
            for await event in pipeline.events {
                guard let self else { return }
                self.apply(event)
            }
        }

        settings.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.settingsDidChange() }
            .store(in: &cancellables)
    }

    // MARK: - Listening

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    func startListening() {
        guard !isListening else { return }
        Task {
            guard await MicrophoneCapture.requestPermission() else {
                show(Banner(
                    kind: .error,
                    message: "Earshot needs the microphone. Allow it in System Settings → Privacy & Security → Microphone.",
                    action: .openMicrophonePrivacy
                ))
                return
            }
            do {
                try capture.start()
            } catch {
                show(Banner(kind: .error, message: error.localizedDescription, action: nil))
                return
            }
            isListening = true
            inputDeviceName = MicrophoneCapture.defaultInputName ?? "Default input"
            if banner?.action == .openMicrophonePrivacy { banner = nil }
            await pipeline.prepare()
        }
    }

    func stopListening() {
        guard isListening else { return }
        capture.stop()
        isListening = false
        isSpeaking = false
        level = 0
        pipeline.endUtterance()
    }

    private func captureFailed(_ message: String) {
        isListening = false
        isSpeaking = false
        level = 0
        pipeline.endUtterance()
        show(Banner(kind: .error, message: message, action: nil))
    }

    // MARK: - Server

    func refreshServer() async {
        connection = .checking
        let endpoint = settings.translationEndpoint
        do {
            let models = try await client.listModels(at: endpoint)
            serverModels = models
            let configured = settings.translationModel.trimmingCharacters(in: .whitespaces)
            if models.isEmpty && configured.isEmpty {
                connection = .failed("MLX Studio is running but has no model loaded.")
            } else {
                let model = configured.isEmpty ? (OpenAIBackend.pickTranslationModel(from: models) ?? models[0]) : configured
                connection = .connected(model: model, modelCount: models.count)
            }
        } catch {
            serverModels = []
            let issue = PipelineIssue.from(error, stage: .connection, configuration: settings.pipelineConfiguration())
            connection = .failed(issue.message)
        }
    }

    private func settingsDidChange() {
        let configuration = settings.pipelineConfiguration()
        guard configuration != lastConfiguration else { return }
        let serverChanged = configuration.translationEndpoint != lastConfiguration.translationEndpoint
            || configuration.translationModel != lastConfiguration.translationModel
        lastConfiguration = configuration
        let previous = configurationTask
        let pipeline = self.pipeline
        configurationTask = Task {
            await previous?.value
            await pipeline.update(configuration: configuration)
        }
        if serverChanged {
            Task { await refreshServer() }
        }
    }

    // MARK: - Transcript

    func clearTranscript() {
        entries.removeAll()
        preview = nil
        previewCache.removeAll()
        revision += 1
    }

    var hasTranscript: Bool {
        entries.contains { !$0.displayText.isEmpty }
    }

    func transcriptText(_ format: TranscriptExporter.Format = .plainText) -> String {
        TranscriptExporter.export(entries, as: format, includeSource: settings.panes.contains(.original))
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText(), forType: .string)
    }

    /// Saves the transcript through a free-standing save panel; the captions never host sheets.
    /// `finished` runs once the panel is done, whether it saved or was cancelled.
    func exportTranscript(as format: TranscriptExporter.Format, then finished: @escaping () -> Void) {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "Earshot \(formatter.string(from: Date())).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        let text = transcriptText(format)
        panel.level = .modalPanel
        panel.begin { response in
            defer { finished() }
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                _ = NSAlert(error: error).runModal()
            }
        }
    }

    /// Every utterance the display styles render, oldest first.
    var lines: [DisplayLine] {
        var result: [DisplayLine] = []
        result.reserveCapacity(entries.count + 1)
        for entry in entries {
            var original = entry.sourceText
            var translations = entry.translations
            if let cached = previewCache[entry.segmentID] {
                // Keep the live preview up until the final pass catches up, so text
                // never blanks out or shrinks mid-sentence.
                if original.isEmpty { original = cached.sourceText }
                if !entry.isFinished {
                    for (code, text) in cached.translations where text.count > translations[code, default: ""].count {
                        translations[code] = text
                    }
                }
            }
            if entry.isFinished, original.isEmpty, translations.values.allSatisfy(\.isEmpty) { continue }
            var failure: String?
            if case .failed(let reason) = entry.state { failure = reason }
            result.append(DisplayLine(
                id: "seg-\(entry.segmentID)",
                original: original,
                translations: translations,
                sourceLanguage: entry.sourceLanguage,
                timestamp: entry.startTime,
                isPreview: false,
                isPending: !entry.isFinished,
                failure: failure
            ))
        }
        if let preview, !result.contains(where: { $0.id == "seg-\(preview.segmentID)" }) {
            result.append(DisplayLine(
                id: "seg-\(preview.segmentID)",
                original: preview.sourceText,
                translations: preview.translations,
                sourceLanguage: settings.sourceLanguage?.code,
                timestamp: entries.last.map { $0.startTime + $0.duration } ?? 0,
                isPreview: true,
                isPending: true,
                failure: nil
            ))
        }
        return result
    }

    /// The lines one pane shows, oldest first.
    func paneLines(_ pane: DisplayPane) -> [PaneLine] {
        lines.compactMap { line in
            guard let shown = line.shown(in: pane) else { return nil }
            return PaneLine(
                id: line.id,
                text: shown.text,
                isPlaceholder: shown.isPlaceholder,
                isPreview: line.isPreview,
                isPending: line.isPending,
                timestamp: line.timestamp
            )
        }
    }

    /// Finished lines for a ticker band, newest last.
    func finishedLines(_ pane: DisplayPane) -> [PaneLine] {
        entries.suffix(30).compactMap { entry in
            let text: String
            switch pane {
            case .original: text = entry.sourceText
            case .translation(let code): text = entry.translation(code)
            }
            guard entry.isFinished, !text.isEmpty else { return nil }
            return PaneLine(
                id: "\(entry.id.uuidString)-\(pane.key)",
                text: text,
                isPlaceholder: false,
                isPreview: false,
                isPending: false,
                timestamp: entry.startTime
            )
        }
    }

    /// Header for the original pane: the chosen or most recently detected language, in its own name.
    var originalLanguageName: String {
        if let source = settings.sourceLanguage { return source.nativeName }
        if let code = entries.last(where: { $0.sourceLanguage != nil })?.sourceLanguage,
           let language = Languages.language(recognized: code) {
            return language.nativeName
        }
        return "Original"
    }

    // MARK: - Pipeline events

    private func apply(_ event: PipelineEvent) {
        switch event {
        case .ready(let model):
            connection = .connected(model: model, modelCount: max(serverModels.count, 1))
            clearBanner(for: .connection)
        case .speechActivity(let speaking):
            isSpeaking = speaking
        case .preview(let value):
            preview = value
            if let value {
                previewCache[value.segmentID] = value
            }
            revision += 1
        case .entryAdded(let entry):
            entries.append(entry)
            if entries.count > maximumEntries {
                entries.removeFirst(entries.count - maximumEntries)
            }
            revision += 1
        case .entryUpdated(let entry):
            if let index = entries.lastIndex(where: { $0.id == entry.id }) {
                entries[index] = entry
                if entry.isFinished {
                    previewCache.removeValue(forKey: entry.segmentID)
                }
                revision += 1
            }
        case .entryRemoved(let id):
            if let entry = entries.first(where: { $0.id == id }) {
                previewCache.removeValue(forKey: entry.segmentID)
            }
            entries.removeAll { $0.id == id }
            revision += 1
        case .backlog(let count):
            backlog = count
        case .issue(let issue):
            if issue.stage == .connection {
                connection = .failed(issue.message)
            }
            let action: Banner.Action?
            switch issue.kind {
            case .serverUnreachable, .noModelLoaded, .timeout: action = .retry
            case .modelNotFound, .speechUnavailable, .speechModelIncompatible: action = .openSettings
            case .modelLoadFailed, .other: action = nil
            }
            show(Banner(kind: issue.kind == .timeout ? .warning : .error, message: issue.message, action: action, stage: issue.stage))
        case .issueResolved(let stage):
            clearBanner(for: stage)
        }
        if previewCache.count > 20 {
            let keep = Set(previewCache.keys.sorted().suffix(5))
            previewCache = previewCache.filter { keep.contains($0.key) }
        }
    }

    // MARK: - Banners

    func show(_ banner: Banner) {
        if self.banner?.message == banner.message { return }
        self.banner = banner
        bannerDismissTask?.cancel()
        if banner.kind == .info {
            bannerDismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled else { return }
                self?.banner = nil
            }
        }
    }

    func dismissBanner() {
        banner = nil
    }

    private func clearBanner(for stage: PipelineIssue.Stage) {
        guard let banner, banner.stage == stage || (stage != .connection && banner.stage == .connection) else { return }
        self.banner = nil
    }

    func perform(_ action: Banner.Action) {
        switch action {
        case .openSettings:
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
        case .openMicrophonePrivacy:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                _ = NSWorkspace.shared.open(url)
            }
        case .retry:
            banner = nil
            Task {
                await refreshServer()
                if isListening { await pipeline.prepare() }
            }
        }
    }
}

extension Banner.Kind {
    /// SF Symbol shown beside the message.
    var symbol: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "clock.badge.exclamationmark"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

extension Banner.Action {
    /// Title of the menu item that performs the action.
    var title: String {
        switch self {
        case .openSettings: return "Open Settings…"
        case .openMicrophonePrivacy: return "Open Microphone Privacy Settings…"
        case .retry: return "Retry"
        }
    }
}
