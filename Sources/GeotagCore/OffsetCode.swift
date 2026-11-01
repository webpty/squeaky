import CoreImage
import Foundation
import ImageIO
import Vision

/// The offset code: Geotag's clock screen shows the exact time as a square
/// code that changes with every frame the screen draws. A camera photographs it, and the
/// difference between the code's time and the camera's own reading is its
/// clock offset, to the hundredth (David, 1 November 2026).
public enum OffsetCode {
    static let prefix = "geotag-clock:"

    /// What the code holds: the moment, in milliseconds since 1970, UTC.
    public static func payload(_ moment: Date) -> String {
        prefix + String(Int64((moment.timeIntervalSince1970 * 1000).rounded()))
    }

    public static func moment(_ payload: String) -> Date? {
        guard payload.hasPrefix(prefix), let ms = Int64(payload.dropFirst(prefix.count)) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    static let context = CIContext()

    /// The code as a picture, `scale` pixels to a square with hard edges:
    /// scaled up afterwards, it blurred.
    public static func image(_ moment: Date, scale: CGFloat = 16) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload(moment).utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return context.createCGImage(output, from: output.extent.integral)
    }

    /// The moment held by an offset code in this photo, or nil when it shows
    /// none. Raw files are read from the picture the Mac makes of them.
    public static func find(in url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3000,
              ] as CFDictionary) else { return nil }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: picture).perform([request])
        for found in request.results ?? [] {
            if let text = found.payloadStringValue, let moment = moment(text) { return moment }
        }
        return nil
    }
}

/// One offset code photo: when it was taken, by the code, and how far the
/// camera's clock was ahead then, to the hundredth.
public struct ClockReading: Codable, Equatable, Sendable {
    public var at: Date
    public var offset: Double

    public init(at: Date, offset: Double) {
        self.at = at
        self.offset = offset
    }
}

public enum Drift {
    /// Seconds a day the clock gains (negative: loses), fitted through every
    /// reading; nil with fewer than two readings an hour or more apart.
    public static func perDay(_ readings: [ClockReading]) -> Double? {
        guard readings.count >= 2, let first = readings.first?.at, let last = readings.last?.at,
              last.timeIntervalSince(first) >= 3600 else { return nil }
        let xs = readings.map { $0.at.timeIntervalSince(first) / 86_400 }
        let ys = readings.map(\.offset)
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let sxx = zip(xs, xs).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        return zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / sxx
    }

    /// The offset at a moment: between two readings, in proportion; after
    /// the last, the last plus the drift since; before the first, the first.
    public static func offset(at moment: Date, readings: [ClockReading]) -> Double? {
        let sorted = readings.sorted { $0.at < $1.at }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if moment <= first.at { return first.offset }
        if moment >= last.at {
            let days = moment.timeIntervalSince(last.at) / 86_400
            return last.offset + (perDay(sorted) ?? 0) * days
        }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.at <= moment && moment <= b.at {
            let span = b.at.timeIntervalSince(a.at)
            guard span > 0 else { return b.offset }
            return a.offset + (b.offset - a.offset) * moment.timeIntervalSince(a.at) / span
        }
        return last.offset
    }
}
