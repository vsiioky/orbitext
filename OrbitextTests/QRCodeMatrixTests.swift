import XCTest
@testable import OrbitextWatch

final class QRCodeMatrixTests: XCTestCase {
    func testEncodeProducesSquareMatrixForText() throws {
        let matrix = try QRCodeMatrix.encode(text: "tg://login?token=test-token")

        XCTAssertEqual(matrix.text, "tg://login?token=test-token")
        XCTAssertGreaterThan(matrix.size, 0)
        XCTAssertEqual(matrix.modules.count, matrix.size)
        XCTAssertTrue(matrix.modules.allSatisfy { $0.count == matrix.size })
    }

    func testEncodeIsDeterministicForSameText() throws {
        let first = try QRCodeMatrix.encode(text: "tg://login?token=stable")
        let second = try QRCodeMatrix.encode(text: "tg://login?token=stable")

        XCTAssertEqual(first, second)
    }

    func testEncodeHandlesNonASCIIDigitsWithoutNumericModeCrash() throws {
        let matrix = try QRCodeMatrix.encode(text: "١٢٣٤")

        XCTAssertEqual(matrix.text, "١٢٣٤")
        XCTAssertGreaterThan(matrix.size, 0)
        XCTAssertEqual(matrix.modules.count, matrix.size)
    }

    func testEncodeRejectsTextThatDoesNotFitQRCodeCapacity() {
        let oversizedText = String(repeating: "a", count: 3_000)

        XCTAssertThrowsError(try QRCodeMatrix.encode(text: oversizedText))
    }
}
