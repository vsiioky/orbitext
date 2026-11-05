import MapKit
import SwiftUI

struct LocationMessageView: View {
    let latitude: Double
    let longitude: Double
    let livePeriod: Int?
    var venueTitle: String?
    var venueAddress: String?
    var venueType: String?

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var camera: MapCamera {
        MapCamera(centerCoordinate: coordinate, distance: 800, heading: 0, pitch: 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Map(position: .constant(.camera(camera)), interactionModes: []) {
                Marker(venueTitle ?? "", systemImage: venueIcon, coordinate: coordinate)
                    .tint(venueTint)
            }
            .mapStyle(.hybrid(pointsOfInterest: .excludingAll))
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .allowsHitTesting(false)

            if let title = venueTitle, !title.isEmpty {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
            }
            if let addr = venueAddress, !addr.isEmpty {
                Text(addr)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if livePeriod != nil {
                Label(L10n.string("Live"), systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    var venueIcon: String {
        Self.icon(for: venueType)
    }

    var venueTint: Color {
        Self.tint(for: venueType)
    }

    nonisolated static func icon(for venueType: String?) -> String {
        guard let t = venueType?.lowercased(), !t.isEmpty else { return "mappin.circle.fill" }
        if t.contains("museum") || t.contains("arts") { return "building.columns.fill" }
        if t.contains("travel") || t.contains("hotel") || t.contains("lodging") { return "bed.double.fill" }
        if t.contains("food") || t.contains("restaurant") || t.contains("cafe") { return "fork.knife" }
        if t.contains("park") || t.contains("outdoor") { return "tree.fill" }
        if t.contains("shop") || t.contains("store") { return "bag.fill" }
        if t.contains("transport") || t.contains("station") { return "tram.fill" }
        return "mappin.circle.fill"
    }

    static func tint(for venueType: String?) -> Color {
        guard let t = venueType?.lowercased(), !t.isEmpty else { return .red }
        if t.contains("museum") { return .pink }
        if t.contains("travel") { return .purple }
        if t.contains("food") { return .orange }
        if t.contains("park") { return .green }
        if t.contains("shop") { return .yellow }
        return .red
    }
}
