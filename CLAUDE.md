# CLAUDE.md

Guidance for Claude Code (or any future agent) working in this repo.

## What this is

Sotto is a native Swift, on-device macOS voice assistant. Two modes: **Dictation**
(speak → polished text typed into whatever app is focused) and **Jarvis** (speak a
command → Sotto acts: opens apps, controls the OS, browses, drafts scripts, etc).
Full user-facing description is in `README.md` — read that first for behavior; this
file is about the codebase and build.

Target hardware: Apple Silicon, tuned specifically for **M1 / 8 GB**. Every
architecture decision in this repo is downstream of that RAM constraint — don't
suggest "just use a bigger model" without addressing memory.

## Build / run / test

```bash
swift build              # debug build
swift build -c release   # release build
swift test                # SottoCore unit tests (Tests/SottoTests)
./.build/debug/Sotto --run-tests    # runs integration tests
./.build/debug/Sotto --evaluate     # runs evaluation benchmarks (only in DEBUG)
```

Microphone, Accessibility, and Screen Recording permissions are needed for the full pipelines.

## Toolchain requirement

Requires **macOS 27 + Xcode 27 (Swift 6.4)**. The platform floor is macOS 27, and modern Apple Intelligence features are active by default.

**Known SDK-beta diagnostics (do not chase):** a full rebuild shows ~108 deprecation
warnings (`GenerationError` / `decodingFailure`), all from the `@Generable` macro
expansion on the project's 9 `@Generable` enums — Apple's macro emits a deprecated
fallback throw beside the new `ParsingError` path. Not fixable in project code; goes
away when the SDK's macro is fixed. Same category as the `installTapCompat` shim in
`AudioRecorder.swift`. Any warning NOT from a `@Generable` expansion is new — fix it.

## Model backend — what's active

**Apple Intelligence (Foundation Models / `SystemLanguageModel`) is the only model backend.** Every `LanguageModelSession` in this codebase runs on it — dictation polish, Jarvis command routing, and all sub-agent delegation. The chat/quick/bigJob lanes are built as plain per-lane `LanguageModelSession`s in `CoordinatorAgent` (the `DynamicProfile` API was retired after dyld symbol-not-found crashes; `JarvisProfile.classify` still picks the lane).

## Concurrency & Memory Pressure Management

1. **Memory Pressure Handling**: A DispatchSource memory pressure observer is registered in `AppController.swift`. On `.warning` or `.critical` signals, it unloads warm cached sub-agent sessions (`OSControlAgent`, `WebResearcherAgent`, `ScriptingExecutorAgent`, `CoordinatorAgent.shared`) and the polish session to free up unified memory. `AppController.coordinator` must stay `CoordinatorAgent.shared` — a private instance would hide its warm session from eviction. `MemoryLedger` counts evictions; the HUD ledger line is gated behind `SettingsController.showMemoryLedger` (debug default-off).
2. **Actor & MainActor Isolation**:
   - `ScreenParser`, `NativeClipboard`, and `ClipboardObserver` are isolated to `@MainActor`.
   - `GitObserver` is implemented as a Swift actor to prevent concurrent state mutation races.
   - All `NSAppleScript` and AppKit pasteboard calls must execute safely on the main thread/runloop.
3. **Deadlock Prevention in AudioRecorder**: CoreAudio background thread calls write to `silenceAccumulator` and `samples` inside a lock, but invoke the silence callback and the `onBuffer` streaming callback *outside* the lock context to prevent lock deadlocks when stop() is called.
4. **Streaming ASR single-consumer rule**: `DictationTranscriber.results` tolerates exactly ONE consumer. The live streaming pass (`Transcriber.startStreaming/finishStreaming`) owns it via a backend-held `StreamingSession`; batch `transcribe()` cancels any active session before consuming. On key-release, `AppController.endRecording` awaits the streaming setup task and prefers the streaming transcript (skipping a second ASR pass); nil falls back to batch over the recorded samples. Partial transcripts are HUD display ONLY — they must never route or execute commands (half-spoken text acting is a safety bug, and dictation must never trigger actions).

