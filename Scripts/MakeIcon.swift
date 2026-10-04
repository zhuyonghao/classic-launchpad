import AppKit

// Vector source for the app icon. No downloaded artwork or runtime dependencies.
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func drawIcon() {
    let outer = NSBezierPath(roundedRect: NSRect(x: 66, y: 70, width: 892, height: 892),
                             xRadius: 206, yRadius: 206)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 24
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.27)
    shadow.set()
    color(0xCBD1DB).setFill()
    outer.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0xFCFCFD), color(0xDCE2EA), color(0xB5BDC9)])!
        .draw(in: outer, angle: -90)

    let inner = NSBezierPath(roundedRect: NSRect(x: 76, y: 80, width: 872, height: 872),
                             xRadius: 198, yRadius: 198)
    NSColor.white.withAlphaComponent(0.72).setStroke()
    inner.lineWidth = 6
    inner.stroke()

    let palette: [(UInt32, UInt32)] = [
        (0x65CBF8, 0x0785EC), (0xF58BB0, 0xE34371), (0xFFCC68, 0xEF7B32),
        (0xA58BF1, 0x7351CA), (0x75D892, 0x31AA68), (0x6CDBE5, 0x2BA8BB),
        (0xFA766E, 0xE84242), (0xFFDC68, 0xEDAC35), (0x91ADEB, 0x496EBC)
    ]
    for row in 0..<3 {
        for column in 0..<3 {
            let x = 202 + CGFloat(column) * 219
            let y = 638 - CGFloat(row) * 219
            let rect = NSRect(x: x, y: y, width: 182, height: 182)
            let tile = NSBezierPath(roundedRect: rect, xRadius: 43, yRadius: 43)
            NSGraphicsContext.saveGraphicsState()
            let tileShadow = NSShadow()
            tileShadow.shadowOffset = NSSize(width: 0, height: -5)
            tileShadow.shadowBlurRadius = 6
            tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
            tileShadow.set()
            color(palette[row * 3 + column].1).setFill()
            tile.fill()
            NSGraphicsContext.restoreGraphicsState()
            let colors = palette[row * 3 + column]
            NSGradient(starting: color(colors.0), ending: color(colors.1))!
                .draw(in: tile, angle: -90)
            let inset = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2),
                                     xRadius: 42, yRadius: 42)
            NSColor.white.withAlphaComponent(0.24).setStroke()
            inset.lineWidth = 2
            inset.stroke()
        }
    }
}

for (filename, pixels) in variants {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                  pixelsHigh: pixels, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    drawIcon()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!
        .write(to: outputDirectory.appendingPathComponent(filename))
}
