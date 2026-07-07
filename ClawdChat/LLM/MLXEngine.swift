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
    /// Qwen3-VL-8B-4bit (5.8 GB of weights) LOADS on a 12 GB iPhone 17 Pro but
    /// jetsam SIGKILLs it as soon as generation starts (prefill + KV cache +
    /// vision tower overflow the per-app budget, even with the
    /// increased-memory-limit entitlement) — verified on device 2026-07-07.
    /// 4B is the real ceiling for phones today.
    private static let model = VLMRegistry.qwen3VL4BInstruct4Bit

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
    /// Conversation so far (user + assistant turns, think-blocks stripped).
    /// Kept here because each turn runs in a FRESH ChatSession — reusing a
    /// session's KV cache across turns is broken for Qwen3-VL in
    /// mlx-swift-lm 3.31.4 (turn 2+ hangs or emits corrupted text, verified
    /// on device 2026-07-07); replaying history costs a short prefill and
    /// stays correct.
    private var history: [Chat.Message] = []

    var modelName: String { Self.model.name }

    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        guard container == nil else { return }

        // Cap MLX's GPU buffer cache so inference stays inside the iOS
        // per-app memory budget.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        DebugLog.log("load() starting, model: \(Self.model.name)")
        let container = try await #huggingFaceLoadModelContainer(
            configuration: Self.model,
            progressHandler: { progress in
                let fraction = progress.fractionCompleted
                DebugLog.log("download progress: \(fraction) (\(progress.completedUnitCount)/\(progress.totalUnitCount))")
                Task { @MainActor in
                    onProgress(fraction)
                }
            }
        )
        DebugLog.log("model container loaded")
        self.container = container
        reset()
    }

    func reset() {
        history = []
        session = nil
    }

    /// One fresh ChatSession per turn (see `history` comment).
    private func makeSession(_ container: ModelContainer) -> ChatSession {
        ChatSession(
            container,
            instructions: Self.instructions,
            // Qwen's recommended sampling for instruct models; the repetition
            // penalty stops the degenerate "2023 and 2024. 2023 and 2024. …"
            // loops a 4-bit 4B model falls into after tool-result injection.
            generateParameters: GenerateParameters(
                temperature: 0.7,
                topP: 0.8,
                repetitionPenalty: 1.15,
                repetitionContextSize: 64
            ),
            tools: PhoneTools.specs + WebTools.specs + MoreTools.specs,
            toolDispatch: { call in
                DebugLog.log("tool call: \(call.function.name) args: \(call.function.arguments)")
                // A stuck tool must never hang the whole reply (the model
                // waits on this result), so every tool races a 30s deadline.
                let result = await Self.withDeadline(seconds: 30) {
                    if let webResult = await WebTools.dispatch(call) { return webResult }
                    if let moreResult = await MoreTools.dispatch(call) { return moreResult }
                    return await PhoneTools.dispatch(call)
                } ?? #"{"error": "tool timed out after 30 seconds"}"#
                DebugLog.log("tool result: \(result.prefix(300))")
                return result
            }
        )
    }

    private static func withDeadline(
        seconds: Double, _ body: @escaping @Sendable () async -> String
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func respond(to prompt: String, image: CIImage?) -> AsyncThrowingStream<String, Error> {
        guard let container else {
            return AsyncThrowingStream { $0.finish(throwing: EngineError.notLoaded) }
        }
        let session = makeSession(container)
        self.session = session

        let userMessage = Chat.Message.user(
            prompt, images: image.map { [.ciImage($0)] } ?? [])
        let turn = history + [userMessage]
        DebugLog.log("turn start (history: \(history.count) msgs)")
        let upstream = session.streamResponse(to: turn)

        // Tap the stream: log raw chunks for debugging, and on completion
        // fold the exchange into `history` for the next turn's replay.
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                var reply = ""
                do {
                    for try await chunk in upstream {
                        DebugLog.log("chunk: \(chunk.debugDescription)")
                        reply += chunk
                        continuation.yield(chunk)
                    }
                    self.commit(user: userMessage, reply: reply)
                    continuation.finish()
                } catch {
                    DebugLog.log("stream error: \(error)")
                    if !reply.isEmpty { self.commit(user: userMessage, reply: reply) }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Append a finished exchange to the replayed history. Think-blocks are
    /// dropped (Qwen convention: prior-turn reasoning is not replayed).
    private func commit(user: Chat.Message, reply: String) {
        var text = reply
        while let start = text.range(of: "<think>") {
            guard let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex)
            else {
                text.removeSubrange(start.lowerBound..<text.endIndex)
                break
            }
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        history.append(user)
        history.append(.assistant(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    enum EngineError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The model is not loaded yet." }
    }
}

#endif
