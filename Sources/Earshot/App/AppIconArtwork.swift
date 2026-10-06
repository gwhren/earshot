import AppKit

/// Draws Earshot's icon: a caption bubble with sound waves on an indigo-to-teal tile.
@MainActor
enum AppIconArtwork {
    static func draw(in rect: CGRect) {
        let margin = rect.width * 0.098
        let tile = rect.insetBy(dx: margin, dy: margin)
        let radius = tile.width * 0.225

        // Soft drop shadow, as on system icons.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = rect.width * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.008)
        shadow.set()
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
        NSColor(calibratedRed: 0.13, green: 0.10, blue: 0.36, alpha: 1).setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.20, green: 0.13, blue: 0.52, alpha: 1),
            NSColor(calibratedRed: 0.09, green: 0.36, blue: 0.66, alpha: 1),
            NSColor(calibratedRed: 0.03, green: 0.64, blue: 0.66, alpha: 1),
        ])
        gradient?.draw(in: tilePath, angle: -58)

        // Caption bubble.
        let bubble = CGRect(
            x: tile.minX + tile.width * 0.14,
            y: tile.minY + tile.height * 0.25,
            width: tile.width * 0.62,
            height: tile.height * 0.42
        )
        let bubbleRadius = bubble.height * 0.24
        let bubblePath = NSBezierPath(roundedRect: bubble, xRadius: bubbleRadius, yRadius: bubbleRadius)
        let tail = NSBezierPath()
        tail.move(to: CGPoint(x: bubble.minX + bubble.width * 0.20, y: bubble.minY + 2))
        tail.line(to: CGPoint(x: bubble.minX + bubble.width * 0.10, y: bubble.minY - tile.height * 0.11))
        tail.line(to: CGPoint(x: bubble.minX + bubble.width * 0.42, y: bubble.minY + 2))
        tail.close()
        NSColor.white.setFill()
        bubblePath.fill()
        tail.fill()

        // Caption lines inside the bubble.
        let lineColor = NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.52, alpha: 1)
        lineColor.setFill()
        let lineHeight = bubble.height * 0.12
        let widths: [CGFloat] = [0.70, 0.52, 0.62]
        for (index, width) in widths.enumerated() {
            let y = bubble.maxY - bubble.height * 0.26 - CGFloat(index) * lineHeight * 1.9
            let line = CGRect(x: bubble.minX + bubble.width * 0.14, y: y - lineHeight / 2, width: bubble.width * width, height: lineHeight)
            NSBezierPath(roundedRect: line, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
        }

        // Sound waves arriving at the top right.
        NSColor.white.withAlphaComponent(0.92).setStroke()
        let center = CGPoint(x: tile.minX + tile.width * 0.72, y: tile.minY + tile.height * 0.70)
        for index in 0..<3 {
            let waveRadius = tile.width * (0.075 + CGFloat(index) * 0.065)
            let wave = NSBezierPath()
            wave.appendArc(withCenter: center, radius: waveRadius, startAngle: -8, endAngle: 72)
            wave.lineWidth = tile.width * 0.032
            wave.lineCapStyle = .round
            NSColor.white.withAlphaComponent(0.95 - CGFloat(index) * 0.22).setStroke()
            wave.stroke()
        }
    }

    /// Writes the PNGs `iconutil -c icns` expects.
    static func exportIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: pixels,
                    pixelsHigh: pixels,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ) else { continue }
                bitmap.size = NSSize(width: pixels, height: pixels)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
