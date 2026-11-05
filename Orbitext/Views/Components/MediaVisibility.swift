import SwiftUI

private struct MediaWantedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the media views below should load. A list builds only the rows
    /// on screen and keeps the default; the eager chat timeline builds every
    /// row, so `TimelineRowWindow` sets this from the row's visibility. Media
    /// that is not wanted downloads nothing, and a download that is running
    /// stops when the media stops being wanted.
    var isMediaWanted: Bool {
        get { self[MediaWantedKey.self] }
        set { self[MediaWantedKey.self] = newValue }
    }
}

/// What a timeline row knows about being on screen. The scroll view says so
/// through `onScrollVisibilityChange`; if it never says anything, the row
/// is taken to be on screen once the scroll view has had time to.
struct MediaVisibilityState: Equatable {
    private(set) var isOnScreen = false
    private(set) var hasReported = false

    /// The scroll view reported the row's visibility.
    mutating func report(_ visible: Bool) {
        hasReported = true
        isOnScreen = visible
    }

    /// The scroll view had its time to report. A row it said nothing about
    /// loads, slowly, instead of staying without its media until the user
    /// scrolls it out of the viewport and back. The project has seen the
    /// callback skip the first transition of a view inserted after the
    /// scroll view was built, and a watch is the only place to say whether
    /// the rows of a chat can be hit by that.
    mutating func reportingTimedOut() {
        guard !hasReported else { return }
        isOnScreen = true
    }
}

enum MediaVisibility {
    /// How long a row waits for the scroll view to report before it is taken
    /// to be on screen. Far above the time a first layout takes, so a row
    /// outside the viewport that is still waiting for its report does not
    /// start a download it would cancel at once.
    static let reportingGrace = Duration.seconds(2)
}

/// What a media view's load task is keyed on: the task runs again when the
/// file changes, a retry is asked for, or the media stops or starts being
/// wanted. A retry belongs to the task, so it ends with the view instead of
/// downloading for nobody; so does the download of media that is no longer
/// wanted, which the cache stops once its last waiting task has gone.
struct MediaLoadID: Hashable {
    let fileId: String
    var attempt = 0
    /// Whether anyone looks at the media now. A task with nothing wanted
    /// loads nothing.
    var isWanted = true
}
