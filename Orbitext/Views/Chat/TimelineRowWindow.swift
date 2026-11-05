import SwiftUI

/// Whether a row of the eager chat timeline is drawn, and what it knows
/// about being on screen.
///
/// The timeline keeps every loaded row in the view tree, and a drawn row
/// keeps its text bitmaps and view graph for as long as the chat is open:
/// about 2 MB for a long bot message, which got a long chat killed for
/// memory while scrolling. A row that stayed off screen for a while is
/// replaced by a clear placeholder of its measured height, so the layout
/// and the scroll position stay exactly as they were, and is drawn again as
/// soon as any part of it is back on screen.
struct TimelineRowWindowState: Equatable {
    private(set) var visibility = MediaVisibilityState()
    private(set) var height: CGFloat?
    private(set) var isReleased = false

    /// Media inside the row loads only while the row is on screen.
    var isMediaWanted: Bool { visibility.isOnScreen }

    /// Whether the release countdown should run: the scroll view said the
    /// row is off screen and its height is known. A row the scroll view never
    /// reported stays drawn; so does one that was never measured.
    var canRelease: Bool {
        visibility.hasReported && !visibility.isOnScreen && !isReleased && height != nil
    }

    /// What the release countdown restarts on.
    var releaseKey: ReleaseKey { ReleaseKey(isOnScreen: visibility.isOnScreen, canRelease: canRelease) }

    struct ReleaseKey: Equatable {
        let isOnScreen: Bool
        let canRelease: Bool
    }

    mutating func report(_ visible: Bool) {
        visibility.report(visible)
        if visible { isReleased = false }
    }

    mutating func reportingTimedOut() {
        visibility.reportingTimedOut()
    }

    /// The drawn row's height. A placeholder keeps the last one.
    mutating func measured(_ height: CGFloat) {
        guard !isReleased, height > 0 else { return }
        self.height = height
    }

    /// The countdown ended with the row still off screen.
    mutating func releaseIfOffScreen() {
        guard canRelease else { return }
        isReleased = true
    }

    /// The message changed while its row was released: draw it again so the
    /// placeholder takes the new height. The countdown releases it again.
    mutating func contentChanged() {
        isReleased = false
    }
}

enum TimelineRowWindowTiming {
    /// How long a row stays drawn after leaving the screen, so scrolling a
    /// little back and forth does not redraw it.
    static let releaseDelay = Duration.seconds(3)
}

/// A row of the chat timeline that is drawn only while it is on screen or
/// was there a moment ago. Visibility trackers that must hear every change,
/// such as read receipts, go on this view rather than inside `content`:
/// content drawn again in place may not report its first transition.
struct TimelineRowWindow<Value: Equatable, Content: View>: View {
    let value: Value
    var releaseDelay = TimelineRowWindowTiming.releaseDelay
    var reportingGrace = MediaVisibility.reportingGrace
    /// Always true in the app. A test turns it off to stand for a scroll
    /// view that says nothing about the row, which a render cannot produce.
    var hearsScrollView = true
    @ViewBuilder let content: Content

    @State private var state = TimelineRowWindowState()

    var body: some View {
        let state = $state
        let releaseDelay = releaseDelay
        let reportingGrace = reportingGrace
        let hearsScrollView = hearsScrollView
        Group {
            if state.wrappedValue.isReleased, let height = state.wrappedValue.height {
                Color.clear.frame(height: height)
            } else {
                content
                    .environment(\.isMediaWanted, state.wrappedValue.isMediaWanted)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        state.wrappedValue.measured(height)
                    }
            }
        }
        // Any visible part counts: a tall album half on screen is on screen,
        // and a row coming back must be drawn before it is seen blank.
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            guard hearsScrollView else { return }
            state.wrappedValue.report(visible)
        }
        .task {
            try? await Task.sleep(for: reportingGrace)
            guard !Task.isCancelled else { return }
            state.wrappedValue.reportingTimedOut()
        }
        .task(id: state.wrappedValue.releaseKey) {
            guard state.wrappedValue.canRelease else { return }
            try? await Task.sleep(for: releaseDelay)
            guard !Task.isCancelled else { return }
            state.wrappedValue.releaseIfOffScreen()
        }
        .onChange(of: value) {
            state.wrappedValue.contentChanged()
        }
    }
}
