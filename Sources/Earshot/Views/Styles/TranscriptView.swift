import EarshotCore
import SwiftUI

/// Timestamped history, newest at the bottom. With several panes (the original
/// and its translation, or two languages), each row lines them up side by side.
struct TranscriptView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    private let endID = "transcript-end"

    var body: some View {
        let lines = model.lines
        let panes = settings.panes
        VStack(spacing: 0) {
            if panes.count > 1, !settings.theme.bare {
                HStack(spacing: 12) {
                    Color.clear.frame(width: TranscriptRow.timestampWidth, height: 1)
                    ForEach(panes, id: \.self) { pane in
                        PaneHeader(pane: pane)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(lines) { line in
                            if panes.contains(where: { line.shown(in: $0) != nil }) {
                                TranscriptRow(line: line, panes: panes)
                                    .id(line.id)
                            }
                        }
                        Color.clear
                            .frame(height: 4)
                            .id(endID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.revision) {
                    proxy.scrollTo(endID, anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo(endID, anchor: .bottom)
                }
            }
        }
    }
}

@MainActor
struct TranscriptRow: View {
    static let timestampWidth: CGFloat = 40

    @EnvironmentObject private var settings: AppSettings
    let line: DisplayLine
    let panes: [DisplayPane]

    var body: some View {
        let theme = settings.theme
        let size = settings.styledFontSize
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(TranscriptExporter.clock(line.timestamp))
                .font(.system(size: max(10, size * 0.5), design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .frame(width: Self.timestampWidth, alignment: .trailing)
            ForEach(panes, id: \.self) { pane in
                cell(line.shown(in: pane), size: size, theme: theme)
            }
        }
        .lineSpacing(settings.lineSpacing)
        .captionShadow(theme)
    }

    private func cell(_ shown: ShownText?, size: CGFloat, theme: Theme) -> some View {
        Text(shown?.text ?? "")
            .font(settings.font(size: size))
            .italic(line.isPreview && shown?.isPlaceholder == false)
            .foregroundStyle(color(shown, theme: theme))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ shown: ShownText?, theme: Theme) -> Color {
        guard let shown, !shown.isPlaceholder else { return theme.secondaryText }
        return line.isPending ? theme.text.opacity(0.7) : theme.text
    }
}
