import SwiftUI

/// Film-style captions: the newest lines at the bottom, older ones fading away above.
struct SubtitlesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let pane: DisplayPane

    var body: some View {
        let theme = settings.theme
        let size = settings.styledFontSize
        let alignment = settings.textAlignment
        let lines = Array(model.paneLines(pane).suffix(max(1, settings.subtitleLines)))

        VStack(alignment: alignment.horizontal, spacing: size * 0.35) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(settings.font(size: size))
                    .italic(line.isPreview && !line.isPlaceholder)
                    .foregroundStyle(PaneStyle.color(for: line, theme: theme))
                    .multilineTextAlignment(alignment.text)
                    .lineSpacing(settings.lineSpacing)
                    .frame(maxWidth: .infinity, alignment: alignment.frame)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .captionShadow(theme)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        // Anchor to the bottom and let long text overflow upwards, so the newest words stay visible.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .clipped()
        .edgeFade(top: 0.14)
        .animation(.easeOut(duration: 0.25), value: lines.map(\.id))
    }
}

/// Shared colouring for pane text.
enum PaneStyle {
    static func color(for line: PaneLine, theme: Theme) -> Color {
        if line.isPlaceholder { return theme.secondaryText }
        if line.isPending { return theme.text.opacity(0.75) }
        return theme.text
    }
}
