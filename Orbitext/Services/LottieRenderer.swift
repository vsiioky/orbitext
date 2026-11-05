import Foundation
import librlottie
import WatchKit
import zlib

/// Renders Lottie JSON (or TGS gzipped data) into UIImage frames using rlottie C API.
final class LottieRenderer {
    private static let maxTGSFileSize = 64 * 1024

    private let animation: OpaquePointer
    let frameCount: Int
    let frameRate: Double
    let duration: Double
    private let renderWidth: Int
    private let renderHeight: Int
    /// Reusable pixel buffer to avoid per-frame allocation
    private var buffer: [UInt32]

    /// Initialize from raw Lottie JSON string
    init?(json: String, width: Int = 128, height: Int = 128) {
        guard let anim = json.withCString({ cStr in
            lottie_animation_from_data(cStr, "", "")
        }) else { return nil }
        self.animation = anim
        self.frameCount = Int(lottie_animation_get_totalframe(anim))
        self.frameRate = lottie_animation_get_framerate(anim)
        self.duration = lottie_animation_get_duration(anim)
        self.renderWidth = width
        self.renderHeight = height
        self.buffer = [UInt32](repeating: 0, count: width * height)
    }

    /// Initialize from TGS data (gzipped Lottie JSON)
    convenience init?(tgsData: Data, width: Int = 128, height: Int = 128) {
        guard let json = Self.decodeTGSJSON(tgsData) else { return nil }
        self.init(json: json, width: width, height: height)
    }

    deinit {
        lottie_animation_destroy(animation)
    }

    /// Render a single frame as UIImage (reuses internal pixel buffer to avoid allocation per frame)
    func renderFrame(at index: Int) -> UIImage? {
        guard index >= 0, index < frameCount else { return nil }

        let bytesPerLine = renderWidth * 4
        buffer.withUnsafeMutableBufferPointer { ptr in
            lottie_animation_render(animation, index, ptr.baseAddress!, renderWidth, renderHeight, bytesPerLine)
        }

        // Copy buffer bytes into Data (buffer is reused across frames)
        let data = Data(bytes: &buffer, count: buffer.count * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: renderWidth,
                height: renderHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerLine,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Pre-render frames at the given step, checking for cancellation between frames.
    func renderFrames(step: Int, cancel: @escaping () -> Bool) -> [UIImage] {
        guard step > 0 else { return [] }

        var result: [UIImage] = []
        result.reserveCapacity(frameCount / step + 1)
        for i in stride(from: 0, to: frameCount, by: step) {
            if cancel() { break }
            if let frame = renderFrame(at: i) {
                result.append(frame)
            }
        }
        return result
    }

    // MARK: - TGS Decompression

    static func decodeTGSJSON(_ data: Data) -> String? {
        // TGS = gzip compressed Lottie JSON
        guard data.count > 2, data[0] == 0x1F, data[1] == 0x8B else {
            // Not gzipped - try as plain JSON
            return String(data: data, encoding: .utf8)
        }
        guard data.count <= maxTGSFileSize else { return nil }

        var output = Data()
        let status = data.withUnsafeBytes { rawBuffer -> Int32 in
            guard let input = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Z_STREAM_ERROR
            }
            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input)
            stream.avail_in = uInt(data.count)

            // 15 + 32 = auto-detect gzip or zlib
            guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                return Z_STREAM_ERROR
            }
            defer { inflateEnd(&stream) }

            let chunkSize = 16 * 1024
            var status: Int32 = Z_OK
            while status != Z_STREAM_END {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    status = inflate(&stream, Z_NO_FLUSH)

                    let produced = buffer.count - Int(stream.avail_out)
                    if produced > 0, let baseAddress = buffer.baseAddress {
                        output.append(baseAddress, count: produced)
                    }
                }

                if status != Z_OK && status != Z_STREAM_END {
                    return status
                }
            }
            return status
        }

        guard status == Z_STREAM_END else { return nil }
        return String(data: output, encoding: .utf8)
    }
}
