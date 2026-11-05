import SwiftUI

struct EditMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    let onSave: (String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            TextField(L10n.string("Edit message"), text: $text)
                .frame(minHeight: 44)
                .background { WristGlassBackground(cornerRadius: 22) }
                .clipShape(Capsule())
            Button(L10n.string("Save")) {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                onSave(trimmed)
                dismiss()
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .foregroundStyle(WristTheme.Palette.accent)
            .buttonStyle(WristGlassButtonStyle(tint: WristTheme.Palette.accent))
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L10n.string("Edit"))
        .background { WristScreenBackground() }
    }
}
