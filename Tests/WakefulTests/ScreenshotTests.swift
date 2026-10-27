import AppKit
import SwiftUI
import XCTest
@testable import Wakeful

/// README screenshots of the menu panel, rendered offscreen with throwaway settings.
/// Run with WAKEFUL_SCREENSHOTS=<output folder> swift test --filter ScreenshotTests
final class ScreenshotTests: XCTestCase {
    private var output: URL!
    private var settings: Wakeful.Settings!
    private var cleanup: (() -> Void)!
    private var manager: SessionManager!

    override func setUpWithError() throws {
        let path = ProcessInfo.processInfo.environment["WAKEFUL_SCREENSHOTS"]
        try XCTSkipUnless(path != nil, "Screenshots run on request only")
        output = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        (settings, cleanup) = makeTestSettings()
        manager = SessionManager(settings: settings)
    }

    override func tearDown() {
        manager?.end()
        cleanup?()
    }

    func testCaptureReadmeScreenshots() throws {
        let navigation = MenuNavigation()
        let menu = makeMenuView(manager: manager, settings: settings, navigation: navigation)

        try render(menu, "1-idle")
        manager.start(.manual(until: Date().addingTimeInterval(83 * 60 + 30)))
        try render(menu, "2-session")
        navigation.page = .settings
        try render(menu, "3-settings")
        manager.end()
        settings.customRule = CustomRule(match: .all, conditions: [.networkDrive(nil), .charger])
        navigation.page = .rule
        try render(menu, "4-custom-rule")
    }

    /// Draws the menu on the panel's own menu material, as it appears under the menu bar.
    private func render(_ menu: MenuView, _ name: String) throws {
        let host = NSHostingView(rootView: menu.fixedSize(horizontal: false, vertical: true))
        host.frame.size = CGSize(width: MenuView.width, height: 10)
        host.layoutSubtreeIfNeeded()
        let size = CGSize(width: MenuView.width, height: host.fittingSize.height)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .menu
        background.blendingMode = .withinWindow
        background.state = .active
        host.frame = background.bounds
        background.addSubview(host)
        let window = ActiveWindow(contentRect: background.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = background
        // Let SwiftUI finish layout and its page/animation updates before drawing.
        waitUntil(timeout: 0.6) { false }
        background.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(background.bitmapImageRepForCachingDisplay(in: background.bounds))
        background.cacheDisplay(in: background.bounds, to: rep)
        // Clip to the panel's 10pt corner radius on a transparent canvas.
        let rounded = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rounded.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rounded)
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: rep.size), xRadius: 10, yRadius: 10).addClip()
        rep.draw(in: NSRect(origin: .zero, size: rep.size))
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(rounded.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent(name + ".png"))
    }
}

/// Draws controls in their active (accent-colored) state without showing or focusing a window.
private final class ActiveWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
