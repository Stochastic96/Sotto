# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Sotto is a privacy-first, **fully on-device** voice assistant for Apple Silicon Macs (tuned for an M1 with 8 GB RAM). It is a menu-bar-only app (`LSUIElement`) that does push-to-talk dictation **and** a JARVIS-style tool-calling agent ("Jarvis mode"). Everything runs in-process in Swift: **no Python, no local HTTP servers, no `.scpt` files, no network at inference time.**

## Build & run

```bash
./scripts/make-app.sh      # release build via xcodebuild → build/Sotto.app (ad-hoc codesigned)
open build/Sotto.app
pkill -f Sotto.app         # stop a running instance
swift build                # fast compile / type-check
```

- **Use `make-app.sh`, not a bare `swift build`, to ship a runnable app.** It uses `xcodebuild` (required to compile MLX's Metal shaders) and copies SwiftPM `.bundle` resources into the app.
- No test target — `Package.swift` declares a single `executableTarget`.
- Runtime logs go to `./sotto.log` (stdout/stderr are redirected there in `main.swift`). Tail it to debug.
- **First `make-app.sh` build is slow** (MLX Metal compilation). **First heavy Jarvis task downloads the Qwen model** (~0.9 GB) once.

## The brain — two native engines (`QwenRefiner` + `MLXEngine`)

`QwenRefiner` (an `actor`) is the single entry point for all LLM work and routes by task:

- **Dictation polish (`refine`)** → Apple Foundation Models via a **warm, reused `LanguageModelSession`**. Reusing one prewarmed session (recreated every ~12 turns to bound the transcript) is what keeps polish fast — creating a fresh session per call was the cause of the post–Apple-Intelligence slowdown. Stable instructions live on the session; per-call vocab/style/history go in the user turn.
- **Heavy / long-form generation (`getCompletion`)** → `MLXEngine.shared` (in-process Qwen via MLX-Swift), falling back to Apple Intelligence on any failure.

`MLXEngine` (`MLXEngine.swift`) is an `actor` that loads a Qwen `ModelContainer` once and keeps it warm, creating a fresh `ChatSession` per call. **It is gated by the `SOTTO_MLX` compile flag** (defined in `Package.swift` `swiftSettings`). When the flag is off, `MLXEngine` is a no-op stub (`prepareIfNeeded()` returns false) and all generation uses Apple Intelligence — so the app builds with or without the MLX packages. Default model: `mlx-community/Qwen2.5-1.5B-Instruct-4bit` (`SettingsController.modelIdentifier`).

`JarvisAgent` (`JarvisAgent.swift`) is the agent brain: Apple Foundation Models tool-calling (`LanguageModelSession` + `JarvisToolbox.all()` from `JarvisTools.swift`). Requires macOS 26.

### Adding MLX packages

`Package.swift` depends on `ml-explore/mlx-swift-lm` (`MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`), plus `huggingface/swift-huggingface` (`HuggingFace` module) and `huggingface/swift-transformers` (`Tokenizers` module) — the last two back the `#hubDownloader()` / `#huggingFaceTokenizerLoader()` loader macros used in `MLXEngine`.

## Runtime flow

Wired up in `AppController` (`@MainActor`) from `main.swift`. `AppController.endRecording()` is the core pipeline — read it first.

1. **Hotkey/menu** (`HotkeyListener`, `StatusBarController`) sets `currentMode` (`.dictation` / `.jarvis`), then `beginRecording()`.
2. **`AudioRecorder`** captures 16 kHz mono Float32; auto-stops on silence / 5-min cap.
3. **`Transcriber`** — two engines via `SettingsController.transcriptionEngine`: `offlineAI` (FluidAudio Parakeet on the ANE) or `appleSpeech` (`SFSpeechRecognizer`).
4. **Routing** in `endRecording()` (first match wins, each returns early):
   - Voice **skill-approval gate**: "enable/approve/activate skill X" → `SkillStore.enable` (the only way a drafted skill becomes runnable — do not let the agent self-enable skills).
   - Selection grab when the utterance mentions "selection".
   - **Zero-latency shortcuts** (`CommandEngine.checkZeroLatencyShortcut`) — deterministic, no LLM. All emit `native:<action>` commands.
   - **Jarvis agent** (`.jarvis` mode + macOS 26): `JarvisAgent.run`.
   - **Orchestrator** (`CommandEngine.orchestratorAction`) — Claude-popover flows (`ClaudeQuickEntry`).
   - **`CommandEngine.process`** — general command/dictation handler.
   - **AI polish** (`QwenRefiner.refine`, 15 s timeout, sanity-checks against truncation/expansion/loops).
5. **`TextInjector.inject`** re-activates the prior frontmost app and pastes via pasteboard + synthetic ⌘V. Keystrokes are delivered with **`CGEvent.postToPid(targetPID)`** (not the global HID tap) so the paste targets the intended app and doesn't lose the focus race — this fixed the "text shows but never pastes" bug. Direct-insert (AX) is opt-in (`SettingsController.isDirectInsert`, default off).

## Native action layer (`NativeActions.swift`)

All `native:<action>` commands dispatch through `NativeActions.perform` (called from the `default:` case of the `native:` switch in `AppController.endRecording`):

- **Window management** (`NativeWindow`) — AX API (`kAXPosition/Size/Minimized/CloseButton`). `workArea()` converts the Cocoa visible frame to AX top-left coords.
- **Media** (`MediaControl`) — system-defined NX media keys (play/pause/next/prev).
- **Browser** (`BrowserControl` + `KeySimulator`) — keystrokes for reload/back/forward/new-tab/close; `listFrontmostWindows()` via `CGWindowListCopyWindowInfo`.
- **Appearance** (`Appearance`) — dark-mode toggle and show-desktop.

Other native helpers: `SystemControlHelper` (CoreAudio volume/mute, DisplayServices brightness), `SystemDiagnostics` (battery/wifi/disk/RAM), `NativeSystemOrchestrator` (lock/sleep/empty-trash/create-note). The few OS toggles with **no public API** (dark mode, sleep, Notes creation) use a small in-process `NSAppleScript` string — no external files, no shell.

## LLM providers

There is only one: **Apple Intelligence** (+ in-process MLX). `SettingsController.apiProvider` is a constant `"apple"` kept so existing `== "apple"` guards still compile. The old `local` (mlx_lm.server) and `custom` (OpenAI) providers, the API-key/base-URL settings, and the Kokoro TTS settings have been removed.

## Persistence

- **`UserDefaults`** (`sotto_*` keys in `SettingsWindow.swift`): settings, plus learned `sotto_style_examples` and `sotto_learned_vocabulary` (on-device style learning in `AppController.learnFromDictation`).
- **`sotto-data/`**: datasets (`DatasetLogger`), task journal (`TaskJournal`), `jarvis_memory.db` (`SystemMemoryStore`), research notes, downloaded model assets. `sotto-data/skills/` still holds old `.scpt`/`.applescript` files — they are **no longer referenced by the shipped shortcuts** (only the user-drafted-skill path in `SkillStore` → `CommandEngine.runCommandNatively` runs AppleScript/shell, for voice-approved user skills).

## Entry points

- **URL scheme**: `sotto://command?text=...` → `AppController.handleIncomingCommandText`.
- Migrations were removed from `AppController.init()` along with the provider/Kokoro settings.

## Gotchas

- `MLXEngine` is a no-op unless built with `SOTTO_MLX` **and** the MLX packages resolve. `getCompletion` transparently falls back to Apple Intelligence.
- Several paths hard-code `~/Projects/Sotto` / `/Users/prashantsharma/Projects/Sotto`.
- Runtime permissions: Microphone, Accessibility (hotkey + ⌘V + window AX), Screen Recording (OCR), Automation for System Events/Notes (dark mode, sleep, notes).
- Not a git repository.
