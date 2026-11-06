#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Files for demo mode, made on the spot: a drawn photo, silent audio and a
/// voice waveform, so no picture or recording has to ship with the app.
enum DemoMedia {
    static let photoFileId = "demo-photo-ridge"
    static let voiceFileId = "demo-voice-note"
    static let voiceDuration = 14

    /// The bytes the demo transport serves for a file id, nil for an unknown one.
    static func data(forFileId fileId: String) -> Data? {
        if fileId.hasPrefix("demo-photo") { return ridgePNG() }
        if fileId.hasPrefix("demo-voice") { return silentWAV(seconds: voiceDuration) }
        return nil
    }

    /// Peaks on TDLib's 0...31 scale, a smooth speech-like pattern.
    static func waveform(count: Int = 48, seed: Int = 0) -> [UInt8] {
        (0..<count).map { index in
            let t = Double(index + seed * 7)
            let level = 0.5 + 0.28 * sin(t * 0.55) + 0.17 * sin(t * 1.37 + 1.3)
            return UInt8(max(2, min(31, (level * 31).rounded())))
        }
    }

    /// Mono 8-bit PCM silence: a valid file for the audio player.
    static func silentWAV(seconds: Int, sampleRate: Int = 8000) -> Data {
        let sampleCount = max(seconds, 1) * sampleRate
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36 + sampleCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt16(8))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: UInt32(sampleCount))
        data.append(Data(repeating: 0x80, count: sampleCount))
        return data
    }

    /// A sunrise over two ridges, drawn with Core Graphics.
    static func ridgePNG(width: Int = 480, height: Int = 360) -> Data? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let w = CGFloat(width)
        let h = CGFloat(height)
        let skyColors = [rgb(0.99, 0.76, 0.54), rgb(0.27, 0.40, 0.76)] as CFArray
        if let sky = CGGradient(colorsSpace: space, colors: skyColors, locations: [0, 1]) {
            context.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        }
        context.setFillColor(rgb(1.0, 0.94, 0.74))
        context.fillEllipse(in: CGRect(x: w * 0.60, y: h * 0.42, width: h * 0.24, height: h * 0.24))
        fillRidge(context, color: rgb(0.47, 0.44, 0.64), width: w, height: h,
                  peaks: [(0, 0.38), (0.2, 0.62), (0.36, 0.45), (0.58, 0.70), (0.8, 0.44), (1, 0.56)])
        fillRidge(context, color: rgb(0.20, 0.27, 0.40), width: w, height: h,
                  peaks: [(0, 0.22), (0.25, 0.40), (0.5, 0.26), (0.75, 0.42), (1, 0.24)])
        guard let image = context.makeImage() else { return nil }
        return encodePNG(image)
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: 1)
    }

    /// Fills the area under a polyline whose points are fractions of the canvas.
    private static func fillRidge(
        _ context: CGContext, color: CGColor, width: CGFloat, height: CGFloat, peaks: [(CGFloat, CGFloat)]
    ) {
        let path = CGMutablePath()
        path.move(to: .zero)
        for (x, y) in peaks {
            path.addLine(to: CGPoint(x: x * width, y: y * height))
        }
        path.addLine(to: CGPoint(x: width, y: 0))
        path.closeSubpath()
        context.setFillColor(color)
        context.addPath(path)
        context.fillPath()
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private extension Data {
    mutating func append(littleEndian value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
#endif
