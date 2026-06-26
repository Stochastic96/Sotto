# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Sotto is a privacy-first, **fully on-device** voice assistant for Apple Silicon Macs (tuned for an M1 with 8 GB RAM). It is a menu-bar-only app (`LSUIElement`) that does push-to-talk dictation **and** a JARVIS-style tool-calling agent ("Jarvis mode"). Everything runs in-process in Swift: **no Python, no local HTTP servers, no `.scpt` files, no network at inference time.**

`JARVIS_BLUEPRINT.md` is the authoritative design doc — the file-by-file map, the three-tier routing model, the roadmap (P0/P1/P2), and the "do not break / do not build" lists. Read it before any non-trivial change. This file is the operational quick-start; the blueprint is the architecture.

## Build, run & test

```bash
swift build                # build the app for debugging
swift run Sotto            # run the app directly
swift test                 # run the SottoCore test suite
swift test --filter PromptBudgetTests          # one test class
swift test --filter QuipsTests/testSomeCase    # one test case
```

- **Build and run via Swift PM**: You can build and run Sotto directly using standard Swift Package Manager commands (`swift build` / `swift run`). 
- **Xcode support**: You can open `Package.swift` in Xcode directly to edit, build, and debug the project in a graphical environment.
- **Tests run against `SottoCore` only** — the testable, pure-Swift target (`Tests/SottoTests` depends on `SottoCore`, not the `Sotto` executable). Anything you want covered must live in `SottoCore`.
- Runtime logs: stdout is redirected to `./sotto.log` in `main.swift` (`freopen`). Tail it to debug.
- **First heavy Jarvis task downloads the Qwen MLX model** (~0.4–0.9 GB) once; first offline transcription downloads the Parakeet model (~0.6 GB). Both then run fully offline. Neither is in git.

## Package layout

Two targets in `Package.swift`:

- **`SottoCore`** (`Sources/SottoCore/`) — pure Swift, no AppKit/FoundationModels/AVFoundation. Currently: `ContextDetector`, `PromptBudget`, `PromptPrep`, `Quips`, `VocabCorrector`. **This is the only tested target.** Keep adding testable logic here rather than into `AppController`. A change here must come with a test in `Tests/SottoTests/`.
- **`Sotto`** (`Sources/Sotto/`) — the executable: AppKit menu bar, audio, transcription, the agents, all the platform-bound code. Built with the `SOTTO_MLX` compile flag (and `SOTTO_FM27` when compiler ≥ 6.4).

## The brain — two native engines (`QwenRefiner` + `MLXEngine`)

`QwenRefiner` (an `actor`) is the single entry point for all LLM work and routes by task:

- **Dictation polish (`refine`)** → Apple Foundation Models via a **warm, reused `LanguageModelSession`**. Reusing one prewarmed session (recreated every ~12 turns to bound the transcript) is what keeps polish fast — a fresh session per call was the cause of the post–Apple-Intelligence slowdown. Stable instructions live on the session; per-call vocab/style/history go in the user turn.
- **Heavy / long-form generation (`getCompletion`)** → `MLXEngine.shared` (in-process Qwen via MLX-Swift), falling back to Apple Intelligence on any failure.

`MLXEngine` is an `actor` that loads a Qwen `ModelContainer` once and keeps it warm. **It is gated by the `SOTTO_MLX` compile flag.** With the flag off, `MLXEngine` is a no-op stub (`prepareIfNeeded()` returns false) and all generation uses Apple Intelligence — so the app builds with or without the MLX packages. Default model: `mlx-community/Qwen2.5-0.5B-Instruct-4bit` (small enough to stay resident alongside Apple Intelligence on 8 GB).

`Package.swift` MLX deps: `ml-explore/mlx-swift-lm` (`MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`) + `huggingface/swift-huggingface` (`HuggingFace`) + `huggingface/swift-transformers` (`Tokenizers`) — the last two back the loader macros in `MLXEngine`.

## Runtime flow

Wired up in `AppController` (`@MainActor`) from `main.swift`. `AppController.endRecording()` is the core pipeline — read it first. (Note: `AppController` and `CommandEngine` are both oversized and slated for splitting per blueprint §4.1–4.2; do not add new responsibilities to them.)

1. **Hotkey/menu/wake-word** (`HotkeyListener`, `StatusBarController`, `WakeWordDetector`) sets `currentMode` (`.dictation` / `.jarvis`), then `beginRecording()`.
2. **`AudioRecorder`** captures 16 kHz mono Float32; auto-stops on silence / cap.
3. **`Transcriber`** — two engines via `SettingsController.transcriptionEngine`: `offlineAI` (FluidAudio Parakeet on the ANE) or `appleSpeech` (`SFSpeechRecognizer`).
4. **Routing** in `endRecording()` (first match wins, each returns early) — the three-tier model:
   - **Tier 0**: voice **skill-approval gate** ("enable/approve skill X" → `SkillStore.enable`); selection grab; **zero-latency shortcuts** (`CommandEngine.checkZeroLatencyShortcut`, deterministic, emit `native:<action>`); `CommandEngine.process`.
   - **Tier 1**: Jarvis agent (`.jarvis` + macOS 26) — `CoordinatorAgent`/`JarvisAgent` over Apple Foundation Models tool-calling.
   - **Tier 2**: MLX (Qwen) or Claude CLI fallback for sub-agents.
   - **AI polish** (`QwenRefiner.refine`) for dictation, with sanity checks against truncation/expansion/loops.
