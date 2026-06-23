# JARVIS — Complete Architecture Blueprint
> Feed this document to Claude (or any coding agent) along with your codebase.
> It describes what exists, what works, what needs improvement, and what to build next.
> Last updated: 2026-06-23

---

## 1. What This Project Is

**Sotto / JARVIS** is a macOS menu-bar voice assistant that runs *inside the OS*, not inside a browser.
It answers hotkey presses and a wake word, records audio, transcribes speech, routes the intent through a three-tier decision engine, and either types text back into any app, executes native tools, or delegates to AI sub-agents — all without leaving the machine.

The design philosophy is:

- **Deterministic first.** Rules beat AI when speed and accuracy are predictable.
- **Local by default.** Apple Intelligence (on-device) beats cloud AI when possible.
- **Cloud as fallback.** MLX (on-device Qwen) or Claude CLI are last resorts.
- **Act, don't chat.** Tools execute. Replies are one line. No menus.
- **User controls execution.** The agent can *write* skills autonomously. Only the user can *run* them.

---

## 2. Current State — What You Have Built

### 2.1 Core Pipeline

```
Hotkey / WakeWord / SiriOS
        ↓
  AudioRecorder (FluidAudio PCM)
        ↓
  Transcriber (FluidAudio Whisper, on-device)
        ↓
  AppController.endRecording()
        ↓
  ┌─────────────────────────────┐
  │  mode = .dictation           │  → runDictationPipeline → QwenRefiner → TextInjector
  │  mode = .jarvis              │  → runJarvisPipeline  (see §2.3)
  └─────────────────────────────┘
```

### 2.2 Files and Their Roles

| File | Role | Quality |
|---|---|---|
| `AppController.swift` | Root orchestrator, state machine, both pipelines | ⚠️ Too large (1 456 lines). Needs splitting. |
| `CommandEngine.swift` | Rules-based command router, zero-latency shortcuts | ⚠️ Too large (1 837 lines). Needs decomposition. |
| `JarvisAgent.swift` | Intent classifier, single-hop tool-calling agent | ✅ Clean, well-structured |
| `CoordinatorAgent.swift` | Multi-hop coordinator, delegates to sub-agents | ✅ Good multi-agent design |
| `JarvisTools.swift` | 27+ Foundation Models Tool implementations | ✅ Well structured, uses `@Generable` correctly |
| `LongTaskEngine.swift` | Resumable bulk background jobs | ⚠️ Only email promo; needs generalization |
| `SkillStore.swift` | Agent-authored skills with user approval gate | ✅ Solid design |
| `SemanticMemory.swift` | NLEmbedding vector store, cosine recall | ✅ Correct and efficient |
| `QwenRefiner.swift` | On-device Qwen polish for dictation | ✅ Good |
| `MLXEngine.swift` | MLX inference server (Qwen fallback for agents) | ✅ Good |
| `ScreenParser.swift` | Accessibility tree capture + OCR click | ✅ Clever |
| `SystemMemoryStore.swift` | Key-value session memory | ✅ Simple, useful |
| `TaskJournal.swift` | Persistent activity log | ✅ Good |
| `SottoCore/` | Testable pure-Swift: ContextDetector, PromptBudget, PromptPrep, Quips, VocabCorrector | ✅ Excellent separation |
| `Tests/SottoTests/` | FormattingStyle, PromptBudget, PromptPrep, Quips, VocabCorrector | ✅ Good test coverage of core |
| `AppIntentsBridge.swift` | App Intents shell (exists, state unknown) | ❓ Needs audit |
| `EventKitOrchestrator.swift` | Calendar/Reminders (exists, not wired to main flow) | ❓ Needs wiring |
| `SiriBridge.swift` | Forward prompts to Apple Intelligence text box | ✅ Works |
| `WeatherService.swift` | Deterministic weather lookup | ✅ Bypasses model correctly |
| `MailConnector.swift` | Apple Mail AppleScript bridge for LongTaskEngine | ✅ Correct scope |
| `JarvisProfile.swift` | DynamicProfile for macOS 27 lane control | ✅ Forward-looking |
| `WakeWordDetector.swift` | Hands-free trigger | ✅ Works |

