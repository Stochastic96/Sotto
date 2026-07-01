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
./.build/release/Sotto    # run after release build
```

There's no headless way to exercise the Jarvis/Dictation pipelines from the CLI —
they need Microphone, Accessibility, and Screen Recording permissions granted to
the running binary. Manual verification means actually running the app.

`swift build` currently emits one pre-existing, unrelated warning in
`HUDOverlay.swift:328` (implicit NSApp unwrap) — not something introduced by recent
work, safe to ignore.

## Toolchain requirement

Requires **macOS 27 + Xcode 27 (Swift 6.4)**. The `SOTTO_FM27` build flag (see
below) specifically needs Swift 6.4 — Swift 6.3.2 declares the symbols in the SDK
but can't actually see them, so code gated behind it silently falls back rather
than failing to build. Check `swift --version` before assuming that flag is usable
on a given machine.

## Model backend — what's actually active right now

**Apple Intelligence (Foundation Models / `SystemLanguageModel`) is the only model
backend currently compiled into the app.** Every `LanguageModelSession` in this
codebase runs on it — dictation polish, Jarvis command routing, and all sub-agent
delegation.

The on-device Qwen 0.5B-via-MLX path (`MLXEngine.swift`) still exists in source and
is architecturally wired in (`SottoIntelligence` tries MLX first, falls back to
Apple Intelligence) — but `Package.swift` currently has **no MLX package
dependencies and no `SOTTO_MLX` flag**, so `MLXEngine.prepareIfNeeded()` always
returns `false` at runtime and every call falls straight through to Apple
Intelligence. This was a deliberate choice (running Qwen + Apple Intelligence
concurrently on 8 GB was worse than either alone) — don't "fix" this by silently
re-adding the MLX packages without asking; confirm with the user first, since
they've toggled this off and on before while tuning RAM behavior.

If you need to re-enable MLX: add back the `mlx-swift-lm` / `swift-huggingface` /
`swift-transformers` packages to `Package.swift` dependencies, the corresponding
products to the `Sotto` target, and `.define("SOTTO_MLX")` to `swiftSettings`.

## The `SOTTO_FM27` flag — lane system

`Package.swift` → `swiftSettings: [.define("SOTTO_FM27")]` (enabled as of
2026-07-01). This activates `JarvisProfile.swift`'s `DynamicProfile`-based lane
system in `CoordinatorAgent.swift`: turns are classified into `chat` / `quick` /
`bigJob` lanes, each with a different tool set, `toolCallingMode`, and temperature,
expressed as native Apple `LanguageModelSession.Profile`s rather than one big
always-on tool list. This is meaningfully cheaper per-turn than the macOS-26
hand-built fallback path (which always assembles up to 12 tool schemas into the
prompt regardless of what was said) — it's the main lever for reducing per-turn
cost on 8 GB, not model size.

The DynamicProfile path has a 40-second internal timeout
(`CoordinatorAgent.swift`, `handleTurn`) and falls back to the macOS-26 hand-built
session path on any failure — so a regression here fails soft, not hard. If you
change `JarvisProfile.classify()`'s heuristics, know that `.chat` disallows tools
entirely and `.bigJob` *requires* `start_long_task` — a genuine command misclassified
as `.chat` will silently do nothing but reply with one line.

## Session reuse in sub-agents (fixed 2026-07-01)

`OSControlAgent`, `WebResearcherAgent`, `ScriptingExecutorAgent` (bottom of
`CoordinatorAgent.swift`) are **actors with a cached `LanguageModelSession`**,
recreated only every 12 turns (same bound as `SottoIntelligence`'s polish session).
They used to be stateless classes that built a brand-new session — full
instructions + tool schema reprocessing — on every single delegation call. If
you're debugging a "sub-agent forgot context between calls" issue, this is why it
now *doesn't*: turns within the 12-turn window share the same session transcript.
If you need per-call isolation instead (e.g. a sub-agent call must never see a
prior unrelated task), call `.unload()` on the relevant agent's `.shared` instance
before the call, or lower the reuse bound.

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
          ├─ JarvisToolbox.routed (keyword scoring)        (fallback tool selection)
          └─ DynamicProfile: chat / quick / bigJob lanes   (SOTTO_FM27, macOS 27+)
                              ↓ (quick/bigJob lane escalation)
          Delegate*Tool → OSControlAgent / WebResearcherAgent / ScriptingExecutorAgent
                              ↓ (bulk work)
          StartLongTaskTool → LongTaskEngine (detached background job, resumable, non-blocking)
```

Dictation polish: `MLXEngine` (currently inert, see above) → falls through to
`SottoIntelligence`'s dedicated prewarmed Apple Intelligence session → `TextInjector`.

Three source modules:
- `Sources/Sotto/` — executable target, AppKit + all platform code, ~85 files.
- `Sources/SottoCore/` — pure Swift, no AppKit, unit-testable (vocab correction,
  disfluency filtering, context detection). This is the only target `swift test`
  actually covers.
- `Sources/SottoInfra/` — referenced in README as shared infra (EventBus,
  CapabilityRegistry, LaneStats) — currently these types live in `Sources/Sotto/`
  directly rather than a separate target; README's layout diagram is aspirational
  here, not current fact.

## Known open items (as of 2026-07-01)

- **`.env` has a live-looking Gemini API key committed to disk in plaintext.** It's
  untracked by git (safe for now) but **not** in `.gitignore` — one `git add .` or
  `git add -A` away from landing in the repo. `GEMINI_API_KEY` / `GoogleGenerativeAI`
  don't appear to be referenced anywhere in `Sources/`, so this may be a dead
  dependency with a live credential attached. Flag before touching — don't rotate
  or delete without asking, in case it's mid-setup for something.
- **`PhoneRemote.swift` (new, staged) is in-progress work-in-progress**: a local
  HTTP server (`Network` framework, port 52027) letting an iPhone Shortcut POST
  dictated text to Sotto over local Wi-Fi, auth'd via a token shown in the status
  bar menu. Touches `AppController.swift`, `AudioRecorder.swift`,
  `NativeSystemOrchestrator.swift` (added `purgeRAM()`), `ResilientNetworkClient.swift`,
  `StatusBarController.swift` — all currently unstaged/uncommitted. Don't assume
  these are finished or revert them without checking with the user first.
- A few code paths hard-code `~/Projects/Sotto` (per README) — grep before
  assuming portability if the repo is ever cloned elsewhere.
- `.agents/` at repo root is a completed historical record from a prior
  multi-agent orchestration session (2026-06-22) that originally built
  `CoordinatorAgent`/`ScreenParser`/`SwiftScriptRunner`. It references a
  `PROJECT.md` that no longer exists on disk — `PROJECT.md` at repo root (see
  below) was recreated from scratch on 2026-07-01 to reflect current reality, not
  restored from that session.

See `PROJECT.md` for the fuller architecture/design writeup.