5. **`TextInjector.inject`** re-activates the prior frontmost app and pastes via pasteboard + synthetic ⌘V. Keystrokes use **`CGEvent.postToPid(targetPID)`** (not the global HID tap) so the paste targets the intended app — this fixed the "text shows but never pastes" bug. Direct AX insert is opt-in (`SettingsController.isDirectInsert`, default off) and gated on `AXUIElementIsAttributeSettable`.

## Tool calling & routing (the key accuracy decision)

The agent exposes ~27 native Swift `Tool`s (`JarvisTools.swift`, `JarvisToolbox.all()`), each with a `@Generable Arguments` struct. **Tool-selection accuracy plateaus around 8 tools**, so `JarvisToolbox.routed(for:)` sends only the ≤8 tools relevant to each utterance, by keyword group. A tool that is in `all()` but never in a `routed(for:)` group will never be called.

When adding a tool: (1) `@Generable Arguments` with `@Guide` annotations — use `@Guide(options:)` or a `@Generable enum` whenever the valid values are known, never a free-form `String`; (2) add to `all()`; (3) add to the right keyword group in `routed(for:)`; (4) validate inputs and return descriptive error strings — never force-unwrap, a crashing tool silently drops the Foundation Models turn.

## Multi-agent layer

`CoordinatorAgent` is the front door (retains session across clarification turns) and delegates to focused sub-agents (`OSControlAgent`, `WebResearcherAgent`, `ScriptingExecutorAgent`) and `LongTaskEngine` (resumable bulk jobs) via `DelegateTo…`/`StartLongTask` tools. It sheds context-window overflow by retrying tool-free on `exceededContextWindowSize`. `CoordinatorAgent.isMockMode = true` exercises the loop without Apple Intelligence — use it for integration tests.

## Native action layer (`NativeActions.swift`)

All `native:<action>` commands dispatch through `NativeActions.perform`: `NativeWindow` (AX API window tiling), `MediaControl` (NX media keys), `BrowserControl`/`KeySimulator` (keystroke nav), `Appearance` (dark mode / show desktop), `SystemControlHelper` (CoreAudio volume/mute, DisplayServices brightness), `SystemDiagnostics`, `NativeSystemOrchestrator` (lock/sleep/empty-trash/create-note). The few toggles with no public API (dark mode, sleep, Notes) use a small in-process `NSAppleScript` string — no external files, no shell.

## The skill approval gate (security-critical)

The agent can **draft** a skill (`DraftSkillTool` → `SkillStore.draft()`, saved DISABLED). Only the **user** can enable it ("enable skill X" → `SkillStore.enable()`), and only enabled skills run (`SkillStore.runEnabled()`). **Never call `runEnabled` from agent code, and never add an auto-approve path.** This gate is what keeps agent-generated code from self-executing.

## Persistence

- **`UserDefaults`** (`sotto_*` keys): settings, learned `sotto_style_examples` and `sotto_learned_vocabulary`, skill manifest, typed `UserProfile` preferences.
- **`sotto-data/`** (gitignored): datasets (`DatasetLogger`), `TaskJournal`, `SystemMemoryStore` (key-value session memory), `SemanticMemory` (NLEmbedding vectors, capped at 400 entries — no model download, fits 8 GB), research notes, downloaded model assets.

## Gotchas

- LLM provider is **Apple Intelligence only** (+ in-process MLX). `SettingsController.apiProvider` is a constant `"apple"` kept so `== "apple"` guards compile. The old mlx_lm.server / OpenAI / Kokoro paths are gone.
- `MLXEngine` is a no-op unless built with `SOTTO_MLX` **and** the MLX packages resolve; `getCompletion` falls back to Apple Intelligence transparently.
- Several paths **hard-code `~/Projects/Sotto`** (`/Users/prashantsharma/Projects/Sotto`). On a different username/clone location, these need updating.
- Jarvis mode and dictation-polish fallback require **macOS 26+ with Apple Intelligence enabled**.
- Runtime permissions: Microphone, Accessibility (hotkey + ⌘V + window AX), Screen Recording (OCR), Automation (System Events/Notes), Calendar/Reminders (when EventKit tools are wired). Any new tool touching a restricted API must check permission status and return a helpful message rather than crash.
- URL scheme: `sotto://command?text=...` → `AppController.handleIncomingCommandText`.

## Working rules

- **Deterministic first.** If a command can be a `case` in `CommandEngine.checkZeroLatencyShortcut` (cap ~50), do that before writing a tool. Match the existing Hindi persona in `voiceFeedback` strings.
- **Keep `SottoCore` pure** (no Apple-platform imports) and tested.
- **Don't grow `AppController`/`CommandEngine`** — new pipeline stages go in dedicated files.
- See `JARVIS_BLUEPRINT.md` §3 ("do not break") and §5 ("do not build") before changing routing, the approval gate, or adding a persistent server/chat UI.
