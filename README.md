# Clawd Chat — a private AI agent in your pocket

An iOS chat app that runs an open-source **vision-language model entirely
on-device**. No API keys, no server: the app downloads
[`mlx-community/Qwen3-VL-8B-Instruct-4bit`](https://huggingface.co/mlx-community/Qwen3-VL-8B-Instruct-4bit)
(~4.7 GB) from Hugging Face on first launch, then all inference happens on the
iPhone's GPU via [MLX Swift](https://github.com/ml-explore/mlx-swift-lm).
Airplane mode works fine after the first run (web tools excepted).

Beyond chat, the model is an **agent on your phone**:

- **Vision** — attach a camera shot or library photo (`+` in the composer)
  and ask about it; the model looks at it locally.
- **Voice** — mic button, on-device speech-to-text (audio never leaves).
- **Tools** the model calls on its own, with iOS asking your permission the
  first time each is touched: contacts, calendar (read + create), reminders
  (read + create), location, weather, step counts, clipboard, battery/date,
  web search (keyless DuckDuckGo), and web page reading.

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

## Agent loop (build → run → see, no hands)

`tools/simloop.sh [out.png]` builds the app, boots an iPhone simulator,
installs + launches the app, and writes a screenshot — so an agent (or CI)
can verify changes visually without a human clicking Run. For driving taps
and text input on the simulator: `brew install idb-companion && pipx install fb-idb`.
Real-model verification still needs a physical iPhone (see above); once the
phone has been trusted once, `xcrun devicectl` can install builds to it from
the CLI too.

## Swapping the model

Edit `MLXEngine.model` in `ClawdChat/LLM/MLXEngine.swift`:

```swift
static let model = ModelConfiguration(id: "mlx-community/Qwen3-VL-8B-Instruct-4bit")  // default: best fit for 12 GB phones
// static let model = VLMRegistry.qwen3VL4BInstruct4Bit   // half the size, ~2x faster, still vision+tools
// static let model = LLMRegistry.qwen3_4b_4bit           // text-only
```

Any 4-bit MLX model on the [mlx-community](https://huggingface.co/mlx-community)
hub should work.

## How it works

- `ChatStore` (`@Observable`) owns the message list and model lifecycle on
  top of an `LLMEngine` protocol with two implementations:
  - **`MLXEngine`** (device builds): `#huggingFaceLoadModelContainer`
    downloads/caches weights and returns a `ModelContainer`; a `ChatSession`
    on top keeps multi-turn history and streams tokens via
    `AsyncThrowingStream`.
  - **`MockEngine`** (simulator builds): MLX can't run in the simulator (no
    Metal GPU), so sim builds stream a canned reply — the full UI stays
    testable in automated simulator runs.
- Qwen's `<think>…</think>` reasoning blocks are stripped for display
  (`ChatMessage.displayText`) and shown as a "Thinking…" indicator instead.
- `MLX.GPU.set(cacheLimit:)` + the increased-memory-limit entitlement keep a
  2B model inside iOS's per-app memory budget.

## Roadmap ideas

- Model picker UI (download/manage multiple models)
- Conversation persistence
- Markdown rendering in bubbles
- Voice in/out (on-device speech ↔ TTS)