### 2.3 Jarvis Pipeline (Three-Tier Speed Model)

```
Spoken command
        ↓
Tier 0 — Deterministic (CommandEngine.checkZeroLatencyShortcut / process)
  ~50 commands: window tiling, browser, Spotify, volume, dark mode, Wikipedia, Maps…
  Cost: 0 tokens, 0–5 ms. Returns immediately.
        ↓ (if not matched)
Tier 1 — Apple Intelligence tool-calling (JarvisAgent / CoordinatorAgent)
  JarvisToolbox.routed(for:) picks ≤8 of 27 tools relevant to the utterance.
  Foundation Models runs the tool-calling loop natively.
  Cost: 0 API cost, ~200–600 ms cold / ~100 ms warm.
        ↓ (if Apple Intelligence unavailable or context exceeded)
Tier 2 — MLX (on-device Qwen) or Claude CLI
  WebResearcherAgent, ScriptingExecutorAgent fall back to this path.
  ReAct loop: Thought → Action → Observation × N turns.
  Cost: local GPU, ~1–3 s per turn.
```

### 2.4 Multi-Agent Architecture

```
CoordinatorAgent (front door, retains session across clarification turns)
   ├── JarvisToolbox (27 native tools — executes inline via Foundation Models)
   ├── DelegateOSControlTool → OSControlAgent (system tasks via tool-calling)
   ├── DelegateWebResearcherTool → WebResearcherAgent (screen OCR + click + Wikipedia)
   ├── DelegateScriptingExecutorTool → ScriptingExecutorAgent (generates + runs Swift scripts)
   └── StartLongTaskTool → LongTaskEngine (bulk background jobs, resumable)
```

### 2.5 Memory Architecture

```
SemanticMemory (NLEmbedding, 400 entries, cosine recall)
    ← remembered via: RememberAboutMeTool, TaskJournal, UserProfile
    → recalled via: CoordinatorAgent.buildInstructions(), SearchMemoryTool

SystemMemoryStore (key-value, in-process + UserDefaults)
    ← written by: MemoryGoalTool, WikipediaLookupTool (cache)
    → read by: tools, CommandEngine

UserProfile (typed key-value preferences)
    ← written by: RememberAboutMeTool, CommandEngine "remember that"
    → injected into: every CoordinatorAgent session instructions
```

### 2.6 Skill System

```
Agent observes repeated pattern
        ↓
DraftSkillTool → SkillStore.draft() → saves as DISABLED + indexes in Spotlight
        ↓
User says "enable skill <name>"
        ↓
SkillStore.enable() → writes script to disk, flips enabled = true
        ↓
RunSkillTool / "run skill <name>" → SkillStore.runEnabled() → shell/AppleScript
```

---

## 3. What Works Well — Do Not Break These

1. **Tool routing** (`JarvisToolbox.routed(for:)`) — routing ≤8 tools per utterance is the single biggest accuracy win. Do not send the full 27-tool catalog every call.

2. **Deterministic pre-checks in CommandEngine** — these handle ~80% of commands with zero AI cost. They must stay first in the pipeline.

3. **Dual-mode separation** — dictation hotkey (⌘⇧K) and Jarvis hotkey (⌘⇧J) are completely independent. Do not merge them.

4. **Skill approval gate** — `SkillStore.runEnabled()` refuses anything not explicitly approved. Do not weaken this.

5. **SemanticMemory with NLEmbedding** — no model download, fits 8 GB budget, recall is fast for 400 entries.

6. **SottoCore separation** — testable pure-Swift logic kept separate from AppKit/FoundationModels. Keep adding logic there rather than into AppController.

