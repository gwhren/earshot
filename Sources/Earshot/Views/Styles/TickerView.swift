import SwiftUI

/// A broadcast-style crawl: finished translations scroll right to left behind a LIVE badge,
/// with the sentence still being spoken shown above. With the original shown, or a second
/// language pinned, there's a band for each, stacked.
@MainActor
struct TickerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var tapes = TickerTapes()

    var body: some View {
        let theme = settings.theme
        let size = settings.styledFontSize
        let bandHeight = max(40, size * 1.9)
        let panes = settings.panes

        VStack(spacing: 6) {
            Spacer(minLength: 0)
            if let first = panes.first, let inProgress = inProgressText(in: first) {
                Text(inProgress)
                    .font(settings.font(size: max(11, size * 0.5), weight: .medium))
                    .italic()
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .captionShadow(theme)
            }
            ForEach(Array(panes.enumerated()), id: \.element) { index, pane in
                band(for: pane, isLast: index == panes.count - 1, size: size, bandHeight: bandHeight, theme: theme)
            }
        }
        .onAppear(perform: sync)
        .onChange(of: model.revision) {
            sync()
        }
        .onChange(of: panes) {
            sync()
        }
    }

    @ViewBuilder
    private func band(for pane: DisplayPane, isLast: Bool, size: CGFloat, bandHeight: CGFloat, theme: Theme) -> some View {
        let tape = tapes.tape(for: pane)
        if theme.bare {
            // The Shadow theme: no band or badge, just the shadowed text crawling across.
            let scale: CGFloat = pane == .original ? 0.8 : 1
            TickerBand(
                tape: tape,
                style: style(size: size * scale, color: pane == .original ? theme.secondaryText : theme.text, pane: pane),
                height: bandHeight * scale,
                background: .clear
            ) {
                EmptyView()
            }
            .captionShadow(theme)
            .padding(.bottom, isLast ? 8 : 0)
        } else if pane == .original {
            TickerBand(tape: tape, style: style(size: size * 0.8, color: theme.secondaryText, pane: pane), height: bandHeight * 0.8, background: theme.band.opacity(0.85)) {
                LanguageBadge(text: originalBadge, height: bandHeight * 0.8)
            }
        } else if isLast {
            TickerBand(tape: tape, style: style(size: size, color: theme.text, pane: pane), height: bandHeight, background: theme.band) {
                LiveBadge(theme: theme, pair: liveLabel(for: pane), speaking: model.isSpeaking, height: bandHeight)
            }
            .padding(.bottom, 8)
        } else {
            TickerBand(tape: tape, style: style(size: size, color: theme.text, pane: pane), height: bandHeight, background: theme.band) {
                LanguageBadge(text: badge(for: pane), height: bandHeight)
            }
        }
    }

    private func sync() {
        for pane in settings.panes {
            tapes.tape(for: pane).sync(model.finishedLines(pane))
        }
    }

    /// The sentence still being spoken, in the language of the top band.
    private func inProgressText(in pane: DisplayPane) -> String? {
        guard let line = model.paneLines(pane).last, line.isPending, !line.isPlaceholder else { return nil }
        return line.text
    }

    private var originalBadge: String {
        (settings.sourceLanguage?.badge ?? model.lines.last?.sourceLanguage?.uppercased()) ?? "ORIG"
    }

    private func badge(for pane: DisplayPane) -> String {
        if case .translation(let code) = pane { return code.uppercased() }
        return originalBadge
    }

    /// "AUTO → FR" with one language; just the band's own language when there are two.
    private func liveLabel(for pane: DisplayPane) -> String {
        settings.targetLanguages.count > 1 ? badge(for: pane) : settings.languagePairLabel
    }

    private func style(size: CGFloat, color: Color, pane: DisplayPane) -> TickerTape.Style {
        TickerTape.Style(
            font: settings.font(size: size),
            color: color,
            separator: settings.theme.accent,
            speed: CGFloat(settings.tickerSpeed),
            uppercase: settings.tickerUppercase,
            key: "\(pane.key)|\(settings.fontFamily)|\(size)|\(settings.fontWeight.rawValue)|\(settings.tickerUppercase)"
        )
    }
}

/// One crawl per pane, created the first time a band asks for it.
final class TickerTapes {
    private var tapes: [DisplayPane: TickerTape] = [:]

    func tape(for pane: DisplayPane) -> TickerTape {
        if let tape = tapes[pane] { return tape }
        let tape = TickerTape()
        tapes[pane] = tape
        return tape
    }
}

/// A band's language label ("ES", "EN") in place of the LIVE badge.
struct LanguageBadge: View {
    let text: String
    let height: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: height * 0.26, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, height * 0.25)
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.3))
    }
}

/// One crawling band with a badge on its left.
struct TickerBand<Badge: View>: View {
    @EnvironmentObject private var model: AppModel
    let tape: TickerTape
    let style: TickerTape.Style
    let height: CGFloat
    let background: Color
    let badge: Badge

