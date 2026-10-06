import SwiftUI

/// Only the sentence being spoken, as large as the captions allow; it types itself
/// out as the translation streams in and crossfades to the next one.
struct SpotlightView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let pane: DisplayPane

    var body: some View {
        let theme = settings.theme
        let size = settings.styledFontSize
        let line = model.paneLines(pane).last

        ZStack {
            if let line {
                Text(line.text)
                    .font(settings.font(size: size))
                    .italic(line.isPreview && !line.isPlaceholder)
                    .foregroundStyle(PaneStyle.color(for: line, theme: theme))
                    .lineSpacing(settings.lineSpacing)
                    .lineLimit(5)
                    .minimumScaleFactor(0.3)
                    .multilineTextAlignment(settings.textAlignment.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: settings.textAlignment.frame)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .captionShadow(theme)
                    .id(line.id)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97)),
                        removal: .opacity
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: line?.id)
    }
}