7. **LongTaskEngine persistence** — saves after every batch; `resumePending()` on launch. Pattern is correct for bulk work on an 8 GB machine.

8. **Context-window shedding** in CoordinatorAgent — retries tool-free on `exceededContextWindowSize`. Keep this.

9. **PromptBudget, PromptPrep, VocabCorrector, Quips** in SottoCore — all have test coverage. Don't touch without running tests.

---

## 4. What Needs Improvement — Priority Order

### P0 — Urgent (breaks scalability)

**4.1 Split AppController.swift (1 456 lines)**

AppController owns too many responsibilities: state machine, dictation pipeline, Jarvis pipeline, polish sanity checks, wake-word routing, error recovery, vocab learning, dataset logging, Siri bridge, weather shortcut, and clarification flow.

Split into:
- `AppController.swift` — state machine + lifecycle only (~200 lines)
- `DictationPipeline.swift` — listen → transcribe → polish → inject
- `JarvisPipeline.swift` — route → tier0 → tier1 → tier2 → speak
- `ErrorRecovery.swift` — `scheduleErrorRecovery`, model-load retry
- Keep all the same behavior; just move code.

**4.2 Split CommandEngine.swift (1 837 lines)**

The current file is a massive switch/if-else chain. Add at minimum:
- `WindowCommands.swift` — window tiling, resize, center
- `BrowserCommands.swift` — tabs, back/forward, reload
- `MediaCommands.swift` — Spotify, volume, brightness
- `AIOrchestrationCommands.swift` — ask ChatGPT/Claude/Gemini/Perplexity
- `SearchCommands.swift` — Wikipedia, Maps, LinkedIn, Google Ads

`CommandEngine.process()` becomes a dispatcher that calls into these.

### P1 — Important (unlocks new capabilities)

**4.3 Wire EventKitOrchestrator into the main flow**

`EventKitOrchestrator.swift` exists but is not reachable from the Jarvis pipeline. Add a `CalendarTool` and `RemindersTool` to `JarvisTools.swift` backed by EventKit:
```swift
@available(macOS 26.0, *)
struct CreateCalendarEventTool: Tool {
    let name = "create_calendar_event"
    let description = "Create a calendar event with a title, date, and optional time."
    @Generable struct Arguments {
        let title: String
        let dateDescription: String   // e.g. "tomorrow at 3pm"
        let calendar: String?
    }
    func call(arguments: Arguments) async throws -> String { … }
}
```
Use `EventKit.EKEventStore` with `requestFullAccessToEvents()`.

**4.4 Generalize LongTaskEngine**

Currently hard-coded to email promo cleanup only. The engine's batch/resume/persist pattern is excellent — the routing is the problem.

Add a second job type: `bulkFileOrganizer` (move files matching a pattern to a folder). This proves the generalization works.

Pattern:
```swift
enum LongTaskJob {
    case emailPromoCleanup
    case fileOrganizer(sourcePath: String, pattern: String, destPath: String)
    // next: calendarCleanup, contactDedup, ...
}
```

**4.5 Audit and activate AppIntentsBridge**

`AppIntentsBridge.swift` exists. Audit whether it exposes Jarvis commands as proper `AppIntent` conformers. If not, implement at minimum:

```swift
struct RunJarvisCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Jarvis Command"
    @Parameter(title: "Command") var command: String
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await CoordinatorAgent().handleTurn(userInput: command)
        return .result(value: result)
    }
}
```

This makes every Jarvis command available to Siri, Shortcuts, and Apple Intelligence automatically.

**4.6 Make the Skill trigger phrase live**

When a skill is enabled, its `trigger` phrase should be registered with `CommandEngine` so it runs without saying "run skill X". Currently this registration is missing.

Add to `SkillStore.enable()`:
```swift
CommandEngine.registerSkillTrigger(skill.trigger, skillName: skill.name)
```
And in `CommandEngine.process()`, check registered triggers before the Tier-1 AI call.

