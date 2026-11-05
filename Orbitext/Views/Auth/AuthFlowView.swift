import SwiftUI

enum AuthMethod {
    case none
    case qr
    case phone
}

struct AuthFlowView: View {
    @Environment(AppState.self) private var appState
    @Environment(AuthManager.self) private var authManager
    @State private var method: AuthMethod = .none
    @State private var isResetting = false
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        NavigationStack {
            Group {
                if isResetting {
                    LoadingPlaceholderView()
                } else {
                    authContent
                }
            }
            .toolbar {
                if showBackButton && !isResetting {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            resetAuthFlow()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel(L10n.string("Back"))
                    }
                }
            }
        }
        .id(appLanguage)
        .onAppear {
            L10n.useLanguage(rawValue: appLanguage)
        }
        .onChange(of: appLanguage) { _, newValue in
            L10n.useLanguage(rawValue: newValue)
        }
        .background { WristScreenBackground() }
    }

    @ViewBuilder
    private var authContent: some View {
        switch authManager.authState {
        case .waitOtherDeviceConfirmation:
            QRLoginView(onSwitchToPhone: {
                resetAuthFlow(switchTo: .phone)
            })
        case .waitPhoneNumber:
            if effectiveMethod == .none {
                AuthMethodView(method: $method)
            } else if effectiveMethod == .qr {
                QRLoginView(onSwitchToPhone: {
                    resetAuthFlow(switchTo: .phone)
                })
            } else {
                PhoneKeypadView()
            }
        case .waitCode:
            CodeKeypadView()
        case .waitPassword(let hint):
            TwoFactorView(hint: hint)
        case .error(let msg):
            AuthErrorView(message: msg) {
                resetAuthFlow()
            }
        default:
            LoadingPlaceholderView()
        }
    }

    private var showBackButton: Bool {
        AuthFlowLogic.shouldShowBackButton(
            authState: authManager.authState,
            method: method,
            hasQRCodeLink: authManager.qrCodeLink != nil
        )
    }

    private var effectiveMethod: AuthMethod {
        AuthFlowLogic.effectiveMethod(method: method, hasQRCodeLink: authManager.qrCodeLink != nil)
    }

    private func resetAuthFlow(switchTo: AuthMethod = .none) {
        isResetting = true
        authManager.clearQRCodeLinkAndThrottle()
        method = switchTo
        Task {
            // AppState owns the bounded native close and preserves its error.
            // A UI timer must not cancel that barrier or invent auth success.
            await appState.resetAuthMethodSelection()
            isResetting = false
        }
    }
}

struct AuthMethodView: View {
    @Environment(AuthManager.self) private var authManager
    @Binding var method: AuthMethod
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        List {
            Section {
                Button {
                    method = .qr
                } label: {
                    HStack {
                        Image(systemName: "qrcode")
                            .foregroundStyle(WristTheme.Palette.accent)
                        Text(L10n.string("QR Code"))
                    }
                    .frame(minHeight: 44)
                }
                .disabled(authManager.isLoading)
                .wristGlassRow()

                Button {
                    method = .phone
                } label: {
                    HStack {
                        Image(systemName: "phone")
                            .foregroundStyle(WristTheme.Palette.accent)
                        Text(L10n.string("Phone Number"))
                    }
                    .frame(minHeight: 44)
                }
                .disabled(authManager.isLoading)
                .wristGlassRow()
            } header: {
                Text(L10n.string("Sign In"))
                    .font(.headline)
            } footer: {
                Text(L10n.string("Unofficial app that uses the Telegram API and is part of the Telegram ecosystem. Not affiliated with Telegram."))
                    .font(.footnote)
            }

            Section {
                Picker(selection: languageSelection) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.optionLabelKey))
                            .tag(language.rawValue)
                    }
                } label: {
                    Label(L10n.string("Language"), systemImage: "globe")
                        .font(.caption)
                }
                .wristGlassRow()
            }
        }
        .wristListStyle()
        .id(appLanguage)
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: { appLanguage },
            set: { newValue in
                L10n.useLanguage(rawValue: newValue)
                appLanguage = newValue
            }
        )
    }
}
