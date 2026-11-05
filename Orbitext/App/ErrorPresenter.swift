import Foundation
import Observation

@MainActor
@Observable
final class ErrorPresenter {
    var error: String?
    private var dismissTask: Task<Void, Never>?

    func show(_ error: any Error) {
        if let tdError = error as? TDError {
            if tdError.isSessionRevoked { return }
            if tdError.isFloodWait, let seconds = tdError.floodWaitSeconds {
                show("Please wait \(seconds)s", dismissAfter: min(seconds, 10))
                return
            }
        }
        show(error.localizedDescription, dismissAfter: 4)
    }

    func show(_ message: String, dismissAfter seconds: Int) {
        dismissTask?.cancel()
        self.error = message
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.error = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        error = nil
    }
}