### P2 — Nice to Have (quality of life)

**4.7 Add macOS Shortcuts actions for top 10 commands**

Export these as `AppIntent`s so users can build Shortcuts automations:
- Open app
- Web search
- Play Spotify song
- Set volume
- Create note
- Create reminder
- Create calendar event
- Run skill
- Remember fact
- System status

**4.8 Add a `CalendarContextTool`**

Before any task planning, Jarvis should know "do you have meetings in the next 2 hours?". Add:
```swift
struct GetTodayScheduleTool: Tool {
    let name = "get_today_schedule"
    let description = "Get today's calendar events and next upcoming events, so you can suggest appropriate timing for tasks."
    …
}
```

**4.9 Strengthen WebResearcherAgent's ReAct loop**

The current MLX fallback parses `Action: search(query: "…")` by string matching. This is fragile. Use Foundation Models guided generation for the action decision step instead of free-form text parsing.

**4.10 Add a `PersonaLanguageTool`**

The CommandEngine has Hindi responses hardcoded in `ZeroLatencyShortcut.voiceFeedback` but the agent replies are always English. Add a user preference `UserProfile.responseLanguage` that CoordinatorAgent appends to its system instructions:
```
Reply in the user's preferred language: Hindi (Devanagari script).
```

---

## 5. What NOT to Build (Anti-patterns to Avoid)

1. **Do not add a persistent server process.** The whole point is a lightweight menu-bar app. No daemons, no background XPC servers beyond what the OS provides.

2. **Do not send the full 27-tool catalog every request.** Tool routing (`JarvisToolbox.routed`) is a solved problem. Reverting to "always all tools" will kill accuracy on the small on-device model.

3. **Do not skip the skill approval gate.** The agent generating and immediately executing its own code is dangerous. The `SkillStore.runEnabled()` pattern is correct. Do not add an "auto-approve" flag.

4. **Do not add more than ~50 deterministic shortcuts.** Beyond that, patterns are better handled by the AI tier. The current ~50 is about right.

5. **Do not add a large persistent chat UI.** Sotto is a heads-up display (HUDOverlay), not a chat app. If the user wants a chat UI, they can say "ask Claude" — that opens the Claude app.

6. **Do not download models at runtime without a progress indicator.** The QwenRefiner pattern (status callback with download percentage) is correct. Copy it for any new on-device model.

7. **Do not use DispatchQueue where async/await suffices.** SemanticMemory uses a serial `DispatchQueue` for its IO queue — that's correct for its old-style synchronous `NLEmbedding` API. Everywhere else, use `async/await`.

8. **Do not force-unwrap optionals in Tool implementations.** If a tool crashes, the Foundation Models session silently drops the turn. Validate inputs and return descriptive error strings.

---

## 6. Apple Frameworks — Complete Inventory

### 6.1 Already Used

| Framework | Usage |
|---|---|
| `FoundationModels` | Intent classification, tool-calling, guided generation (`@Generable`, `@Guide`) |
| `NaturalLanguage` | `NLEmbedding` for semantic memory vectors |
| `CoreSpotlight` | Indexing skills and memory entries for Spotlight search |
| `Vision` | Screen OCR (`VNRecognizeTextRequest`) |
| `ScreenCaptureKit` | Screen capture for OCR |
| `AVFoundation` | Audio recording, `AVSpeechSynthesizer` TTS |
| `AppKit` | Menu bar, HUD, windows, notifications |
| `NSWorkspace` | App launch, app switch notifications |
| `Accessibility (AX)` | Screen tree capture, click synthesis, text injection |
| `MLX / mlx-swift-lm` | On-device Qwen inference (fallback) |
| `FluidAudio` | On-device Whisper transcription |
| `EventKit` | Exists in EventKitOrchestrator (not wired to main flow) |
| `UserNotifications` | (inferred from HUD patterns) |
| `CoreML` | (via MLX indirectly) |

