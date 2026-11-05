import SwiftUI
import XCTest
@testable import OrbitextWatch

/// Whether the media views of a row are told to load.
@MainActor
final class MediaVisibilityTests: XCTestCase {
    func testMediaOutsideTheTimelineIsWanted() {
        let probe = WantedProbe()

        render(WantedReader(probe: probe))

        XCTAssertEqual(probe.values, [true], "Lists build only the rows on screen")
    }

    func testRowIsNotWantedUntilItIsSeenOnScreen() {
        let probe = WantedProbe()

        render(TimelineRowWindow(value: 0) { WantedReader(probe: probe) })

        XCTAssertEqual(probe.values, [false, true])
    }

    /// Timeline rows are `.equatable()`: an unchanged message skips its body,
    /// but its media must still hear that the row came into view.
    func testVisibilityReachesMediaInsideAnEquatableRow() {
        let probe = WantedProbe()

        render(TimelineRowWindow(value: 1) { EquatableRow(id: 1, probe: probe).equatable() })

        XCTAssertEqual(probe.values, [false, true])
    }

    // MARK: - A row the scroll view never reports

    /// The scroll view is trusted to say when a row is on screen, but a row
    /// it never says anything about must not stay without its media for good.
    func testRowThatHasNotReportedIsNotWantedUntilTheGraceEnds() {
        var state = MediaVisibilityState()

        XCTAssertFalse(state.isOnScreen)
        state.reportingTimedOut()
        XCTAssertTrue(state.isOnScreen, "Slow is better than never")
    }

    func testRowThatReportedItselfOffScreenStaysOffScreenAfterTheGrace() {
        var state = MediaVisibilityState()

        state.report(false)
        state.reportingTimedOut()

        XCTAssertFalse(state.isOnScreen, "The scroll view said it is not there")
    }

    func testRowThatReportedItselfOnScreenStaysOnScreenAfterTheGrace() {
        var state = MediaVisibilityState()

        state.report(true)
        state.reportingTimedOut()

        XCTAssertTrue(state.isOnScreen)
    }

    func testLateReportOfARowThatTimedOutWins() {
        var state = MediaVisibilityState()
        state.reportingTimedOut()

        state.report(false)

        XCTAssertFalse(state.isOnScreen)
    }

    /// The row below hears nothing from the scroll view: the grace is the
    /// only thing that makes it wanted.
    func testRowTheScrollViewNeverReportsBecomesWantedWhenTheGraceEnds() async throws {
        let probe = WantedProbe()
        let renderer = renderInScrollView(
            TimelineRowWindow(value: 0, reportingGrace: .milliseconds(50), hearsScrollView: false) {
                WantedReader(probe: probe)
            }
        )

        try await waitUntil(redrawing: renderer) { probe.values.last == true }
        XCTAssertEqual(probe.values.first, false, "Not wanted before the grace")
    }

    func testRowTheScrollViewReportsOffScreenStaysUnwantedPastTheGrace() async throws {
        let probe = WantedProbe()
        let renderer = renderInScrollView(
            VStack(spacing: 0) {
                Color.clear.frame(height: 800)
                TimelineRowWindow(value: 0, reportingGrace: .milliseconds(50)) {
                    WantedReader(probe: probe)
                }
                .frame(height: 100)
            }
        )

        try await Task.sleep(for: .milliseconds(300))
        _ = renderer.cgImage

        XCTAssertFalse(probe.values.contains(true), "Reported as outside the viewport, so the grace has nothing to add")
    }

    private func renderInScrollView(_ content: some View) -> ImageRenderer<some View> {
        let renderer = ImageRenderer(content: ScrollView { content }.frame(width: 184, height: 224))
        renderer.scale = 1
        _ = renderer.cgImage
        return renderer
    }

    /// The renderer redraws only when asked to, so a wait for a change in the
    /// views has to ask on every turn.
    private func waitUntil(redrawing renderer: ImageRenderer<some View>, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for the condition") }
            _ = renderer.cgImage
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func render(_ view: some View) {
        let renderer = ImageRenderer(content: view.frame(width: 184, height: 224))
        renderer.scale = 1
        _ = renderer.cgImage
    }
}

@MainActor
private final class WantedProbe {
    var values: [Bool] = []
}

private struct WantedReader: View {
    let probe: WantedProbe
    @Environment(\.isMediaWanted) private var isWanted

    var body: some View {
        probe.values.append(isWanted)
        return Color.clear
    }
}

private struct EquatableRow: View, Equatable {
    let id: Int
    let probe: WantedProbe

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    var body: some View {
        WantedReader(probe: probe)
    }
}
