import SwiftUI

struct QRLoginView: View {
    @Environment(AuthManager.self) private var authManager
    var onSwitchToPhone: () -> Void

    @State private var qrLink = ""

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    if qrLink.isEmpty {
                        LoadingPlaceholderView(message: L10n.string("Waiting for QR..."))
                            .frame(height: 120)

                        Button(authManager.isLoading ? L10n.string("Generating...") : L10n.string("Generate QR")) {
                            Task { await authManager.requestQRCodeAuth(forceRefresh: true) }
                        }
                        .font(.caption2)
                        .buttonStyle(WristGlassButtonStyle(tint: WristTheme.Palette.accent))
                        .disabled(authManager.isLoading)
                    } else {
                        QRCodeView(text: qrLink)
                            .frame(width: 120, height: 120)
                            .padding(8)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        StepView(number: 1, text: L10n.string("Open Telegram on your phone"))
                        StepView(number: 2, text: L10n.string("Settings -> Devices -> Link Desktop Device"))
                        StepView(number: 3, text: L10n.string("Point your phone at the QR code"))
                    }
                    .padding(.top, 6)
                    .padding(10)
                    .background(WristGlassBackground(cornerRadius: 20))
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            Section {
                Button(L10n.string("Use Phone Number")) {
                    onSwitchToPhone()
                }
                .font(.caption)
                .frame(minHeight: 44)
                .wristGlassRow()
            }
        }
        .task {
            if let existing = authManager.qrCodeLink {
                qrLink = existing
            } else {
                await authManager.requestQRCodeAuth()
            }
            if let link = authManager.qrCodeLink {
                qrLink = link
            }
        }
        .onChange(of: authManager.qrCodeLink) { _, newLink in
            if let newLink {
                qrLink = newLink
            }
        }
        .wristListStyle()
    }
}

struct QRCodeView: View {
    let text: String
    @State private var qrMatrix: QRCodeMatrix? = nil
    @State private var encodedText = ""
    @State private var generationTask: Task<Void, Never>?

    var body: some View {
        Canvas { context, size in
            guard let qr = qrMatrix, qr.size > 0 else { return }
            let moduleSize = min(size.width, size.height) / CGFloat(qr.size)

            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.white)
            )

            for y in 0..<qr.size {
                for x in 0..<qr.size {
                    if qr.modules[y][x] {
                        let rect = CGRect(
                            x: CGFloat(x) * moduleSize,
                            y: CGFloat(y) * moduleSize,
                            width: moduleSize,
                            height: moduleSize
                        )
                        context.fill(Path(rect), with: .color(.black))
                    }
                }
            }
        }
        .onChange(of: text) { _, newText in regenerateIfNeeded(for: newText) }
        .onAppear { regenerateIfNeeded(for: text) }
        .onDisappear {
            generationTask?.cancel()
            generationTask = nil
            encodedText = ""
        }
    }

    @MainActor
    private func regenerateIfNeeded(for newText: String) {
        guard !newText.isEmpty else {
            generationTask?.cancel()
            generationTask = nil
            encodedText = ""
            qrMatrix = nil
            return
        }
        guard newText != encodedText else { return }

        encodedText = newText
        generationTask?.cancel()
        // Build the QR matrix away from MainActor so Canvas rendering and
        // encoding are separate; keep the previous matrix until replacement.
        generationTask = Task.detached(priority: .userInitiated) {
            do {
                let matrix = try QRCodeMatrix.encode(text: newText)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard encodedText == newText, !Task.isCancelled else { return }
                    qrMatrix = matrix
                    generationTask = nil
                }
            } catch {
                await MainActor.run {
                    guard encodedText == newText, !Task.isCancelled else { return }
                    encodedText = ""
                    qrMatrix = nil
                    generationTask = nil
                }
            }
        }
    }
}

struct QRCodeMatrix: Equatable {
    let text: String
    let size: Int
    let modules: [[Bool]]

    static func encode(text: String) throws -> QRCodeMatrix {
        let qr = try QRCode.encode(text: text, ecl: .medium)
        let count = qr.size
        var modules = Array(repeating: Array(repeating: false, count: count), count: count)
        for y in 0..<count {
            for x in 0..<count {
                modules[y][x] = qr.getModule(x: x, y: y)
            }
        }
        return QRCodeMatrix(text: text, size: count, modules: modules)
    }
}
