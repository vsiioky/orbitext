import XCTest
@testable import OrbitextWatch

final class MediaViewerModeTests: XCTestCase {
    func testViewerNeverHidesTheNavigationBarWithoutDrawingItsOwnBackButton() {
        for mode in [MediaViewerMode.photo, .video] where mode.hidesNavigationBar {
            XCTAssertTrue(mode.drawsOwnBackButton, "\(mode) hides the system bar and leaves no way out of the viewer")
        }
    }

    func testVideoTakesOverTheChromeWhilePhotosKeepTheSystemBar() {
        XCTAssertTrue(MediaViewerMode.video.hidesNavigationBar)
        XCTAssertTrue(MediaViewerMode.video.drawsOwnBackButton)
        XCTAssertFalse(MediaViewerMode.photo.hidesNavigationBar)
        XCTAssertFalse(MediaViewerMode.photo.drawsOwnBackButton, "Photos would show two back buttons")
    }
}
