import AppKit
import SwiftUI

/// Shared vector artwork stays crisp in a 16-point status item and larger cards.
enum MetricIconArtwork {
    private static var cache: [String: NSImage] = [:]

    static func image(for kind: MetricKind) -> NSImage {
        let key: String
        if kind.rawValue.lowercased().contains("bodybattery") { key = "human-battery" }
        else if kind == .steps { key = "footprints" }
        else if kind.category == .stress { key = "speedometer" }
        else { key = kind.symbol == "chart.bar.fill" ? kind.category.symbol : kind.symbol }
        if let image = cache[key] { return image }
        let image: NSImage
        if key == "human-battery" || key == "footprints" {
            image = NSImage(size: NSSize(width: 24, height: 24), flipped: true) { _ in
                NSColor.black.set()
                if key == "human-battery" { drawHumanBattery() } else { drawFootprints() }
                return true
            }
        } else {
            image = NSImage(systemSymbolName: key, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
                ?? NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil)!
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// Text attachments do not inherit template-image tinting. Resolve the actual
    /// system menu appearance, independently of the app's light/dark preference.
    static func menuImage(for kind: MetricKind, appearance: NSAppearance) -> NSImage {
        let glyph = image(for: kind)
        var ink = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            ink = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .black
        }
        return NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            ink.setFill(); rect.fill(using: .sourceIn)
            return true
        }
    }

    private static func stroke(_ points: [NSPoint], width: CGFloat = 1.8) {
        guard let first = points.first else { return }
        let path = NSBezierPath(); path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
    }

    private static func drawHumanBattery() {
        // A smiling little person whose torso is a battery, with raised arms.
        NSBezierPath(ovalIn: NSRect(x: 9, y: 1, width: 6, height: 6)).fill()
        let body = NSBezierPath(roundedRect: NSRect(x: 7, y: 8, width: 10, height: 10), xRadius: 2, yRadius: 2)
        body.lineWidth = 1.8; body.stroke()
        NSBezierPath(roundedRect: NSRect(x: 9, y: 10, width: 6, height: 2.3), xRadius: 0.6, yRadius: 0.6).fill()
        NSBezierPath(roundedRect: NSRect(x: 9, y: 13.5, width: 6, height: 2.3), xRadius: 0.6, yRadius: 0.6).fill()
        stroke([NSPoint(x: 7, y: 11), NSPoint(x: 4.5, y: 12), NSPoint(x: 2.5, y: 9)])
        stroke([NSPoint(x: 17, y: 11), NSPoint(x: 19.5, y: 12), NSPoint(x: 21.5, y: 9)])
        stroke([NSPoint(x: 10, y: 18), NSPoint(x: 8.5, y: 22), NSPoint(x: 6.5, y: 22)])
        stroke([NSPoint(x: 14, y: 18), NSPoint(x: 15.5, y: 22), NSPoint(x: 17.5, y: 22)])
        NSColor.white.set()
        let smile = NSBezierPath(); smile.move(to: NSPoint(x: 10.5, y: 4))
        smile.curve(to: NSPoint(x: 13.5, y: 4), controlPoint1: NSPoint(x: 11, y: 6), controlPoint2: NSPoint(x: 13, y: 6))
        smile.lineWidth = 0.8; smile.lineCapStyle = .round; smile.stroke()
    }

    private static func drawFootprints() {
        for (x, y) in [(CGFloat(4), CGFloat(6)), (CGFloat(14), CGFloat(1))] {
            let sole = NSBezierPath()
            sole.move(to: NSPoint(x: x + 1, y: y + 1))
            sole.curve(to: NSPoint(x: x + 6, y: y + 1), controlPoint1: NSPoint(x: x + 2, y: y - 1), controlPoint2: NSPoint(x: x + 5, y: y - 1))
            sole.curve(to: NSPoint(x: x + 4, y: y + 10), controlPoint1: NSPoint(x: x + 8, y: y + 5), controlPoint2: NSPoint(x: x + 2, y: y + 6))
            sole.curve(to: NSPoint(x: x, y: y + 8), controlPoint1: NSPoint(x: x + 2, y: y + 11), controlPoint2: NSPoint(x: x, y: y + 10))
            sole.curve(to: NSPoint(x: x + 1, y: y + 1), controlPoint1: NSPoint(x: x + 1, y: y + 5), controlPoint2: NSPoint(x: x - 1, y: y + 3))
            sole.close(); sole.fill()
            NSBezierPath(roundedRect: NSRect(x: x + 0.5, y: y + 11, width: 4, height: 4), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

struct MetricIcon: View {
    let kind: MetricKind
    var size: CGFloat = 18
    var body: some View {
        Image(nsImage: MetricIconArtwork.image(for: kind)).resizable().scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}
