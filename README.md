# Clawd Chat — an LLM in your pocket

A minimal iOS chat app that runs an open-source model **entirely on-device**.
No API keys, no server: the app downloads
[`mlx-community/Qwen3.5-2B-4bit`](https://huggingface.co/mlx-community/Qwen3.5-2B-4bit)
(~1.2 GB) from Hugging Face on first launch, then all inference happens on the
iPhone's GPU via [MLX Swift](https://github.com/ml-explore/mlx-swift-lm).
Airplane mode works fine after the first run.

## Stack

- **SwiftUI** (iOS 17+) — chat UI with streaming tokens
- **[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)** — model
  implementations + `ChatSession` (multi-turn history, streaming)
- **swift-huggingface / swift-transformers** — weights download + tokenizer
- **XcodeGen** — `project.yml` is the source of truth; the `.xcodeproj` is
  generated (and committed for convenience)

## Build & run

1. **Install Xcode** (App Store; 16.3 or newer — the packages need Swift 6.1
   toolchain). Then make sure the full Xcode is active:
   ```sh
   sudo xcode-select -s /Applications/Xcode.app
   ```
2. **Generate the project** (only needed after editing `project.yml`; a
   generated `ClawdChat.xcodeproj` is already committed):
   ```sh
   brew install xcodegen
   xcodegen generate
   ```
3. **Open `ClawdChat.xcodeproj`**, select the *ClawdChat* target →
   *Signing & Capabilities* → pick your team (a free personal team works).
4. **Run on a real iPhone** (plugged in, or Wi-Fi debugging). MLX needs an
   Apple-silicon GPU — the simulator is not a useful target. iPhone 13 or
   newer recommended; first launch downloads the weights, so be on Wi-Fi.

> If signing complains about the *Increased Memory Limit* entitlement on your
> account, delete it in Signing & Capabilities (or from
> `ClawdChat/ClawdChat.entitlements`) — the 2B model usually still fits.

## Swapping the model

Edit `ChatStore.model` in `ClawdChat/LLM/ChatStore.swift`:

```swift
static let model = LLMRegistry.qwen3_5_2b_4bit      // default
// static let model = LLMRegistry.qwen3_0_6b_4bit   // tiny + fast, older phones
// static let model = LLMRegistry.qwen3_4b_4bit     // smarter, needs a Pro-class phone
// static let model = ModelConfiguration(id: "mlx-community/Llama-3.2-3B-Instruct-4bit")
```

Any 4-bit MLX model on the [mlx-community](https://huggingface.co/mlx-community)
hub should work.

## How it works

- `ChatStore` (`@Observable`) owns the model lifecycle:
  `#huggingFaceLoadModelContainer` downloads/caches weights and returns a
  `ModelContainer`; a `ChatSession` on top of it keeps multi-turn history and
  streams tokens via `AsyncThrowingStream`.
- Qwen's `<think>…</think>` reasoning blocks are stripped for display
  (`ChatMessage.displayText`) and shown as a "Thinking…" indicator instead.
- `MLX.GPU.set(cacheLimit:)` + the increased-memory-limit entitlement keep a
  2B model inside iOS's per-app memory budget.

## Roadmap ideas

- Model picker UI (download/manage multiple models)
- Conversation persistence
- Markdown rendering in bubbles
- Voice in/out (on-device speech ↔ TTS)
