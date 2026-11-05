import XCTest
@testable import OrbitextWatch

/// The license texts the app shows in Settings -> Open-Source Licenses. The
/// notice terms of the bundled third-party code (MIT, BSD-3-Clause,
/// Apache-2.0, FTL, MPL-2.0) require them in the distributed binary, so they
/// are read from the packaged bundle.
final class LicenseDocumentTests: XCTestCase {
    func testEveryListedDocumentIsBundledAndReadable() throws {
        for document in LicenseDocument.all {
            let text = try XCTUnwrap(document.loadText(from: .main), "\(document.fileName) is not in the app bundle")
            XCTAssertFalse(text.isEmpty, "\(document.fileName) is empty")
        }
    }

    /// project.yml bundles LICENSES/ and the rlottie licenses as whole
    /// folders, so a license file added there lands in the bundle; it must
    /// also get a row on the screen.
    func testEveryBundledLicenseFileIsListed() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let names = try FileManager.default.contentsOfDirectory(atPath: resources.path)
        let licenseFiles = names.filter { $0.hasPrefix("COPYING.") || $0.hasSuffix(".txt") }
        let listed = Set(LicenseDocument.all.map(\.fileName))

        XCTAssertFalse(licenseFiles.isEmpty)
        for name in licenseFiles {
            XCTAssertTrue(listed.contains(name), "\(name) is bundled but has no row in LicenseDocument.all")
        }
    }

    func testDocumentIdentitiesAreUnique() {
        let ids = LicenseDocument.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testHardWrappedLinesJoinIntoOneParagraph() {
        let text = "Permission is hereby granted, free of charge,\nto any person obtaining a copy\n\nTHE SOFTWARE IS PROVIDED \"AS IS\""

        XCTAssertEqual(LicenseText.paragraphs(text), [
            LicenseParagraph(text: "Permission is hereby granted, free of charge, to any person obtaining a copy", isHeading: false),
            LicenseParagraph(text: "THE SOFTWARE IS PROVIDED \"AS IS\"", isHeading: false),
        ])
    }

    func testListItemsKeepTheirOwnLines() {
        let text = "- License: MIT\n- Copyright (c) 2020\n  Samsung Electronics\n1. Definitions.\n(a) first"

        XCTAssertEqual(LicenseText.paragraphs(text), [
            LicenseParagraph(
                text: "- License: MIT\n- Copyright (c) 2020 Samsung Electronics\n1. Definitions.\n(a) first",
                isHeading: false
            ),
        ])
    }

    func testMarkdownAndUnderlinedHeadingsBecomeHeadings() {
        let text = "# Third-Party Notices\n\n## rlottie - app\nbody\n\nMozilla Public License Version 2.0\n=================================="

        XCTAssertEqual(LicenseText.paragraphs(text), [
            LicenseParagraph(text: "Third-Party Notices", isHeading: true),
            LicenseParagraph(text: "rlottie - app", isHeading: true),
            LicenseParagraph(text: "body", isHeading: false),
            LicenseParagraph(text: "Mozilla Public License Version 2.0", isHeading: true),
        ])
    }

    func testAsteriskBoxIsUnwrapped() {
        let text = "****************\n*  6. Disclaimer of Warranty  *\n*  -----------  *\n*  Covered Software is provided  *\n*  on an \"as is\" basis  *\n****************"

        XCTAssertEqual(LicenseText.paragraphs(text), [
            LicenseParagraph(text: "6. Disclaimer of Warranty", isHeading: true),
            LicenseParagraph(text: "Covered Software is provided on an \"as is\" basis", isHeading: false),
        ])
    }

    func testCarriageReturnsAndTrailingSpacesAreIgnored() {
        XCTAssertEqual(LicenseText.paragraphs("a  \r\nb\r\n\r\n\r\n"), [
            LicenseParagraph(text: "a b", isHeading: false),
        ])
    }
}
