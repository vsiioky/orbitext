import SwiftUI

/// Numeric keypad for phone-number entry. Shows the current digits with a
/// leading "+", a 3x4 keypad with digits, "+", and delete, plus the Next
/// action. Used instead of the system keyboard on watchOS.
struct PhoneKeypadView: View {
    @Environment(AuthManager.self) private var authManager
    @State private var phone = "+"

    private static let minDigits = 7
    private static let maxDigits = 15

    private var digitCount: Int {
        phone.filter(\.isNumber).count
    }

    private var isValid: Bool {
        digitCount >= Self.minDigits && digitCount <= Self.maxDigits
    }

    /// Slot 9 is .empty (visual placeholder): "+" is owned by state, not a
    /// tap action, so showing a key that does nothing is misleading.
    private let keys: [KeypadKey] = [
        .digit("1"), .digit("2"), .digit("3"),
        .digit("4"), .digit("5"), .digit("6"),
        .digit("7"), .digit("8"), .digit("9"),
        .empty, .digit("0"), .delete
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(phone)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(WristTheme.Palette.primaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(WristGlassBackground(cornerRadius: 18))
                    .accessibilityLabel(L10n.string("Phone number"))
                    .accessibilityValue(phone)

                Text(L10n.string("Include country code, e.g. +7..."))
                    .font(.caption2)
                    .foregroundStyle(WristTheme.Palette.secondaryText)
                    .multilineTextAlignment(.center)

                KeypadView(keys: keys, onKey: handleKey)

                Button(action: submit) {
                    if authManager.isLoading {
                        ProgressView()
                    } else {
                        Text(L10n.string("Next"))
                            .font(.headline)
                    }
                }
                .buttonStyle(WristGlassButtonStyle(tint: WristTheme.Palette.accent))
                .tint(WristTheme.Palette.accent)
                .disabled(!isValid || authManager.isLoading)
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .background { WristScreenBackground() }
    }

    private func handleKey(_ key: KeypadKey) {
        switch key {
        case .digit(let d):
            guard digitCount < Self.maxDigits else {
                HapticManager.error()
                return
            }
            phone.append(d)
        case .delete:
            // Keep the leading "+" pinned - state is "+<digits>" by invariant.
            if phone.count > 1 { phone.removeLast() }
        default:
            break
        }
    }

    private func submit() {
        guard isValid, !authManager.isLoading else { return }
        Task { await authManager.sendPhone(phone) }
    }
}