### 6.2 Should Be Added

| Framework | Purpose | Priority |
|---|---|---|
| `AppIntents` | Expose commands to Siri, Shortcuts, Apple Intelligence | P1 |
| `EventKit` (wired) | Calendar + Reminders tools reachable by agent | P1 |
| `Contacts` | "Who is X?" → contact lookup before Wikipedia | P2 |
| `Photos` | "Show me photos of my trip to X" | P3 |
| `PDFKit` | "Summarize this PDF" via drag-drop or current file | P2 |
| `BackgroundTasks` | Register `BGProcessingTask` for LongTaskEngine jobs | P2 |
| `FSEvents` (via FileManager notifications) | Watch Downloads folder, trigger smart skill suggestions | P3 |
| `Network` (NWPathMonitor) | Detect offline mode, skip cloud paths | P2 |

---

## 7. Swift Macros — What You Have and What You Can Use

### 7.1 Already Used

`@Generable` and `@Guide` — from `FoundationModels`. Applied to every tool's `Arguments` struct and to constrained generation types like `Routing`, `PromoBatchDecision`, `SpotifyAction`. These are the most important macros in the project.

```swift
@Generable
struct Arguments {
    @Guide(description: "The song or artist to search for.")
    let query: String?
}
```

This eliminates JSON parsing and schema validation. The framework enforces the contract at generation time. **Use this pattern for every new tool.**

### 7.2 Foundation Models Macros You Should Know

| Macro | Purpose |
|---|---|
| `@Generable` | Make a struct/enum a valid generation target (adds schema, init) |
| `@Guide(description:)` | Document a field — the model sees this as a constraint |
| `@Guide(options:)` | Restrict a String field to a finite set of values |
| `@Guide(minimum:maximum:)` | Restrict an Int/Double to a range |

Use `@Guide(options:)` instead of a free-form String when the valid values are known:
```swift
@Guide(options: ["shell", "applescript"])
let language: String
```

### 7.3 Swift Standard Macros You Can Use

| Macro | Purpose | Where to use |
|---|---|---|
| `@Observable` | Modern replacement for `ObservableObject` (Swift 5.9+) | SettingsController, StatusBarController if they need SwiftUI |
| `@MainActor` | Already used extensively — correct pattern |
| `#Preview` | SwiftUI previews for HUDOverlay if you add SwiftUI views | HUDOverlay |
| `@dynamicMemberLookup` | Proxy access to nested structs | Could simplify UserProfile access |

### 7.4 Future: Build a `@Skill` Macro

When you have multiple skills, a custom macro would eliminate boilerplate:

```swift
// Today (manual):
struct OpenSpotifySkill: Tool {
    let name = "open_spotify"
    let description = "Open Spotify and start playing."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String { … }
}

// Future (macro-generated):
@Skill(
    name: "open_spotify",
    description: "Open Spotify and start playing.",
    trigger: "open spotify"
)
func openSpotify() async -> String { … }
```

This is a `@attached(peer)` macro that synthesizes the `Tool` conformance. It is worth building once you have 40+ tools.

---

## 8. Architecture Patterns — How to Approach New Work

### 8.1 Adding a New Native Tool

1. Define a `@Generable Arguments` struct with `@Guide` annotations.
2. Implement `Tool` conformance with a descriptive `name` and `description`.
3. Add it to `JarvisToolbox.all()`.
4. Add its keyword group to `JarvisToolbox.routed(for:)` so it is only sent when relevant.
5. Write a unit test for the tool's logic if it involves non-trivial computation.

### 8.2 Adding a New Deterministic Shortcut