## Structured Output

The codebase uses `@Generable` structured output types with `respond(to:generating:options:)` to eliminate fragile string parsing:
- `TurnOutcome` struct for `CoordinatorAgent.handleTurn` to handle normal replies and `clarifyingQuestion`s cleanly.
- `SwiftScript` struct for `ScriptingExecutorAgent` to generate Swift code directly without markdown fences.

## Dictation transcription — native SpeechAnalyzer, not legacy SFSpeechRecognizer

`TranscriptionEngine.appleSpeech` (`Transcriber.swift`) runs on `NativeDictationBackend`
— the modern `SpeechAnalyzer` + `DictationTranscriber` stack (`import Speech`, macOS 26+)
— not the old delegate-callback `SFSpeechRecognizer` API. Key points for future work here:
- The `SpeechAnalyzer`/model is created once and cached on the `Transcriber` actor
  (`.lingering` model retention) so repeated dictation presses don't re-pay asset-install
  cost; it's released only when the user switches to the `.offlineAI` (Parakeet) engine.
- Custom vocabulary + learned jargon (same UserDefaults keys `SottoIntelligence` reads for
  the polish prompt) are injected via `AnalysisContext.contextualStrings` so the ASR layer
  gets names/jargon right at the source, not just via post-hoc polish correction.
- `LegacyAppleSpeechBackend` (the old `SFSpeechRecognizer` implementation) is kept in the
  same file as an internal fallback — not user-selectable — invoked automatically if the
  modern path throws during `prepare()` or `transcribe()` (e.g. on-device asset install
  fails). Don't delete it without confirming the modern path has proven stable in practice.
- `SottoIntelligence.refine()`'s polish instructions were tuned for a more premium/
  professional feel: paragraph breaks at topic boundaries and list formatting for
  enumerated speech, plus an explicit no-hallucinated-facts rule. `isAcceptablePolish()` in
  `DictationPipeline.swift` still guards against truncation/expansion/loop/unrelated-output
  regressions from any prompt change here.

## Voice activation — hotkey-only by default

Jarvis and Dictation are both hotkey-driven (`SettingsController.isPushToTalk` defaults
`true`). `WakeWordDetector`'s continuous-listening path only starts if
`SettingsController.isHandsFreeEnabled` is explicitly turned on in Settings (defaults
`false`) — it is dormant code, not deleted, so hands-free can be revisited later without
re-architecting. Don't wire it into the startup path or flip its default without asking.

## Architecture map

```
Voice → Parakeet (ANE, via FluidAudio) → transcript
                               ↓
        CommandEngine.checkZeroLatencyShortcut  ← instant, no AI (window tiling, volume, etc)
                               ↓
        isSiriNativeCommand → SiriBridge.send   ← delegates to Siri (weather, reminders, calls)
                               ↓
        CommandEngine.process (prefix rules)     ← "open chrome and search X" style parsing
                               ↓
        CoordinatorAgent (Apple Foundation Models)
          ├─ CommandLearner.hint → pre-select known tool  (learned from ≥3 uses, persisted)
          ├─ JarvisToolbox.routed (keyword scoring, max 5 tools)
          └─ DynamicProfile: chat / quick / bigJob lanes
                               ↓ (quick/bigJob lane escalation)
          Delegate*Tool → OSControlAgent / WebResearcherAgent / ScriptingExecutorAgent
                               ↓ (bulk work)
          StartLongTaskTool → LongTaskEngine (detached background job, non-blocking)
```

## Source modules

- `Sources/Sotto/` — executable target, AppKit + all platform code.
- `Sources/SottoCore/` — pure Swift, no AppKit, unit-testable (vocab correction, disfluency filtering, context detection). This is the target `swift test` covers.
