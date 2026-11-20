// The watch's launcher icon: tools/icon.svg (Squeaky's pin, plain colour, larger) at the size the watch asks for.
//   swift tools/watchicon.swift tools/icon.svg resources/drawables/launcher.png 65
import AppKit
let a = CommandLine.arguments
let size = Int(a[3])!
guard let art = NSImage(contentsOf: URL(fileURLWithPath: a[1])),
      let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
// On black, with no transparency (Watch 0.2.9): a try at the watch showing it instead of Garmin's IQ icon.
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
art.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: a[2]))
