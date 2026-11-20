import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The photo behind the sidebar (0.23.0, David, 5 November 2026): one per
/// card inserted, the newest upright JPEG on it, else the newest JPEG. Kept
/// as a small copy of Squeaky's own, so it stays until the next card.
public enum SidebarPhoto {
    /// JPEGs looked at for an upright one, newest first, before settling.
    static let looked = 200
    /// The copy's longest side, in pixels.
    static let longest = 1600

    public static func isJPEG(_ url: URL) -> Bool {
        ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
    }

    /// Taller than wide as shown, the camera's turn taken into account; nil
    /// when it cannot be read.
    public static func upright(_ url: URL) -> Bool? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let turned = ((p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
        return turned ? w > h : h > w
    }

    public static func choose(_ photos: [ScannedPhoto], upright: (URL) -> Bool? = SidebarPhoto.upright) -> URL? {
        let jpegs = photos.filter { isJPEG($0.url) }
            .sorted { (Moments.clockReading($0) ?? .distantPast) > (Moments.clockReading($1) ?? .distantPast) }
        return jpegs.prefix(looked).first { upright($0.url) == true }?.url ?? jpegs.first?.url
    }

    /// A small copy of the photo, turned the right way up, written over the last.
    public static func keep(_ photo: URL, at file: URL) throws {
        guard let source = CGImageSourceCreateWithURL(photo as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: longest,
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw CocoaError(.fileWriteUnknown) }
        try (data as Data).write(to: file, options: .atomic)
    }
}
