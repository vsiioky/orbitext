import SwiftUI

/// iOS stub. Apple's App Store Connect submission pipeline rejects
/// standalone watchOS .ipa packages - the watch app must be embedded
/// inside an iOS host bundle at Payload/<stub>.app/Watch/<watch>.app/.
/// This stub exists only to give Xcode something to put in Payload/.
/// SKIP_INSTALL is YES at the target level so this binary never
/// reaches a user device. The real product is Orbitext.app in Watch/.
@main
struct OrbitextStubApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Orbitext runs on Apple Watch.")
                .multilineTextAlignment(.center)
                .padding()
        }
    }
}
