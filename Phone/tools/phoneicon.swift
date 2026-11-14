// Geotag's icon for the iPhone: Resources/AppIcon.svg drawn edge to edge on
// black, 1024 pixels, with no transparency (the phone rounds the corners).
//
//   phoneicon <svg> <png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let art = NSImage(contentsOf: URL(fileURLWithPath: args[1])),
      let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    print("usage: phoneicon <svg> <png>")
    exit(2)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let all = NSRect(x: 0, y: 0, width: 1024, height: 1024)
NSColor.black.setFill()
all.fill()
art.draw(in: all, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let image = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
