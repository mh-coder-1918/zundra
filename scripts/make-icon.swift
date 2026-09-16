import AppKit

// Composes the app icon from the brain glyph and writes an .icns.
//
//   swift scripts/make-icon.swift Resources/brain.svg Resources/AppIcon.icns
//
// This is a *different* image from the menu-bar glyph. MenuIconTemplate.png is
// a template — macOS throws away its colour and tints it for light/dark. An app
// icon is the opposite: it is never tinted, it has to carry its own colour, and
// it is seen in Finder, the DMG window, the Dock, Sparkle's update dialog and
// every "an app downloaded from the internet" prompt. Without one, all of those
// show the generic blank page.
//
// Needs `iconutil`, which ships with the Command Line Tools.

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("usage: make-icon in.svg out.icns\n", stderr)
    exit(2)
}
let svgURL = URL(fileURLWithPath: args[1])
let icnsURL = URL(fileURLWithPath: args[2])

guard let glyph = NSImage(contentsOf: svgURL) else {
    fputs("failed to load \(svgURL.path)\n", stderr)
    exit(1)
}

// Big Sur onwards, a macOS icon is a rounded square floating in a transparent
// canvas rather than filling it: 824pt of art on a 1024pt grid, corner radius
// 185. Everything below is expressed as a fraction of the canvas so each size
// renders from the same geometry rather than from a scaled bitmap.
let bodyInset: CGFloat = 100.0 / 1024.0
let cornerRadius: CGFloat = 185.0 / 1024.0
let glyphWidth: CGFloat = 0.58

// The identity's app artwork: a flat hot-pink field with the glyph in near-black
// (Pink Noise edition 02 — #FF3D95 on #171217). Flat rather than a gradient
// because the identity is flat colour and print-like texture, and because a
// gradient is the first thing to turn to mud at 16pt. Ink rather than white on
// the field: white on this pink is 3.3:1, which the kit reserves for decoration.
let field = NSColor(srgbRed: 1.0, green: 0.239, blue: 0.584, alpha: 1)
let glyphInk = NSColor(srgbRed: 0.090, green: 0.071, blue: 0.090, alpha: 1)

/// Re-inks the glyph into its own transparent canvas.
///
/// The asset is a *white* outline, because the same file is the source of the
/// menu-bar template. A colour can't simply be laid over it in the icon canvas
/// — `.sourceAtop` there would paint the whole opaque pink body — so the glyph
/// is coloured on its own first and the result is what gets composited.
func inked(_ image: NSImage, _ color: NSColor, side: CGFloat) -> NSImage {
    let out = NSImage(size: NSSize(width: side, height: side))
    out.lockFocus()
    let box = NSRect(x: 0, y: 0, width: side, height: side)
    image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
    color.set()
    box.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func render(_ px: Int) -> NSBitmapImageRep {
    let side = CGFloat(px)
    // Coloured before the icon's own context is current: `lockFocus` inside it
    // would fight over the current graphics context.
    let art = inked(glyph, glyphInk, side: side * glyphWidth)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: side, height: side).fill()

    let inset = side * bodyInset
    let body = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = side * cornerRadius
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    shape.addClip()
    field.setFill()
    body.fill()

    // At 16pt the glyph's strokes are barely over a pixel wide — legible, and
    // helped by the flat field behind them, but this is still the honest limit
    // of a line-art glyph at icon sizes. The menu-bar artwork is a separate
    // template image and stays one: nothing here is applied to it.
    let w = side * glyphWidth
    let box = NSRect(x: (side - w) / 2, y: (side - w) / 2, width: w, height: w)
    art.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// iconutil reads a directory of exactly these names.
let slices: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for slice in slices {
    guard let data = render(slice.px).representation(using: .png, properties: [:]) else {
        fputs("png encode failed for \(slice.name)\n", stderr)
        exit(1)
    }
    try! data.write(to: iconset.appendingPathComponent(slice.name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("iconutil failed (\(iconutil.terminationStatus))\n", stderr)
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)
print("wrote \(icnsURL.path)")
