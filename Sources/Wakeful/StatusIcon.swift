import AppKit

/// Menu bar icon: a diagonal pill, outlined when idle and filled while a session is active.
enum StatusIcon {
    static let inactive = make(active: false)
    static let active = make(active: true)

    private static func make(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: -.pi / 4)

            let width: CGFloat = 7.5, height: CGFloat = 16, line: CGFloat = 1.4
            let body = NSRect(x: -width / 2, y: -height / 2, width: width, height: height)
                .insetBy(dx: line / 2, dy: line / 2)
            let pill = NSBezierPath(roundedRect: body, xRadius: body.width / 2, yRadius: body.width / 2)
            NSColor.black.set()

            if active {
                // Fill the full outline (not the inset stroke path) so both states have the same
                // outer size and the icon doesn't shrink when a session starts.
                let outer = NSRect(x: -width / 2, y: -height / 2, width: width, height: height)
                NSBezierPath(roundedRect: outer, xRadius: width / 2, yRadius: width / 2).fill()
                // Punch out the seam between the two halves.
                context.setBlendMode(.clear)
                NSBezierPath(rect: NSRect(x: -width, y: -line / 2, width: width * 2, height: line)).fill()
            } else {
                pill.lineWidth = line
                pill.stroke()
                let seam = NSBezierPath()
                seam.move(to: NSPoint(x: body.minX, y: 0))
                seam.line(to: NSPoint(x: body.maxX, y: 0))
                seam.lineWidth = line
                seam.stroke()
                // Fill one half so the idle icon still reads as a capsule.
                NSBezierPath(rect: NSRect(x: -width, y: 0, width: width * 2, height: height)).addClip()
                pill.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? "Wakeful (active)" : "Wakeful"
        return image
    }
}
