// Generates the app icon: the same `play.rectangle` SF Symbol the menu bar uses,
// white on a gradient tile shaped like every other macOS icon.
//
// Run it with `make icon`; it rewrites AppIcon.appiconset in place.

import AppKit

let symbolName = "play.rectangle"
let topColor = NSColor(srgbRed: 0.36, green: 0.55, blue: 1.00, alpha: 1)
let bottomColor = NSColor(srgbRed: 0.66, green: 0.33, blue: 0.95, alpha: 1)

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "kid-video-thing/Assets.xcassets/AppIcon.appiconset"

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS icons leave a margin around the tile: content is 824/1024 wide.
    let inset = size * 100.0 / 1024.0
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 185.0 / 824.0
    let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.022,
                  color: NSColor(white: 0, alpha: 0.28).cgColor)
    NSColor.black.setFill()
    tile.fill()
    ctx.restoreGState()

    ctx.saveGState()
    tile.addClip()
    NSGradient(colors: [topColor, bottomColor])!.draw(in: rect, angle: -90)
    // A soft highlight across the top half, so the tile reads as lit from above.
    let sheen = NSGradient(colors: [NSColor(white: 1, alpha: 0.28), NSColor(white: 1, alpha: 0)])!
    sheen.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2),
               angle: -90)
    ctx.restoreGState()

    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.52, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        fatalError("no such SF Symbol: \(symbolName)")
    }
    let target = NSRect(x: rect.midX - symbol.size.width / 2,
                        y: rect.midY - symbol.size.height / 2,
                        width: symbol.size.width,
                        height: symbol.size.height)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.006),
                  blur: size * 0.012,
                  color: NSColor(white: 0, alpha: 0.22).cgColor)
    symbol.isTemplate = false
    symbol.draw(in: target)
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

func write(_ image: NSImage, pixels: Int, to path: String) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// Every size macOS asks for, at both scales.
let points = [16, 32, 128, 256, 512]
var entries: [String] = []

for point in points {
    for scale in [1, 2] {
        let pixels = point * scale
        let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
        try write(render(size: CGFloat(pixels)), pixels: pixels, to: "\(outDir)/\(name)")
        entries.append("""
            {
              "filename" : "\(name)",
              "idiom" : "mac",
              "scale" : "\(scale)x",
              "size" : "\(point)x\(point)"
            }
        """)
        print("wrote \(name)")
    }
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(toFile: "\(outDir)/Contents.json", atomically: true, encoding: .utf8)
print("wrote Contents.json")
