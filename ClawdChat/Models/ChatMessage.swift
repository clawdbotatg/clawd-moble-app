import Foundation
import UIKit

struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    /// Photo the user attached (camera or library), shown in the bubble and
    /// sent to the vision model.
    var image: UIImage?

    init(role: Role, text: String, image: UIImage? = nil) {
        self.role = role
        self.text = text
        self.image = image
    }

    /// Qwen 3.x models can emit `<think>…</think>` reasoning blocks before the
    /// answer. Strip them for display; an unclosed tag means it is still thinking.
    var displayText: String {
        var s = text
        while let start = s.range(of: "<think>") {
            if let end = s.range(of: "</think>", range: start.upperBound..<s.endIndex) {
                s.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                s.removeSubrange(start.lowerBound..<s.endIndex)
                break
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isThinking: Bool {
        text.contains("<think>") && !text.contains("</think>")
    }
}
