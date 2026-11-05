import XCTest
@testable import OrbitextWatch

final class VoiceWaveformTests: XCTestCase {
    func testDecodeEmptyReturnsEmpty() {
        XCTAssertTrue(TDLibService.decodeTelegramWaveform(Data()).isEmpty)
    }

    func testDecodePeakCountIsBitsDividedByFive() {
        // 8 bytes = 64 bits / 5 = 12 samples (4 bits remainder ignored).
        let eight = Data(repeating: 0xFF, count: 8)
        XCTAssertEqual(TDLibService.decodeTelegramWaveform(eight).count, 12)
        // 63 bytes = 504 bits / 5 = 100 samples (typical Telegram size).
        let sixtyThree = Data(repeating: 0xFF, count: 63)
        XCTAssertEqual(TDLibService.decodeTelegramWaveform(sixtyThree).count, 100)
    }

    func testDecodeAllOnesGivesMaxPeaks() {
        // Every 5-bit sample of 0xFF...FF is 0b11111 = 31.
        let data = Data(repeating: 0xFF, count: 16)
        let peaks = TDLibService.decodeTelegramWaveform(data)
        XCTAssertFalse(peaks.isEmpty)
        XCTAssertTrue(peaks.allSatisfy { $0 == 31 })
    }

    func testDecodeAllZerosGivesZeroPeaks() {
        let data = Data(repeating: 0x00, count: 16)
        let peaks = TDLibService.decodeTelegramWaveform(data)
        XCTAssertFalse(peaks.isEmpty)
        XCTAssertTrue(peaks.allSatisfy { $0 == 0 })
    }

    func testDecodeSingleByteFirstSampleIsTopFiveBits() {
        // 0xDE = 0b11011110 -> first 5 MSB bits = 0b11011 = 27.
        // Second sample reads from beyond the buffer (treated as 0):
        // 0b110_00000 -> 0b11000 = 24.
        let peaks = TDLibService.decodeTelegramWaveform(Data([0xDE]))
        XCTAssertEqual(peaks.count, 1) // only 8 bits / 5 = 1 full sample
        XCTAssertEqual(peaks[0], 27)
    }

    func testDecodeKnownTwoBytePattern() {
        // 0xDE 0xAD = 0b1101_1110 1010_1101
        // sample0 bits 0-4   = 11011 = 27
        // sample1 bits 5-9   = 11010 = 26
        // sample2 bits 10-14 = 10110 = 22
        let peaks = TDLibService.decodeTelegramWaveform(Data([0xDE, 0xAD]))
        XCTAssertEqual(peaks.count, 3) // 16 bits / 5 = 3
        XCTAssertEqual(peaks[0], 27)
        XCTAssertEqual(peaks[1], 26)
        XCTAssertEqual(peaks[2], 22)
    }

    func testParserExtractsWaveformWhenPresent() {
        let raw = Data([0xFF, 0xFF])
        let content: [String: Any] = [
            "@type": "messageVoiceNote",
            "voice_note": [
                "duration": 7,
                "voice": ["id": 42] as [String: Any],
                "waveform": raw
            ] as [String: Any]
        ]
        let parsed = MessageContent.parsed(content)
        guard case .voice(let duration, let fileId, let waveform) = parsed else {
            return XCTFail("Expected .voice, got \(parsed)")
        }
        XCTAssertEqual(duration, 7)
        XCTAssertEqual(fileId, "42")
        XCTAssertEqual(waveform, [31, 31, 31])
    }
}
