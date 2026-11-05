import SwiftUI

/// Numeric keypad for the Telegram login code. Displays one dot per
/// expected digit, fills them as the user types on the 3x4 keypad, and
/// auto-submits when the code reaches `AppConstants.Auth.codeLength`.
struct CodeKeypadView: View {
    @Environment(AuthManager.self) private var authManager
    @State private var code = ""
    @State private var lastSubmittedCode = ""

    private var codeLength: Int { AppConstants.Auth.codeLength }

    private let keys: [KeypadKey] = [
        .digit("1"), .digit("2"), .digit("3"),
        .digit("4"), .digit("5"), .digit("6"),
        .digit("7"), .digit("8"), .digit("9"),
        .empty, .digit("0"), .delete
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(L10n.string("Check your Telegram app"))
                    .font(.caption2)
                    .foregroundStyle(WristTheme.Palette.secondaryText)
                    .multilineTextAlignment(.center)

                indicator
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(WristGlassBackground(cornerRadius: 22))

                KeypadView(keys: keys, onKey: handleKey)

                if authManager.isLoading {
                    ProgressView()
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .background { WristScreenBackground() }
        .onChange(of: code) {
            if code.count == codeLength,
               code != lastSubmittedCode,
               !authManager.isLoading {
                submit()
            }
        }
    }

    private var indicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<codeLength, id: \.self) { idx in
                if idx < code.count {
                    let digit = code[code.index(code.startIndex, offsetBy: idx)]
                    Text(String(digit))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(WristTheme.Palette.primaryText)
                        .frame(minWidth: 12, minHeight: 18)
                } else {
                    Circle()
                        .fill(WristTheme.Palette.control)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(WristTheme.Palette.separator, lineWidth: 0.5)
                        )
                        .frame(minHeight: 18)
                }
            }
        }
        // Accessibility still reports progress only (no spoken digits) -
        // the screen is private to the wearer but VoiceOver audio is not.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Enter Code"))
        .accessibilityValue("\(code.count)/\(codeLength)")
    }

    private func handleKey(_ key: KeypadKey) {
        switch key {
        case .digit(let d):
            guard code.count < codeLength else {
                HapticManager.error()
                return
            }
            code.append(d)
        case .delete:
            if !code.isEmpty { code.removeLast() }
        default:
            break
        }
    }

    private func submit() {
        lastSubmittedCode = code
        Task { await authManager.sendCode(code) }
    }
}
