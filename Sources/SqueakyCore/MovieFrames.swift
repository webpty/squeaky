import AVFoundation
import Foundation
import ImageIO

/// A video's picture and length, the same on the phone and the Mac (0.33.0).
public enum MovieFrames {
    /// A frame from the start of the video; for a RAW video, which neither the
    /// phone nor the Mac can play, the picture Canon keeps inside it.
    public static func picture(_ url: URL, maxPixel: Int) -> CGImage? {
        if !PhotoKinds.isRawVideo(url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            if let image = try? generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil) {
                return image
            }
        }
        guard let data = NativeMetadata.moviePreview(url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    /// "10:07", or "1:02:07" past an hour.
    public static func length(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
