import Foundation

/// A single location fix selected for an explicit send; never a live location.
struct SharedLocation: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && horizontalAccuracy.isFinite
            && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
            && horizontalAccuracy >= 0
    }
}
