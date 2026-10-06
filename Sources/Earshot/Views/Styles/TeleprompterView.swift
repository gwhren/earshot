import SwiftUI

/// Big text that rolls upwards as the speaker talks; can be mirrored for beam-splitter glass.
struct TeleprompterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let pane: DisplayPane
    private let bottomID = "teleprompter-bottom"
    /// Fraction of the height kept free below the newest line.
    private let readingLine: CGFloat = 0.18

    var body: some View {
        let theme = settings.theme
        let size = settings.styledFontSize
        let alignment = settings.textAlignment
        let lines = model.paneLines(pane)

        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: alignment.horizontal, spacing: size * 0.55) {
                            Color.clear.frame(height: geometry.size.height * 0.3)
                            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                                let age = lines.count - 1 - index
                                Text(line.text)
                                    .font(settings.font(size: size))
                                    .italic(line.isPreview && !line.isPlaceholder)
                                    .lineSpacing(settings.lineSpacing + size * 0.08)
                                    .foregroundStyle(lineColor(line, age: age, theme: theme))
                                    .multilineTextAlignment(alignment.text)
                                    .frame(maxWidth: .infinity, alignment: alignment.frame)
                                    .id(line.id)
                            }
                            // Keeps the newest line a little above the bottom edge, near eye level.
                            Color.clear
                                .frame(height: geometry.size.height * readingLine)
                                .id(bottomID)
                        }
                        .padding(.horizontal, 32)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: model.revision) {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                    .onChange(of: lines.count) {
                        withAnimation(.easeOut(duration: 0.45)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
                .captionShadow(theme)
                .edgeFade(top: 0.28, bottom: 0.04)

                // Reading cue beside the newest line (the Shadow theme shows only text).
                if !theme.bare {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: max(9, size * 0.3)))
                        .foregroundStyle(theme.accent.opacity(0.75))
                        .padding(.leading, 10)
                        .padding(.bottom, geometry.size.height * readingLine + size * 0.2)
                }
            }
        }
        .scaleEffect(x: settings.teleprompterMirror ? -1 : 1, y: 1)
    }

    /// The newest line is brightest; older ones fade as they roll up.
    private func lineColor(_ line: PaneLine, age: Int, theme: Theme) -> Color {
        if line.isPlaceholder { return theme.secondaryText }
        if age == 0 { return theme.text.opacity(line.isPending ? 0.8 : 1) }
        return theme.text.opacity(max(0.3, 0.82 - Double(age) * 0.16))
    }
}
