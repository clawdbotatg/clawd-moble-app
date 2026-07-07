import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            Group {
                if message.isThinking && message.displayText.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").foregroundStyle(.secondary)
                    }
                } else if message.displayText.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
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