1. Add a `case` to `CommandEngine.checkZeroLatencyShortcut()`.
2. The `command` string uses the `native:` prefix scheme.
3. Handle the `native:` command in `NativeActions.swift` or the relevant handler.
4. Add the Hindi (`voiceFeedback`) and HUD message strings.
5. If the command has more than 3 variants, add a unit test verifying all variants match.

### 8.3 Adding a New Long Background Job

1. Add a new case to `LongTaskJob` (once it is generalized per §4.4).
2. Implement a `run(_ task: inout LongTask)` function.
3. Use the batch/persist/resume pattern from `emptyPromotionalInbox`.
4. Add keyword detection to `LongTaskEngine.supports(goal:)`.
5. Gate execution behind a user confirmation if the action is destructive (deletion, move).

### 8.4 Adding a New Sub-Agent

1. Create a new `class XxxAgent` following the `OSControlAgent` pattern.
2. Add a `DelegateToXxxTool` in `CoordinatorAgent.swift`.
3. Add it to the escalation list in `CoordinatorAgent.handleTurn()`.
4. Keep the sub-agent's tool list focused (≤6 tools) — sub-agents are specialists.

---

## 9. Three-Tier Decision Model — How Routing Works

```
Utterance
    │
    ├─[Tier 0]─ CommandEngine.checkZeroLatencyShortcut()
    │            Exact or near-exact string match.
    │            Returns immediately with a native command string.
    │            ~50 commands. Cost: 0 tokens.
    │
    ├─[Tier 0b]─ CommandEngine.process()
    │             Prefix/pattern matching (wikipedia, click, ask chatgpt, etc.)
    │             Deterministic execution. Cost: 0 tokens.
    │
    ├─[Tier 1]─ CoordinatorAgent.handleTurn() via Apple Intelligence
    │            JarvisToolbox.routed(for:) selects ≤8 tools.
    │            Foundation Models runs the tool loop.
    │            ~100–600 ms. Cost: 0 API tokens.
    │
    └─[Tier 2]─ MLX (Qwen, on-device) or Claude CLI
                 Fallback when Apple Intelligence is unavailable.
                 ReAct loop, 256 token/turn cap.
                 ~1–3 s per turn.
```

This tiered model is the most important architectural decision in the project. Always ask: "Can Tier 0 handle this?" before writing Tier 1 or 2 code.

---

## 10. Memory Architecture — Complete Picture

```
┌─────────────────────────────────────────────────┐
│                   MEMORY LAYERS                  │
├─────────────────────────────────────────────────┤
│ L1: In-process session (SystemMemoryStore)       │
│     Key-value, lost on quit.                     │
│     Use for: current task, Wikipedia cache,      │
│     active goals within a session.               │
├─────────────────────────────────────────────────┤
│ L2: UserDefaults (UserProfile, SkillStore)       │
│     Typed preferences, learned vocabulary,       │
│     skill manifest. Survives quit.               │
│     Use for: durable user preferences,           │
│     enabled skills, app settings.               │
├─────────────────────────────────────────────────┤
│ L3: JSON on disk (SemanticMemory, LongTask)      │
│     Embedding vectors (400 entries max),         │
│     in-progress bulk jobs.                       │
│     Use for: what Jarvis has learned about       │
│     the user, journal, resumable jobs.           │
├─────────────────────────────────────────────────┤
│ L4: Spotlight index (SkillStore, SemanticMemory) │
│     Makes skills and memories discoverable       │
│     from the macOS search bar.                   │
└─────────────────────────────────────────────────┘
```

**Rule:** Only write to L3 (disk) for facts the user would want Jarvis to remember across many sessions. L1 is for ephemeral task context. L2 is for explicit preferences. L3 is for learned facts and conversation memories.

---

## 11. Resource Constraints (8 GB Unified Memory)

The M1 8 GB machine is the primary deployment target. Resource budget:

