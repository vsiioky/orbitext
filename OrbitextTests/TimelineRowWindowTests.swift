import SwiftUI
import XCTest
@testable import OrbitextWatch

/// Rows of the eager chat timeline are drawn only near the screen, so a long
/// chat does not keep every message's bitmaps and view graph alive.
@MainActor
final class TimelineRowWindowTests: XCTestCase {
    // MARK: - State

    func testRowReportedOffScreenIsReleasedWhenTheCountdownEnds() {
        var state = TimelineRowWindowState()
        state.measured(120)
        state.report(false)

        XCTAssertTrue(state.canRelease)
        state.releaseIfOffScreen()

        XCTAssertTrue(state.isReleased)
        XCTAssertEqual(state.height, 120, "The placeholder keeps the row's height")
    }

    func testRowTheScrollViewNeverReportedStaysDrawn() {
        var state = TimelineRowWindowState()
        state.measured(120)
        state.reportingTimedOut()

        state.releaseIfOffScreen()

        XCTAssertFalse(state.isReleased, "Nothing says the row left the screen")
    }

    func testRowThatWasNeverMeasuredStaysDrawn() {
        var state = TimelineRowWindowState()
        state.report(false)

        state.releaseIfOffScreen()

        XCTAssertFalse(state.isReleased, "A placeholder without a height would move the rows below")
    }

    func testRowOnScreenIsNotReleased() {
        var state = TimelineRowWindowState()
        state.measured(120)
        state.report(true)

        state.releaseIfOffScreen()

        XCTAssertFalse(state.isReleased)
    }

    func testReleasedRowIsDrawnAgainWhenItComesBack() {
        var state = TimelineRowWindowState()
        state.measured(120)
        state.report(false)
        state.releaseIfOffScreen()

        state.report(true)

        XCTAssertFalse(state.isReleased)
        XCTAssertTrue(state.isMediaWanted)
    }

    func testPlaceholderHeightIsNotTakenAsTheRowHeight() {
        var state = TimelineRowWindowState()
        state.measured(120)
        state.report(false)
        state.releaseIfOffScreen()

        state.measured(0)
        state.measured(30)

        XCTAssertEqual(state.height, 120)
    }

    func testChangedMessageIsDrawnToTakeItsNewHeight() {
        var state = TimelineRowWindowState()
        state.measured(120)
        state.report(false)
        state.releaseIfOffScreen()

        state.contentChanged()
        state.measured(160)

        XCTAssertFalse(state.isReleased)
        XCTAssertEqual(state.height, 160)
        XCTAssertTrue(state.canRelease, "Still off screen, so it is released again")
    }

    // MARK: - In a scroll view

    func testRowBelowTheViewportIsReplacedByAPlaceholderOfTheSameHeight() async throws {
        let probe = DrawProbe()
        let renderer = renderInScrollView(probe: probe, rowOffset: 800)

        try await waitUntil(redrawing: renderer) { probe.disappearances == 1 }

        XCTAssertFalse(probe.isDrawn)
        XCTAssertEqual(probe.contentHeights.last, 800 + DrawProbe.height, "The layout does not move")
        XCTAssertEqual(Set(probe.contentHeights), [800 + DrawProbe.height])
    }

    func testRowOnScreenStaysDrawn() async throws {
        let probe = DrawProbe()
        let renderer = renderInScrollView(probe: probe, rowOffset: 0)

        try await Task.sleep(for: .milliseconds(300))
        _ = renderer.cgImage

        XCTAssertTrue(probe.isDrawn)
        XCTAssertEqual(probe.disappearances, 0)
    }

    // MARK: - Helpers

    private func renderInScrollView(probe: DrawProbe, rowOffset: CGFloat) -> ImageRenderer<some View> {
        let renderer = ImageRenderer(content: ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: rowOffset)
                TimelineRowWindow(value: 0, releaseDelay: .milliseconds(50)) {
                    DrawnRow(probe: probe)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { probe.contentHeights.append($0) }
        }
        .frame(width: 184, height: 224))
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
}

@MainActor
private final class DrawProbe {
    static let height: CGFloat = 100
    var isDrawn = false
    var disappearances = 0
    var contentHeights: [CGFloat] = []
}

private struct DrawnRow: View {
    let probe: DrawProbe

    var body: some View {
        Color.red
            .frame(height: DrawProbe.height)
            .onAppear { probe.isDrawn = true }
            .onDisappear {
                probe.isDrawn = false
                probe.disappearances += 1
            }
    }
}

/// A long message shows a bounded number of lines until the user asks for
/// the rest: its rendered text is a bitmap of its whole height.
@MainActor
final class MessageTextCollapseTests: XCTestCase {
    func testLongMessageShowsABoundedNumberOfLines() async throws {
        let long = FormattedString(text: (1...200).map { "Line \($0)" }.joined(separator: "\n"))
        let short = FormattedString(text: "Hello")

        let collapsed = try await renderedHeight(MessageTextView(formatted: long, isOutgoing: false))
        let full = try await renderedHeight(Text(long.text).font(.caption2).fixedSize(horizontal: false, vertical: true))
        let oneLine = try await renderedHeight(MessageTextView(formatted: short, isOutgoing: false))

        XCTAssertLessThan(collapsed, oneLine * CGFloat(AppConstants.Message.collapsedLineLimit + 3),
                          "Twelve lines and the Show more button")
        XCTAssertLessThan(collapsed, full / 5)
    }

    func testShortMessageOffersNothingToExpand() {
        var heights = MessageTextHeights()
        heights.shown = 40
        heights.full = 40.3

        XCTAssertFalse(heights.isTruncated, "Rounding between the two layouts is not a cut")
        heights.full = 60
        XCTAssertTrue(heights.isTruncated)
    }

    /// Renders until the height settles: the Show more button appears only
    /// after the first layout measured the text.
    private func renderedHeight(_ view: some View) async throws -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: 160))
        renderer.scale = 1
        var last: CGFloat = -1
        for _ in 0..<10 {
            let height = CGFloat(renderer.cgImage?.height ?? 0)
            if height == last { return height }
            last = height
            try await Task.sleep(for: .milliseconds(20))
        }
        return last
    }
}
