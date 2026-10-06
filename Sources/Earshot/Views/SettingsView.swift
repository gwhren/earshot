import AppKit
import EarshotCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ModelSettingsTab()
                .tabItem { Label("Models", systemImage: "cpu") }
            LanguageSettingsTab()
                .tabItem { Label("Languages", systemImage: "globe") }
            DisplaySettingsTab()
                .tabItem { Label("Display", systemImage: "textformat") }
            ListeningSettingsTab()
                .tabItem { Label("Listening", systemImage: "waveform") }
            CaptionSettingsTab()
                .tabItem { Label("Captions", systemImage: "captions.bubble") }
        }
        .frame(width: 640, height: 600)
    }
}

// MARK: - Models

@MainActor
private struct ModelSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                TextField("Server", text: $settings.serverURL, prompt: Text("http://127.0.0.1:8080"))
                HStack {
                    connectionStatus
                    Spacer()
                    Button("Check Connection") {
                        Task { await model.refreshServer() }
                    }
                }
                Toggle("Use a different server for speech recognition", isOn: $settings.useSeparateSpeechServer)
                if settings.useSeparateSpeechServer {
                    TextField("Speech server", text: $settings.speechServerURL, prompt: Text("http://127.0.0.1:8000"))
                }
                SecureField("API key (optional)", text: $settings.apiKey)
            } header: {
                Text("MLX Studio")
            } footer: {
                Text("Earshot talks to MLX Studio's OpenAI-compatible API gateway, which listens on port 8080 by default (Server → API in MLX Studio). A plain `vmlx serve` uses port 8000; LM Studio or `mlx_lm.server` also work for translation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("Speech model", text: $settings.speechModel, prompt: Text(PipelineConfiguration.defaultSpeechModel))
                    Menu("Presets") {
                        ForEach(ModelCatalog.speech) { suggestion in
                            Button("\(suggestion.name) — \(suggestion.note)") {
                                settings.speechModel = suggestion.id
                            }
                        }
                    }
                    .fixedSize()
                }
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("MLX Studio's engine loads the speech model the first time it hears you, which can take a minute or two while it downloads (about 1.6 GB for Whisper large-v3 turbo).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("Translation model", text: $settings.translationModel, prompt: Text("Automatic: the model loaded in MLX Studio"))
                    Menu("Loaded") {
                        Button("Automatic") { settings.translationModel = "" }
                        if !model.serverModels.isEmpty {
                            Divider()
                            ForEach(model.serverModels, id: \.self) { name in
                                Button(name) { settings.translationModel = name }
                            }
                        }
                    }
                    .fixedSize()
                }
                Picker("Prompt format", selection: $settings.promptStyle) {
                    ForEach(PromptStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("Tell reasoning models not to think first", isOn: $settings.disableThinking)
                Stepper("Context: \(settings.contextTurns) earlier sentence\(settings.contextTurns == 1 ? "" : "s")", value: $settings.contextTurns, in: 0...6)
                LabeledContent("Temperature") {
                    HStack {
                        Slider(value: $settings.temperature, in: 0...1, step: 0.05)
                        Text(settings.temperature.formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit()
                            .frame(width: 36)
                    }
                }
                TextField("Extra instructions", text: $settings.instructions, prompt: Text("e.g. Use a formal tone. Keep product names in English."), axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text("Translation")
            } footer: {
                Text("TranslateGemma models get their native prompt automatically. Extra instructions and context apply to general chat models such as Qwen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(ModelCatalog.translation + ModelCatalog.speech.prefix(1)) { suggestion in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.name).font(.body.weight(.medium))
                            Text("\(suggestion.role.rawValue) · ~\(Int(suggestion.memoryGB.rounded())) GB · \(suggestion.note)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy Name") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(suggestion.id, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Recommended for this Mac (\(Int(ModelCatalog.physicalMemoryGB.rounded())) GB)")
            } footer: {
                Text("Search for these in MLX Studio's model browser. Whisper and TranslateGemma 12B together use about 9 GB, leaving plenty of room on a 64 GB Mac; TranslateGemma 27B or Qwen3 30B-A3B also fit comfortably. For TranslateGemma, set Multimodal Support (VLM) to Force Off in the MLX Studio session's settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshServer() }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch model.connection {
        case .unknown:
            Label("Not checked yet", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
        case let .connected(name, count):
            Label("Connected · using \(name) · \(count) model\(count == 1 ? "" : "s") loaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(3)
        }
    }
}

// MARK: - Languages

private struct LanguageSettingsTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Speech is in", selection: $settings.sourceLanguageCode) {
                    Text("Detect automatically").tag("")
                    Divider()
                    ForEach(Languages.sources) { language in
                        Text(language.menuTitle).tag(language.code)
                    }
                }
                Picker("Translate into", selection: $settings.targetLanguageCode) {
                    ForEach(Languages.targets) { language in
                        Text(language.menuTitle).tag(language.code)
                    }
                }
                Picker("Also translate into", selection: $settings.secondTargetLanguageCode) {
                    Text("None").tag("")
                    Divider()
                    ForEach(Languages.targets) { language in
                        Text(language.menuTitle).tag(language.code)
                    }
                }
                Toggle("Show speech that is already in the target language as-is", isOn: $settings.skipSameLanguage)
            } footer: {
                Text("Automatic detection handles speakers switching languages. Choosing the spoken language improves accuracy for short phrases and similar-sounding languages. With a second language, everything heard is shown in both, one column each — for a room where people speak different languages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Display

private struct DisplaySettingsTab: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var families: [String] = FontCatalog.systemDesigns

    var body: some View {
        Form {
            Section("Style") {
                Picker("Display style", selection: $settings.displayStyle) {
                    ForEach(DisplayStyle.allCases) { style in
                        Label(style.title, systemImage: style.symbol).tag(style)
                    }
                }
                Text(settings.displayStyle.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch settings.displayStyle {
                case .subtitles:
                    Stepper("Lines on screen: \(settings.subtitleLines)", value: $settings.subtitleLines, in: 1...4)
                case .teleprompter:
                    Toggle("Mirror horizontally (for teleprompter glass)", isOn: $settings.teleprompterMirror)
                case .ticker:
                    LabeledContent("Crawl speed") {
                        Slider(value: $settings.tickerSpeed, in: 30...300)
                    }
                    Toggle("Uppercase", isOn: $settings.tickerUppercase)
                case .transcript, .spotlight:
                    EmptyView()
                }
                Toggle("Show the original speech side by side", isOn: $settings.showOriginal)
                    .disabled(settings.secondTargetLanguage != nil)
                Text(settings.secondTargetLanguage != nil
                     ? "With two languages, each has its own column, so the original isn't shown separately. The ticker stacks a band per language."
                     : settings.showOriginal
                     ? "What was heard appears on the left and the translation on the right. The ticker stacks two bands instead."
                     : "Only the translation is shown; a faint “…” stands in until each sentence is translated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text") {
                Picker("Font", selection: $settings.fontFamily) {
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.fontSize, in: 12...96, step: 1)
                        Text("\(Int(settings.fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Weight", selection: $settings.fontWeight) {
                    ForEach(FontWeightOption.allCases) { weight in
                        Text(weight.title).tag(weight)
                    }
                }
                Picker("Alignment", selection: $settings.textAlignment) {
                    ForEach(TextAlignmentOption.allCases) { option in
                        Image(systemName: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Line spacing") {
                    Slider(value: $settings.lineSpacing, in: 0...24)
                }
            }

            Section("Colours") {
                Picker("Theme", selection: $settings.themeID) {
                    ForEach(ThemeID.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                if settings.themeID == .custom {
                    ColorPicker("Text", selection: colorBinding(\.customTextColor, fallback: .white), supportsOpacity: false)
                    ColorPicker("Background", selection: colorBinding(\.customBackgroundColor, fallback: .black), supportsOpacity: false)
                    ColorPicker("Accent", selection: colorBinding(\.customAccentColor, fallback: .red), supportsOpacity: false)
                }
                LabeledContent("Background opacity") {
                    HStack {
                        Slider(value: $settings.backgroundOpacity, in: 0...1)
                        Text("\(Int(settings.backgroundOpacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(settings.theme.bare)
                if settings.theme.bare {
                    Text("The Shadow theme has no background: just white text with a drop shadow, without labels or a divider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Preview") {
                StylePreview()
            }
        }
        .formStyle(.grouped)
        .task {
            families = FontCatalog.families
        }
    }

    private func colorBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, String>, fallback: Color) -> Binding<Color> {
        Binding(
            get: { Color(hex: settings[keyPath: keyPath]) ?? fallback },
            set: { settings[keyPath: keyPath] = $0.hexString }
        )
    }
}

@MainActor
private struct StylePreview: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = settings.theme
        ZStack {
            if theme.bare {
                // No backdrop of its own: show the text over a light, slide-like surface.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(white: 0.88))
            } else {
                PanelBackground(theme: theme, opacity: max(settings.backgroundOpacity, 0.6))
            }
            HStack(spacing: 0) {
                if settings.panes.count > 1 {
                    previewText("Bienvenidos a todos, empecemos.", theme: theme)
                    if !theme.bare {
                        Rectangle()
                            .fill(theme.secondaryText.opacity(0.25))
                            .frame(width: 1)
                            .padding(.vertical, 12)
                    }
                }
                previewText("Welcome, everyone — let's begin.", theme: theme)
            }
            .captionShadow(theme)
        }
        .frame(height: 110)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private func previewText(_ text: String, theme: Theme) -> some View {
        Text(text)
            .font(settings.font(size: min(settings.panes.count > 1 ? 24 : 34, CGFloat(settings.fontSize))))
            .foregroundStyle(theme.text)
            .multilineTextAlignment(settings.textAlignment.text)
            .frame(maxWidth: .infinity, alignment: settings.textAlignment.frame)
            .padding(16)
    }
}

// MARK: - Listening

private struct ListeningSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("Input") {
                    Text(model.inputDeviceName.isEmpty ? (MicrophoneCapture.defaultInputName ?? "Default input") : model.inputDeviceName)
                }
                LabeledContent("Level") {
                    LevelMeter(level: model.level, active: model.isSpeaking, color: .accentColor, bars: 12)
                }
                Button("Open Sound Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                        _ = NSWorkspace.shared.open(url)
                    }
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Earshot always uses the system's default input. Change it in Sound settings (or ⌥-click the menu bar volume icon).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Sensitivity") {
                    HStack {
                        Text("Strict").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.sensitivity, in: 0...1)
                        Text("Eager").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Pause that ends a sentence") {
                    HStack {
                        Slider(value: $settings.pauseLength, in: 0.3...2.0, step: 0.1)
                        Text("\(settings.pauseLength.formatted(.number.precision(.fractionLength(1)))) s")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("Longest chunk") {
                    HStack {
                        Slider(value: $settings.maximumSegment, in: 4...30, step: 1)
                        Text("\(Int(settings.maximumSegment)) s")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("Continuous mode (fixed chunks, no pause detection)", isOn: $settings.continuousMode)
            } header: {
                Text("Speech detection")
            } footer: {
                Text("Shorter pauses give faster captions; longer ones give the models whole sentences. Continuous mode helps with music or constant background noise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("While someone is talking", selection: $settings.livePreview) {
                    ForEach(LivePreviewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                Text("Live preview")
            } footer: {
                Text("Previews re-transcribe the sentence in progress about once a second, so words appear before the speaker pauses. They are dropped whenever finished sentences are waiting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Captions

private struct CaptionSettingsTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var hotKeys: HotKeyCenter
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Button("Move & Resize Captions…") {
                    NSApp.sendAction(#selector(AppDelegate.adjustCaptions(_:)), to: nil, from: nil)
                }
            } header: {
                Text("Captions")
            } footer: {
                Text("Captions float above every app, including full-screen presentations, and clicks pass straight through them. Move & Resize unlocks them until you click Done, press Esc, or leave them alone for 30 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(GlobalShortcut.allCases) { shortcut in
                    LabeledContent(shortcut.title) {
                        Text(hotKeys.registered.contains(shortcut) ? shortcut.displayString : "\(shortcut.displayString) (couldn't be registered)")
                            .foregroundStyle(hotKeys.registered.contains(shortcut) ? .primary : .secondary)
                    }
                }
            } header: {
                Text("Keyboard shortcuts")
            } footer: {
                Text("These work from any app, even during a full-screen presentation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Start listening when Earshot opens", isOn: $settings.listenAtLaunch)
                Toggle("Open Earshot at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in
                        setOpenAtLogin(enabled)
                    }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Could not change the login item: \(error.localizedDescription)"
        }
    }
}