| Component | Peak RAM | Notes |
|---|---|---|
| macOS + active apps | ~3–4 GB | Not controllable |
| Apple Intelligence (on-device FM) | ~1.5–2 GB | Loaded/unloaded by OS |
| MLX Qwen (loaded on demand) | ~1.5–2 GB | Unload when not needed |
| FluidAudio Whisper | ~300 MB | Loaded at startup |
| Sotto process itself | ~50–100 MB | Keep lean |
| Available headroom | ~0–1 GB | Tight |

**Consequences:**
- Never load both Apple Intelligence and MLX at the same time if possible.
- The existing `QwenRefiner.forceUnload()` pattern is correct — follow it for any new model.
- Keep `SemanticMemory` capped at 400 entries (each vector is ~300 doubles = ~2.4 KB = 960 KB total — fine).
- Tool schemas add ~100–200 tokens each. Routing to ≤8 tools saves ~1 900 tokens vs. full catalog. Keep routing.

---

## 12. Security and Safety Model

1. **SkillStore approval gate** — agent can `draft`, user must `enable`. Never bypass.
2. **Accessibility must be granted** — checked before every recording start (`AXIsProcessTrusted()`).
3. **Screen recording permission** — checked at startup with `CGPreflightScreenCaptureAccess()`.
4. **Microphone permission** — requested via `AVCaptureDevice.requestAccess(for: .audio)`.
5. **No API keys in source** — all network calls (Wikipedia, Nominatim) are keyless public APIs.
6. **SwiftScriptRunner** — runs generated code in a subprocess, not in-process. Correct.
7. **User confirmation for destructive LongTask jobs** — currently only email cleanup. If adding file deletion, add a confirmation HUD step before the first batch.
8. **Shell injection risk** in `SkillStore.runEnabled` — the `osascript "path"` and `bash "path"` commands use the full file path. If the path contains spaces or special characters, this could break. Fix: use `Process.arguments` array, not a shell string:

```swift
// Safer:
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/bash")
process.arguments = [fileURL.path]
```

---

## 13. Testing Strategy

### 13.1 What Has Tests

- `SottoCore/`: FormattingStyle, PromptBudget, PromptPrep, Quips, VocabCorrector — all covered.

### 13.2 What Should Have Tests

| Module | Test Type | What to Test |
|---|---|---|
| `CommandEngine.checkZeroLatencyShortcut` | Unit | All ~50 phrases map to correct commands |
| `CommandEngine.process` | Unit (mock tools) | Routing decisions for key phrase patterns |
| `JarvisToolbox.routed(for:)` | Unit | Correct tool subset selected per utterance |
| `SemanticMemory` | Integration | Store, recall, cosine ordering |
| `SkillStore` | Unit | Draft/enable/runEnabled flow, approval gate |
| `LongTaskEngine` | Integration (mock MailConnector) | Batch/persist/resume cycle |
| `CoordinatorAgent` | Integration (mock mode) | Mock mode already exists — wire to XCTest |

### 13.3 Mock Mode

`CoordinatorAgent.isMockMode = true` is already implemented. Use it in integration tests to exercise the coordinator loop without running Apple Intelligence. Extend mock mode to `OSControlAgent` and `WebResearcherAgent` for full pipeline tests.

---

## 14. Development Roadmap

### Version 1 (Current) — Solid Foundation ✅
- Dual-mode dictation and Jarvis pipelines
- Three-tier routing (deterministic → Apple FM → MLX)
- 27 native tools
- Multi-agent architecture (Coordinator + 3 sub-agents)
- Semantic memory
- Skill drafting with approval gate
- Long-task engine (email cleanup)
- Spotlight indexing

### Version 2 — Wired Capabilities
- P0: Split AppController and CommandEngine into focused files
- P1: Wire EventKit (Calendar + Reminders tools reachable by agent)
- P1: Audit and activate AppIntentsBridge (Siri + Shortcuts integration)
- P1: Register skill trigger phrases with CommandEngine dynamically
- P1: Generalize LongTaskEngine beyond email

