#if !targetEnvironment(simulator)

import CoreImage
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Real on-device backend: downloads the model from Hugging Face once,
/// then runs inference on the GPU via MLX.
@MainActor
final class MLXEngine: LLMEngine {
    /// Swap the model by pointing at any entry in `LLMRegistry` (text-only),
    /// `VLMRegistry` (vision), or any mlx-community repo id — linking MLXVLM
    /// makes the shared loader route vision models automatically.
    /// Qwen3-VL-8B-4bit (~4.7 GB) is about the best brain+vision combo a
    /// 12 GB iPhone Pro fits; `VLMRegistry.qwen3VL4BInstruct4Bit` is the
    /// half-size, roughly-2x-faster fallback.
    private static let model = ModelConfiguration(
        id: "mlx-community/Qwen3-VL-8B-Instruct-4bit")

    private static var instructions: String {
        """
        You are Clawd Chat, a helpful assistant running FULLY ON-DEVICE on the \
        user's iPhone — you are the open-source model \(model.name) running \
        locally on the phone's GPU via MLX. There is no cloud: nothing the user \
        says, shares, or photographs ever leaves the phone.

        What you can do:
        - See photos the user attaches (camera or photo library) — identify \
        things, read text in images, answer questions about them.
        - Search the web (web_search) and read pages (fetch_webpage).
        - Search their contacts (search_contacts).
        - Read their calendar (get_calendar_events) and create events \
        (create_calendar_event).
        - Read and create reminders (get_reminders, create_reminder).
        - Get their current location (get_location) and local weather (get_weather).
        - Read daily step counts (get_steps), the clipboard (read_clipboard), \
        and battery/iOS/current date-time (get_device_status).

        iOS asks the user's permission the first time you touch each data \
        source; if a tool reports access denied, tell them it can be enabled in \
        Settings. Use tools whenever a question involves the user's own data or \
        current information — don't guess, and never invent tool results. You do \
        not know the current date, time, or location without calling a tool. If \
        asked what you can do, describe these abilities in plain language and \
        proudly mention everything runs on the phone. Be concise.
        """
    }

    private var container: ModelContainer?
    private var session: ChatSession?

    var modelName: String { Self.model.name }

    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        guard container == nil else { return }

        // Cap MLX's GPU buffer cache so inference stays inside the iOS
        // per-app memory budget.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        print("[ClawdChat] load() starting, model: \(Self.model.name)")
        let container = try await #huggingFaceLoadModelContainer(
            configuration: Self.model,
            progressHandler: { progress in
                let fraction = progress.fractionCompleted
                print("[ClawdChat] download progress: \(fraction) (\(progress.completedUnitCount)/\(progress.totalUnitCount))")
                Task { @MainActor in
                    onProgress(fraction)
                }
            }
        )
        print("[ClawdChat] model container loaded")
        self.container = container
        reset()
    }

    func reset() {
        guard let container else { return }
        session = ChatSession(
            container,
            instructions: Self.instructions,
            tools: PhoneTools.specs + WebTools.specs + MoreTools.specs,
            toolDispatch: { call in
                if let result = await WebTools.dispatch(call) { return result }
                if let result = await MoreTools.dispatch(call) { return result }
                return await PhoneTools.dispatch(call)
            }
        )
    }

    func respond(to prompt: String, image: CIImage?) -> AsyncThrowingStream<String, Error> {
        guard let session else {
            return AsyncThrowingStream { $0.finish(throwing: EngineError.notLoaded) }
        }
        return session.streamResponse(to: prompt, image: image.map { .ciImage($0) })
    }

    enum EngineError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The model is not loaded yet." }
    }
}

#endif