    init(tape: TickerTape, style: TickerTape.Style, height: CGFloat, background: Color, @ViewBuilder badge: () -> Badge) {
        self.tape = tape
        self.style = style
        self.height = height
        self.background = background
        self.badge = badge()
    }

    var body: some View {
        HStack(spacing: 0) {
            badge
            TimelineView(.animation(minimumInterval: nil, paused: !model.captionsVisible)) { timeline in
                Canvas { context, canvasSize in
                    tape.render(in: &context, size: canvasSize, date: timeline.date, style: style)
                }
            }
            .clipped()
        }
        .frame(height: height)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 8)
    }
}

struct LiveBadge: View {
    let theme: Theme
    let pair: String
    let speaking: Bool
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: height * 0.12) {
                Circle()
                    .fill(Color.white)
                    .frame(width: height * 0.16, height: height * 0.16)
                    .opacity(speaking ? 1 : 0.4)
                Text("LIVE")
                    .font(.system(size: height * 0.3, weight: .black))
            }
            .padding(.horizontal, height * 0.3)
            .frame(maxHeight: .infinity)
            .background(theme.badge)
            Text(pair)
                .font(.system(size: height * 0.24, weight: .bold, design: .rounded))
                .padding(.horizontal, height * 0.25)
                .frame(maxHeight: .infinity)
                .background(Color.black.opacity(0.25))
        }
        .foregroundStyle(Color.white)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The crawl's state. A plain class held in `@State` so the Canvas can advance it
/// every frame without triggering SwiftUI updates.
final class TickerTape {
    struct Style {
        var font: Font
        var color: Color
        var separator: Color
        /// Points per second.
        var speed: CGFloat
        var uppercase: Bool
        /// Changes whenever text metrics change, forcing a re-measure.
        var key: String
    }

    private struct Item {
        let id: String
        let text: String
        /// Position on the tape, fixed the first time the item is laid out.
        var start: CGFloat?
        var width: CGFloat?
    }

    private var items: [Item] = []
    private var known = Set<String>()
    private var hasSynced = false
    private var offset: CGFloat = 0
    private var lastDate: Date?
    private var layoutKey = ""
    private let gap: CGFloat = 56

    /// Adds lines the tape has not seen yet.
    func sync(_ lines: [PaneLine]) {
        guard !lines.isEmpty else {
            items.removeAll()
            known.removeAll()
            return
        }
        if !hasSynced {
            hasSynced = true
            // Start with the latest line instead of replaying the whole history.
            for line in lines.dropLast() {
                known.insert(line.id)
            }
        }
        for line in lines where !known.contains(line.id) {
            known.insert(line.id)
            items.append(Item(id: line.id, text: line.text))
        }
        known.formIntersection(lines.map(\.id))
    }

    func render(in context: inout GraphicsContext, size: CGSize, date: Date, style: Style) {
        let elapsed = lastDate.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0
        lastDate = date

        if style.key != layoutKey {
            layoutKey = style.key
            let anchor = items.first?.start
            for index in items.indices {
                items[index].width = nil
                items[index].start = nil
            }
            if let anchor, !items.isEmpty {
                items[0].start = anchor
            }
        }

        var previousEnd: CGFloat?
        for index in items.indices {
            let label = style.uppercase ? items[index].text.uppercased() : items[index].text
            var resolved: GraphicsContext.ResolvedText?
            if items[index].width == nil {
                let measured = context.resolve(Text(label).font(style.font))
                items[index].width = measured.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: size.height)).width
                resolved = measured
            }
            let width = items[index].width ?? 0
            let start = items[index].start ?? max((previousEnd ?? -CGFloat.greatestFiniteMagnitude) + gap, offset + size.width)
            items[index].start = start
            previousEnd = start + width

            let x = start - offset
            guard x < size.width, x + width + gap > 0 else { continue }
            var text = resolved ?? context.resolve(Text(label).font(style.font))
            text.shading = .color(style.color)
            context.draw(text, at: CGPoint(x: x, y: size.height / 2), anchor: .leading)

            let dot = min(10, size.height * 0.14)
            let center = x + width + gap / 2
            context.fill(
                Path(ellipseIn: CGRect(x: center - dot / 2, y: size.height / 2 - dot / 2, width: dot, height: dot)),
                with: .color(style.separator)
            )
        }

        // Speed up while a backlog builds, so the crawl never falls far behind the speaker.
        let backlog = max(0, (previousEnd ?? offset) - offset - size.width)
        let boost = 1 + min(2.5, backlog / max(size.width * 1.5, 1))
        offset += style.speed * boost * CGFloat(elapsed)
        items.removeAll { ($0.start ?? .greatestFiniteMagnitude) + ($0.width ?? 0) + gap < offset }
    }
}