### Version 3 — Smarter Context
- P2: CalendarContextTool (Jarvis knows your schedule before suggesting tasks)
- P2: PDFKit integration ("summarize the PDF I just downloaded")
- P2: Contacts integration for person lookup
- P2: BackgroundTasks registration for LongTaskEngine jobs
- P2: Network (NWPathMonitor) for graceful offline degradation

### Version 4 — Self-Improvement
- Build `@Skill` macro to eliminate tool boilerplate
- Auto-discover enabled skills as CommandEngine shortcuts
- Skill composition (chain two skills into one)
- Skill testing mode (dry-run before enable)
- Skill versioning (update a skill without re-approving from scratch)

### Version 5 — Plugin Ecosystem
- Drop-in skill folder: `~/Library/Sotto/Skills/*.swift`
- Auto-compile and register dropped-in skills (user must approve)
- Skill sharing format (JSON with body + metadata)

---

## 15. Instructions for Claude When Working on This Codebase

When you receive this blueprint along with the source code, follow these rules:

1. **Read before writing.** The codebase has significant existing logic. Always check whether what you're about to implement already exists.

2. **Deterministic first.** If a new command can be handled by adding a case to `CommandEngine.checkZeroLatencyShortcut`, do that before adding a tool.

3. **Route new tools.** Any new `Tool` added to `JarvisTools.swift` must also be added to `JarvisToolbox.routed(for:)` with the right keyword group. A tool that never appears in the routed set will never be called.

4. **Use `@Generable` + `@Guide` for all tool arguments.** Never use a free-form `String` where the valid options are known. Use `@Guide(options:)` or a `@Generable enum` instead.

5. **Keep `SottoCore` pure.** No `AppKit`, `FoundationModels`, or `AVFoundation` imports in `Sources/SottoCore/`. It must remain testable without any Apple platform runtime.

6. **Do not amend AppController with new responsibilities.** It is already too large. New pipeline stages belong in dedicated files.

7. **Match the Hindi persona in zero-latency shortcuts.** `ZeroLatencyShortcut.voiceFeedback` strings follow a specific style ("मिस्टर लॉर्ड, …" / "भाई, …"). Match the register when adding new shortcuts.

8. **The approval gate is sacred.** Never call `SkillStore.runEnabled` from agent code. Only call it from user-facing command handling (i.e., when the user explicitly says "run skill X").

9. **Test SottoCore changes.** Any change to `Sources/SottoCore/` must have a corresponding test in `Tests/SottoTests/`.

10. **Check permissions before acting.** Any new tool that uses a restricted API (camera, contacts, calendar, screen recording) must check permission status first and return a helpful message if denied, instead of crashing.

---

## 16. Quick Reference — Key Entry Points

| What you want | Where to look |
|---|---|
| Add a new voice command (deterministic) | `CommandEngine.checkZeroLatencyShortcut()` or `CommandEngine.process()` |
| Add a new AI-callable capability | New `Tool` in `JarvisTools.swift` + add to `JarvisToolbox` |
| Add a new multi-step automated task | New case in `LongTaskEngine` |
| Add a new agent | New `class XxxAgent` + `DelegateToXxxTool` in `CoordinatorAgent.swift` |
| Change Jarvis persona/instructions | `JarvisAgent.instructions` (shared with `CoordinatorAgent`) |
| Add a persistent user preference | `UserProfile` (key-value) or `SemanticMemory.remember()` |
| Add a new pure-Swift utility | `Sources/SottoCore/` + tests in `Tests/SottoTests/` |
| Register a skill trigger phrase | `SkillStore.enable()` → `CommandEngine.registerSkillTrigger()` (to build) |
| Expose a command to Siri/Shortcuts | `AppIntentsBridge.swift` (audit first) |

---

*End of blueprint. This document is accurate as of the git branch `feat/p1-p2-pipelines` on 2026-06-23.*
