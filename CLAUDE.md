# ClawdChat — orientation for Claude

iOS chat app running an open-source **vision-language model fully on-device**:
SwiftUI + [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) 3.x,
downloads `mlx-community/Qwen3-VL-8B-Instruct-4bit` (~4.7 GB) from Hugging
Face on first launch. The model has **tools** (contacts, calendar r/w,
reminders r/w, location, weather, steps, clipboard, device status, web search,
page fetch), **vision** (camera / photo library via the composer's `+` menu),
and **on-device STT** (mic button). `README.md` has the architecture; this
file is the working state.

## Current state (2026-07-07)

**Shipped and running on a real iPhone 17 Pro** ("Austin's iPhone", paired,
team `XX7QP5899Z` — a paid account, so the increased-memory-limit entitlement
signs fine). Everything verified end-to-end: simulator screenshots, device
install/launch via `devicectl`, real downloads, real inference, tool calls.

## Build / deploy loop (all CLI, no Xcode GUI)

- Prefix everything with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  (xcode-select still points at CommandLineTools; that's fine).
- **Simulator**: `tools/simloop.sh out.png` — build, boot, install, launch,
  screenshot (MockEngine in the sim; MLX needs a real GPU). Read the
  screenshot to verify UI.
- **Device build**: `xcodebuild -project ClawdChat.xcodeproj -scheme ClawdChat
  -destination 'generic/platform=iOS' -derivedDataPath build
  -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates
  DEVELOPMENT_TEAM=XX7QP5899Z build`
  (the two -skip flags are required headless: mlx-swift's CudaBuild plugin and
  the `#huggingFaceLoadModelContainer` macro can't show their trust prompts).
- **Install + launch**: `xcrun devicectl device install app --device
  8B053FBC-B638-548F-B045-F5DDE25D3BDD <path>.app` then
  `… device process launch --terminate-existing --device <udid> com.clawd.chat`.
  **Both fail while the phone is locked** (`kAMDMobileImageMounterDeviceLocked`
  / SBMainWorkspace "Locked") — ask the user to unlock, retry in a loop.
  Launch with `--console` to stream the app's prints (debug prints live in
  `MLXEngine.load`); note that killing the console session terminates the app.
- Reinstalling over the top preserves the app container → model weights
  survive app updates; only a model-id change triggers a new download.

## Conventions / gotchas

- `project.yml` (XcodeGen) is the source of truth; `xcodegen generate` after
  editing and **commit the regenerated `.xcodeproj` together with it** — a
  stale project file silently drops new source files (that was the very first
  build failure).
- Model swaps: `MLXEngine.model` in `ClawdChat/LLM/MLXEngine.swift`. Any
  mlx-community repo id works via `ModelConfiguration(id:)`; linking MLXVLM
  makes the shared loader route vision configs automatically. 8B-4bit is the
  practical ceiling for a 12 GB phone; `VLMRegistry.qwen3VL4BInstruct4Bit` is
  the ~2× faster fallback.
- Adding a tool: new `Tool` in `PhoneTools`/`WebTools`/`MoreTools` (or a new
  file), list it in that enum's `specs` + `dispatch`, add any Info.plist usage
  string to `project.yml`, and mention it in `MLXEngine.instructions` so the
  model can describe itself accurately.
- Download progress: the HF snapshot is one giant safetensors file, so the
  real byte fraction stalls near 1% — the loading screen shows a time-based
  sweep instead (`ChatView.loadingScreen`). Don't "fix" it back to raw fraction.
- Do not add an API-based fallback; on-device-only is the point of the app.
