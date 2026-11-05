import SwiftUI

struct TwoFactorView: View {
    @Environment(AuthManager.self) private var authManager
    let hint: String
    @State private var password = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(WristTheme.Palette.accent)
                    .frame(width: 52, height: 52)
                    .background(WristGlassBackground(cornerRadius: 26, tint: WristTheme.Palette.accent))

                Text(L10n.string("2FA Password"))
                    .font(.headline)

                if !hint.isEmpty {
                    Text(L10n.format("Hint: %@", hint))
                        .font(.caption2)
                        .foregroundStyle(WristTheme.Palette.secondaryText)
                }

                // Deliberate design choice: the 2FA password input is NOT
                // masked on watchOS. The screen is tiny, the keyboard
                // surfaces one character at a time, and SecureField gives
                // the user no chance to verify what they actually typed
                // before submitting. The shoulder-surfing surface on a
                // wrist-worn device is dramatically narrower than on
                // iPhone, so the usability gain wins here.
                TextField(L10n.string("Password"), text: $password)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .clipShape(Capsule())
                    .padding(10)
                    .background(WristGlassBackground(cornerRadius: 22))

                Button {
                    Task { await authManager.sendPassword(password) }
                } label: {
                    if authManager.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text(L10n.string("Submit"))
                    }
                }
                .buttonStyle(WristGlassButtonStyle(tint: WristTheme.Palette.accent))
                .disabled(password.isEmpty || authManager.isLoading)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background { WristScreenBackground() }
    }
}
