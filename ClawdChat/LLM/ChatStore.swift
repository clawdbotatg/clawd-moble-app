import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Owns the on-device model lifecycle (download → load → chat) and the
/// message list the UI renders. Everything runs locally; the only network
/// use is the one-time weights download from Hugging Face.
@Observable
@MainActor
final class ChatStore {
    enum ModelState: Equatable {
        case idle
        case downloading(Double)  // 0...1 fraction of the weights download
        case ready
        case failed(String)
    }

    private(set) var modelState: ModelState = .idle
    private(set) var messages: [ChatMessage] = []
    private(set) var isGenerating = false

    private var container: ModelContainer?
    private var session: ChatSession?
    private var generationTask: Task<Void, Never>?

    /// Swap the model by pointing at any entry in `LLMRegistry` (or a custom
    /// `ModelConfiguration(id: "mlx-community/…")`). 4-bit ~2B models are the
    /// sweet spot for current iPhones.
    static let model = LLMRegistry.qwen3_5_2b_4bit

    private static let instructions =
        "You are a helpful assistant running fully on-device on an iPhone. Be concise."

    var modelName: String {
        "\(Self.model.name)"
    }

    func loadModel() async {
        guard container == nil, modelState != .ready else { return }
        modelState = .downloading(0)

        // Cap MLX's GPU buffer cache so inference stays inside the iOS
        // per-app memory budget.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        do {
            let container = try await #huggingFaceLoadModelContainer(
                configuration: Self.model,
                progressHandler: { progress in
                    Task { @MainActor in
                        self.modelState = .downloading(progress.fractionCompleted)
                    }
                }
            )
            self.container = container
            startNewSession()
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !isGenerating, !trimmed.isEmpty else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        messages.append(ChatMessage(role: .assistant, text: ""))
        let index = messages.count - 1
        isGenerating = true

        generationTask = Task {
            do {
                for try await chunk in session.streamResponse(to: trimmed) {
                    messages[index].text += chunk
                }
            } catch is CancellationError {
                // User tapped stop; keep whatever was generated.
            } catch {
                messages[index].text += "\n\n⚠️ \(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    func stopGenerating() {
        generationTask?.cancel()
    }

    /// New conversation: drop UI messages and the session's KV/history state.
    func clear() {
        stopGenerating()
        messages.removeAll()
        startNewSession()
    }

    private func startNewSession() {
        guard let container else { return }
        session = ChatSession(container, instructions: Self.instructions)
    }
}
