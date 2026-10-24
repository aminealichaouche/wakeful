import AppKit
import XCTest
@testable import Wakeful

final class StatusIconTests: XCTestCase {
    /// The menu bar icon must keep the same size when a session starts or ends.
    func testBothStatesHaveTheSameSizeAndOutline() {
        XCTAssertEqual(StatusIcon.active.size, StatusIcon.inactive.size)
        XCTAssertEqual(inkBounds(StatusIcon.active), inkBounds(StatusIcon.inactive))
        XCTAssertTrue(StatusIcon.active.isTemplate)
        XCTAssertTrue(StatusIcon.inactive.isTemplate)
    }

    /// Bounding box of the drawn pixels at 4x scale.
    private func inkBounds(_ image: NSImage) -> CGRect {
        let scale = 4
        let width = Int(image.size.width) * scale, height = Int(image.size.height) * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        var box = CGRect.null
        for y in 0..<height {
            for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return box
    }
}
