import AppKit
import EarshotCore
import SwiftUI

/// Injects the shared objects into the caption window's view tree.
struct CaptionRootView: View {
    let model: AppModel
    let settings: AppSettings
    let chrome: CaptionChrome

    var body: some View {
        CaptionView()
            .environmentObject(model)
            .environmentObject(settings)
            .environmentObject(chrome)
    }
}

/// The captions themselves. Nothing here is clickable: the window lets clicks through
/// (except while Move & Resize has unlocked it, when an AppKit overlay takes the mouse),
/// and all the controls are in the menu-bar icon's menu.
@MainActor
struct CaptionView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chrome: CaptionChrome

    var body: some View {
        let theme = settings.theme
        let hasText = settings.panes.contains { !model.paneLines($0).isEmpty }
        ZStack(alignment: .bottom) {
            // With nothing to show the captions are fully transparent, so they never cover the slides.
            if hasText || chrome.isAdjusting, !theme.bare {
                PanelBackground(theme: theme, opacity: settings.backgroundOpacity)
            }
            if hasText {
                DisplayArea()
                    .padding(.top, 6)
            } else if chrome.isAdjusting {
                SampleCaptions()
            }
            // The Listening pill and any problem notice stack at the bottom rather than overlap.
            VStack(spacing: 8) {
                if !hasText, !chrome.isAdjusting, model.isListening {
                    ListeningPill()
                }
                if let banner = model.banner {
                    CaptionNotice(banner: banner)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .foregroundStyle(theme.text)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .animation(.easeInOut(duration: 0.25), value: model.banner)
        .ignoresSafeArea()
    }
}

/// Stand-in text while the captions are being moved, so their size is visible.
struct SampleCaptions: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = settings.theme
        VStack(spacing: 6) {
            Text("Captions appear here")
            Text("Drag to move · drag the corner to resize")
                .foregroundStyle(theme.secondaryText)
        }
        .font(settings.font(size: min(26, settings.styledFontSize)))
        .multilineTextAlignment(.center)
        .captionShadow(theme)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Panes

/// One column per pane, side by side: the translation alone, the original and
/// its translation, or two pinned languages. The ticker stacks bands instead,
/// and the transcript lines its columns up row by row.
struct DisplayArea: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        switch settings.displayStyle {
        case .ticker:
            TickerView()
        case .transcript:
            TranscriptView()
        case .subtitles, .teleprompter, .spotlight:
            let panes = settings.panes
            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element) { index, pane in
                    if index > 0, !settings.theme.bare {
                        Rectangle()
                            .fill(settings.theme.secondaryText.opacity(0.25))
                            .frame(width: 1)
                            .padding(.vertical, 10)
                    }
                    PaneColumn(pane: pane, showsHeader: panes.count > 1 && !settings.theme.bare)
                }
            }
        }
    }
}

struct PaneColumn: View {
    @EnvironmentObject private var settings: AppSettings
    let pane: DisplayPane
    let showsHeader: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                PaneHeader(pane: pane)
                    .padding(.horizontal, 22)
            }
            switch settings.displayStyle {
            case .subtitles: SubtitlesView(pane: pane)
            case .teleprompter: TeleprompterView(pane: pane)
            case .spotlight: SpotlightView(pane: pane)
            case .ticker, .transcript: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "ENGLISH" / "УКРАЇНСЬКА" above a pane: each language in its own name, so every
/// reader can find their side.
@MainActor
struct PaneHeader: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let pane: DisplayPane

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(settings.theme.secondaryText)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: settings.textAlignment.frame)
            .padding(.top, 2)
    }

    private var title: String {
        switch pane {
        case .original: return model.originalLanguageName
        case .translation(let code): return Languages.language(code: code)?.nativeName ?? code
        }
    }
}

// MARK: - Status

/// Shown while listening, before the first words arrive.
struct ListeningPill: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = settings.theme
        HStack(spacing: 8) {
            LevelMeter(level: model.level, active: model.isSpeaking, color: theme.accent)
            Text(model.isSpeaking ? "Hearing speech…" : "Listening")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            // The Shadow theme draws no boxes, just the shadowed text and level bars.
            if !theme.bare {
                Capsule().fill(theme.background.opacity(max(settings.backgroundOpacity, 0.6)))
            }
        }
        .captionShadow(theme)
    }
}

/// A problem, in one line. Its fix (Retry, Open Settings…) is in the menu-bar menu.
struct CaptionNotice: View {
    @EnvironmentObject private var settings: AppSettings
    let banner: Banner

    var body: some View {
        let theme = settings.theme
        let line = HStack(spacing: 6) {
            Image(systemName: banner.kind.symbol)
                .foregroundStyle(banner.kind.tint)
            Text(banner.message)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // The Shadow theme draws no boxes, just the shadowed text.
        if theme.bare {
            line
                .foregroundStyle(theme.text)
                .captionShadow(theme)
        } else {
            line
                .foregroundStyle(.primary)
                .background(.regularMaterial, in: Capsule())
        }
    }
}

extension Banner.Kind {
    var tint: Color {
        switch self {
        case .info: return .blue
        case .warning: return .yellow
        case .error: return .orange
        }
    }
}
