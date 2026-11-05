import Foundation

// MARK: - Voice waveform

extension TDLibService {
    /// Decode TDLib voice waveform: packed 5-bit unsigned samples, MSB
    /// first, big-endian within each byte. Each sample is in 0..31.
    /// E.g. 8 bytes -> 12 samples (64 bits / 5), 63 bytes -> 100
    /// samples (the typical Telegram value).
    static func decodeTelegramWaveform(_ data: Data) -> [UInt8] {
        var peaks: [UInt8] = []
        let totalBits = data.count * 8
        let sampleCount = totalBits / 5
        peaks.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let bitIndex = i * 5
            let byteIdx = bitIndex / 8
            let bitOff = bitIndex % 8
            let hi = UInt16(data[byteIdx]) << 8
            let lo: UInt16 = (byteIdx + 1 < data.count) ? UInt16(data[byteIdx + 1]) : 0
            let word = hi | lo
            let shifted = word >> (11 - bitOff)
            peaks.append(UInt8(shifted & 0x1F))
        }
        return peaks
    }
}
