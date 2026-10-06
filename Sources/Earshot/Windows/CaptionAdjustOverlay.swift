import AppKit

/// Covers the captions while they're unlocked: a dashed outline, a Done button
/// and a resize grip. Dragging anywhere else moves the window.
final class CaptionAdjustOverlay: NSView {
    /// Called on any mouse activity, so the auto-lock timer can start over.
    var onActivity: (() -> Void)?
    var onDone: (() -> Void)?
    var accentColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }
    /// The colour of the grip: the theme's text colour, so it shows on light and dark themes alike.
    var gripColor: NSColor = .white {
        didSet { grip.color = gripColor }
    }

    private let doneButton = FirstClickButton(title: "Done", target: nil, action: nil)
    private let grip = ResizeGrip()

    override init(frame: NSRect) {
        super.init(frame: frame)
        doneButton.bezelStyle = .push
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(doneButton)

        grip.onResize = { [weak self] in self?.onActivity?() }
        grip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grip)

        NSLayoutConstraint.activate([
            doneButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            grip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            grip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            grip.widthAnchor.constraint(equalToConstant: 18),
            grip.heightAnchor.constraint(equalToConstant: 18),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // The panel isn't key until it's been clicked; take that first click anyway.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        onActivity?()
    }

    override func mouseDown(with event: NSEvent) {
        onActivity?()
        window?.performDrag(with: event)
        onActivity?()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Fully transparent pixels let clicks fall through to the app behind, so give the whole
        // area an all-but-invisible fill; without it, a theme with no backdrop (Shadow) could
        // only be dragged by its outline or text.
        NSColor.black.withAlphaComponent(0.01).setFill()
        bounds.fill()

        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 16, yRadius: 16)
        outline.lineWidth = 3
        outline.setLineDash([10, 6], count: 2, phase: 0)
        accentColor.setStroke()
        outline.stroke()
    }

    @objc private func done() {
        onDone?()
    }
}

/// A button that works on the first click even when the captions aren't the key window.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The bottom-right handle. The top edge stays put while the corner follows the pointer.
final class ResizeGrip: NSView {
    var onResize: (() -> Void)?
    var color: NSColor = .white {
        didSet { needsDisplay = true }
    }
    private var startFrame = NSRect.zero
    private var startPoint = NSPoint.zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startFrame = window.frame
        startPoint = NSEvent.mouseLocation
        onResize?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let point = NSEvent.mouseLocation
        let minimum = CaptionPanel.minimumSize
        let width = max(minimum.width, startFrame.width + point.x - startPoint.x)
        let height = max(minimum.height, startFrame.height - (point.y - startPoint.y))
        window.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height), display: true)
        onResize?()
    }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.85).setStroke()
        for inset in stride(from: CGFloat(4), through: 14, by: 5) {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: bounds.maxX - inset, y: bounds.minY + 2))
            line.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + inset))
            line.lineWidth = 1.5
            line.stroke()
        }
    }
}
