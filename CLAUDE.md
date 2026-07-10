# CLAUDE.md

Guidance for Claude Code (or any future agent) working in this repo.

## What this is

Sotto is a native Swift, on-device macOS voice assistant. Two modes: **Dictation**
(speak → polished text typed into whatever app is focused) and **Jarvis** (speak a
command → Sotto acts: opens apps, controls the OS, browses, drafts scripts, etc).
Full user-facing description is in `README.md` — read that first for behavior.
`PROJECT.md` is the architecture blueprint (system overview, design rationale).
This file is about the codebase, build, and known gotchas.

Target hardware: Apple Silicon, tuned specifically for **M1 / 8 GB**. Every
architecture decision in this repo is downstream of that RAM constraint — don't
suggest "just use a bigger model" without addressing memory.

## Build / run / test

```bash
swift build              # debug build
swift build -c release   # release build
swift test                # SottoCore unit tests (Tests/SottoTests)
swift test --filter VocabCorrectorTests   # run a single test class
./.build/debug/Sotto --run-tests    # runs integration tests
./.build/debug/Sotto --evaluate     # runs evaluation benchmarks (only in DEBUG; add --mock to force mock mode)
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

1. **Memory Pressure Handling**: A DispatchSource memory pressure observer is registered in `AppController.swift`. On `.warning` or `.critical` signals, it unloads warm cached sub-agent sessions (`OSControlAgent`, `WebResearcherAgent`, `ScriptingExecutorAgent`, `CoordinatorAgent.shared`), `JarvisBrain`, the transcriber's cached `SpeechAnalyzer`, and (on `.critical`) the polish session to free up unified memory. Anything new that holds a warm model or embedding must be added to this eviction list. `AppController.coordinator` must stay `CoordinatorAgent.shared` — a private instance would hide its warm session from eviction. `MemoryLedger` counts evictions; the HUD ledger line is gated behind `SettingsController.showMemoryLedger` (debug default-off).
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

Dictation (`Transcriber.swift`) runs on `NativeDictationBackend` — the modern
`SpeechAnalyzer` + `DictationTranscriber` stack (`import Speech`, macOS 26+) — not the old
delegate-callback `SFSpeechRecognizer` API. This is the ONLY transcription engine: the old
Parakeet/FluidAudio ANE backend and the user-facing engine picker were removed, so there is
no engine setting to switch. Key points for future work here:
- The `SpeechAnalyzer`/model is created once and cached on the `Transcriber` actor
  (`.lingering` model retention) so repeated dictation presses don't re-pay asset-install
  cost; the cached instance is only torn down after a failed/hung finalize (rebuilt on the
  next press).
- Custom vocabulary + learned jargon (same UserDefaults keys `SottoIntelligence` reads for
  the polish prompt) are injected via `AnalysisContext.contextualStrings` so the ASR layer
  gets names/jargon right at the source, not just via post-hoc polish correction.
- There is no fallback engine. If the modern path throws during `prepare()` or
  `transcribe()` (e.g. on-device asset install fails without network), the error
  propagates: `AppController.endRecording` surfaces it as an `.error` state and schedules
  recovery back to idle. The old `LegacyAppleSpeechBackend` (`SFSpeechRecognizer`) was
  removed — don't reintroduce a legacy recognizer; harden the `SpeechAnalyzer` path instead.
- `SottoIntelligence.refine()`'s polish instructions were tuned for a more premium/
  professional feel: paragraph breaks at topic boundaries and list formatting for
  enumerated speech, plus an explicit no-hallucinated-facts rule. `isAcceptablePolish()` in
  `DictationPipeline.swift` still guards against truncation/expansion/loop/unrelated-output
  regressions from any prompt change here.

## Voice activation — hotkey-only

Jarvis and Dictation are both hotkey-driven (`SettingsController.isPushToTalk` defaults
`true`). There is no hands-free / wake-word path: the old `WakeWordDetector` (continuous
`SFSpeechRecognizer` listening) and its `isHandsFreeEnabled` setting were removed. If
hands-free is ever revisited, build it on the modern `SpeechAnalyzer` stack rather than
resurrecting the legacy recognizer.

## Architecture map

The Jarvis hotkey path is `JarvisPipeline.runJarvisPipeline` — a layered dispatch
where the cheapest layer that can handle the utterance wins and later layers never
run. Order matters; new fast paths go in the right layer, not bolted on top:

```
Voice → AudioRecorder (16 kHz mono) → SpeechAnalyzer/DictationTranscriber (on-device) → transcript
                               ↓
        skill approval gate ("enable skill X")   ← user-only; the ONLY way a drafted skill becomes runnable
                               ↓
        CommandEngine.checkZeroLatencyShortcut   ← instant, no AI (window tiling, volume, etc)
                               ↓
        deterministic weather (WeatherService)   ← keyless API call, bypasses the model
                               ↓
        Kernel.dispatchCompound                  ← microkernel reflex router: CapabilityRegistry picks the
                                                    cheapest capable path; pure-Swift reflexes run with 0 tokens,
                                                    higher-tier intents return nil and fall through
                               ↓
        JarvisBrain.recall                       ← associative command memory: NLEmbedding sentence similarity
                                                    matches learned/seeded phrases by MEANING; learned tool
                                                    replays are gated by `directExecutionAllowlist` (checked at
                                                    execution time — destructive tools stay behind the LLM)
                               ↓
        CoordinatorAgent (Apple Foundation Models)
          ├─ CommandLearner.hint → pre-select known tool  (learned from ≥3 uses, persisted;
          │                        also feeds JarvisBrain when args are stable)
          ├─ JarvisToolbox.routed (keyword scoring, max 5 tools)
          └─ JarvisProfile.classify → per-lane LanguageModelSession: chat / quick / bigJob
                               ↓ (quick/bigJob lane escalation)
          Delegate*Tool → OSControlAgent / WebResearcherAgent / ScriptingExecutorAgent
                               ↓ (bulk work)
          StartLongTaskTool → LongTaskEngine (detached background job, non-blocking)
                               ↓
        CommandEngine.orchestratorAction         ← Claude-popover orchestration fallback
```

Siri delegation is NOT a layer in this voice pipeline: `isSiriNativeCommand` →
`SiriBridge.send` lives in `CommandEngine.process` (the text-command entry point,
`handleIncomingCommandText`), and the model can also reach Siri via the `ask_siri`
tool in the registry.

## Source modules

- `Sources/Sotto/` — executable target, AppKit + all platform code.
- `Sources/SottoCore/` — pure Swift, no AppKit, unit-testable (vocab correction, disfluency filtering, context detection). This is the target `swift test` covers.
