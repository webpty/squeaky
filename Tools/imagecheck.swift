// Opens a photo the way Finder and Photos do, decodes it, and prints what the
// system sees: whether it opened, its size, and the location it reads.
//
//   imagecheck <file>
import Foundation
import ImageIO

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path) as CFURL

guard let source = CGImageSourceCreateWithURL(url, nil) else {
    print("opens=no")
    exit(1)
}
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

func value(_ key: CFString) -> String {
    gps[key].map { "\($0)" } ?? "-"
}

print([
    "opens=\(image == nil ? "no" : "yes")",
    "size=\(image.map { "\($0.width)x\($0.height)" } ?? "-")",
    "lat=\(value(kCGImagePropertyGPSLatitude))\(value(kCGImagePropertyGPSLatitudeRef))",
    "lon=\(value(kCGImagePropertyGPSLongitude))\(value(kCGImagePropertyGPSLongitudeRef))",
    "alt=\(value(kCGImagePropertyGPSAltitude))",
    "gpsdate=\(value(kCGImagePropertyGPSDateStamp))",
    "gpstime=\(value(kCGImagePropertyGPSTimeStamp))",
].joined(separator: " "))
exit(image == nil ? 1 : 0)
