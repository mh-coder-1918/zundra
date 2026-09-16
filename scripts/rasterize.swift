import AppKit

// args: input.svg output.png sizePx
let a = CommandLine.arguments
guard a.count == 4, let px = Int(a[3]) else { fputs("usage: rasterize in.svg out.png sizePx\n", stderr); exit(2) }
let inURL = URL(fileURLWithPath: a[1])
let outURL = URL(fileURLWithPath: a[2])
guard let svg = NSImage(contentsOf: inURL) else { fputs("failed to load SVG\n", stderr); exit(1) }

let size = NSSize(width: px, height: px)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.set()
NSRect(origin: .zero, size: size).fill()
svg.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { fputs("png encode failed\n", stderr); exit(1) }
try! data.write(to: outURL)
print("wrote \(outURL.path) (\(px)x\(px))")
