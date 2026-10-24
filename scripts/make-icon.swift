// Draws the Wakeful app icon and writes a 1024×1024 PNG.
// Usage: swift scripts/make-icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linearGradient(_ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// MARK: Background: white rounded square on Apple's icon grid (824pt body, 100pt margins).

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
linearGradient([color(0xFFFFFF), color(0xEEF1F6)], from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.minY))
ctx.restoreGState()

// Hairline edge so the white icon stays defined on white backgrounds.
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1, dy: 1), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(color(0x000000, 0.08))
ctx.setLineWidth(2)
ctx.strokePath()

// MARK: Pill, tilted 45° like the menu bar icon.

let pillWidth: CGFloat = 250, pillLength: CGFloat = 600
let pill = CGRect(x: -pillWidth / 2, y: -pillLength / 2, width: pillWidth, height: pillLength)
let pillPath = CGPath(roundedRect: pill, cornerWidth: pillWidth / 2, cornerHeight: pillWidth / 2, transform: nil)
let seam: CGFloat = 14

ctx.translateBy(x: size / 2, y: size / 2)
ctx.rotate(by: -.pi / 4)

// Soft drop shadow under the pill.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 18, height: -18), blur: 40, color: color(0x1B3A6B, 0.30))
ctx.addPath(pillPath)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// Upper half: blue.
ctx.saveGState()
ctx.addPath(pillPath)
ctx.clip()
ctx.clip(to: CGRect(x: -pillWidth, y: seam / 2, width: pillWidth * 2, height: pillLength))
linearGradient([color(0x5AA8FF), color(0x1F63E6)], from: CGPoint(x: -pillWidth / 2, y: 0), to: CGPoint(x: pillWidth / 2, y: 0))
ctx.restoreGState()

// Lower half: light grey.
ctx.saveGState()
ctx.addPath(pillPath)
ctx.clip()
ctx.clip(to: CGRect(x: -pillWidth, y: -pillLength, width: pillWidth * 2, height: pillLength - seam / 2))
linearGradient([color(0xFFFFFF), color(0xD3DAE5)], from: CGPoint(x: -pillWidth / 2, y: 0), to: CGPoint(x: pillWidth / 2, y: 0))
ctx.restoreGState()

// Thin outline on the grey half so it separates from the white background.
ctx.saveGState()
ctx.clip(to: CGRect(x: -pillWidth, y: -pillLength, width: pillWidth * 2, height: pillLength - seam / 2))
ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: 2, dy: 2), cornerWidth: pillWidth / 2 - 2,
                   cornerHeight: pillWidth / 2 - 2, transform: nil))
ctx.setStrokeColor(color(0x8A97AB, 0.45))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

// Glossy highlight along the left edge of the pill.
ctx.saveGState()
let highlight = CGRect(x: -pillWidth / 2 + 38, y: -pillLength / 2 + 70, width: 34, height: pillLength - 140)
ctx.addPath(CGPath(roundedRect: highlight, cornerWidth: 17, cornerHeight: 17, transform: nil))
ctx.setFillColor(color(0xFFFFFF, 0.45))
ctx.fillPath()
ctx.restoreGState()

// MARK: Write PNG

let url = URL(fileURLWithPath: output)
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(output)") }
