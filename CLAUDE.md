# ClawdChat — orientation for Claude

iOS chat app running an open-source LLM **fully on-device**: SwiftUI +
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) 3.x, downloads
`mlx-community/Qwen3.5-2B-4bit` (~1.2 GB) from Hugging Face on first launch.
`README.md` has the full architecture; this file is the working state.

## Current state (2026-07-06)

**The code has NEVER been compiled.** It was written on a machine without
Xcode (`clawd-leftclaw`), against the mlx-swift-lm 3.x API as read from the
upstream source (ChatSession, `#huggingFaceLoadModelContainer` macro,
decoupled swift-huggingface/swift-transformers). Expect first-compile errors —
fixing them is the immediate next step, on a machine with Xcode ("head").

## Next steps, in order

1. Toolchain (once): `sudo xcode-select -s /Applications/Xcode.app`,
   `sudo xcodebuild -license accept`, `xcodebuild -downloadPlatform iOS`
   (simulator runtime). If sudo is unavailable, prefix commands with
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` instead of
   xcode-select.
2. `tools/simloop.sh /tmp/clawdchat.png` — builds, boots an iPhone simulator,
   installs, launches, screenshots. First run resolves SwiftPM packages
   (slow) and will surface the compile errors. Fix, re-run, repeat until the
   screenshot shows the chat UI (simulator uses `MockEngine` — MLX cannot run
   in the simulator, no Metal GPU; that's by design, see `LLMEngine.swift`).
3. Read the screenshot (it's an image; the Read tool renders it) and verify:
   download progress → chat UI → send a message via `idb`
   (`brew install idb-companion && pipx install fb-idb`) or add an XCUITest.
4. Real inference needs a physical iPhone: set the team in Xcode signing once,
   then `xcrun devicectl` can install builds from the CLI.

## Conventions / gotchas

- `project.yml` (XcodeGen) is the source of truth; regenerate with
  `xcodegen generate` after editing it. The generated `.xcodeproj` is
  committed on purpose — keep it in sync (regenerate + commit together).
- If Xcode signing complains about the increased-memory-limit entitlement on
  a free team, drop it from `project.yml` (`entitlements:` block) — the 2B
  model usually fits without it.
- Model swaps: `MLXEngine.model` in `ClawdChat/LLM/MLXEngine.swift`.
- Do not add an API-based fallback; on-device-only is the point of the app.
