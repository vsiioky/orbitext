import WatchKit

enum HapticManager {
    static func messageSent() {
        WKInterfaceDevice.current().play(.success)
    }

    static func error() {
        WKInterfaceDevice.current().play(.failure)
    }

    static func tap() {
        WKInterfaceDevice.current().play(.click)
    }

    static func reactionAdded() {
        WKInterfaceDevice.current().play(.directionUp)
    }

    static func recording() {
        WKInterfaceDevice.current().play(.start)
    }

    static func recordingStopped() {
        WKInterfaceDevice.current().play(.stop)
    }
}
