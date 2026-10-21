import SwiftUI

/// A row with a colored icon, as in the Settings app. Used in the More tabs of guests and nodes.
struct MoreRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let color: Color
    var hint: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient, in: .rect(cornerRadius: 8))
            Text(title)
            Spacer()
            if let hint {
                Text(hint)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
