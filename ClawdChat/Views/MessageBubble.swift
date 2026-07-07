import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: 8) {
                if let image = message.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if message.isThinking && message.displayText.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").foregroundStyle(.secondary)
                    }
                } else if message.displayText.isEmpty && message.image == nil {
                    ProgressView().controlSize(.small)
                } else if !message.displayText.isEmpty {
                    Text(message.displayText)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.role == .user
                    ? AnyShapeStyle(.tint)
                    : AnyShapeStyle(.fill.secondary),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .foregroundStyle(message.role == .user ? .white : .primary)

            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }
}
