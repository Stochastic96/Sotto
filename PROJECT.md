# Sotto — Project Blueprint

Architecture reference for Sotto, a privacy-first, fully on-device voice assistant
for Apple Silicon Macs. Rewritten 2026-07-01 to reflect the actual current state of
the codebase — the prior version of this file (referenced by `.agents/orchestrator/
handoff.md` from a 2026-06-22 multi-agent build session) no longer exists on disk
and this is not a restoration of it.

For user-facing behavior (what you can say, what it does), see `README.md`.
For agent/session working notes and known gotchas, see `CLAUDE.md`.

## Constraint that shapes every decision here

**Target hardware: Apple Silicon M1, 8 GB unified memory.** There is no larger-RAM
fallback target. Every architectural choice below — session reuse, lane
classification, background job batching, and Apple Intelligence memory constraints —
exists because 8 GB is a hard ceiling, not a soft recommendation. When evaluating a
change, ask "does this add resident memory or reprocessing cost per turn" before
asking "does this add capability."

## System overview

```
                          ┌─────────────────────────────┐
   Microphone  ────────▶ │ AudioRecorder/SpeechAnalyzer │
                          │ (Native Speech, on-device)  │
                          └───────────────┬───────────────┘
                                          ▼
                              transcript (raw speech)
                                          ▼
              ┌───────────────────────────────────────────────┐
              │  CommandEngine — layered dispatch, fastest      │
              │  match wins, later layers only run if earlier    │
              │  layers don't match                              │
              └───────────────────────────────────────────────┘
                   │              │                │
                   ▼              ▼                ▼
        zero-latency        Siri delegation    prefix-rule parse
        shortcuts            (SiriBridge)      (browser/website
        (window tiling,      weather, calls,    open commands)
        volume, media,       reminders, mail
        no AI at all)
                   │              │                │
                   └──────────────┴────────────────┘
                                  ▼ (nothing matched)
                       ┌─────────────────────┐
                       │   CoordinatorAgent    │  ← the actual "Jarvis" brain
                       └─────────────────────┘
```

## CoordinatorAgent — the brain

`Sources/Sotto/CoordinatorAgent.swift`. An `actor` (safe against a second command
arriving mid-turn) wrapping one warm Apple Foundation Models `LanguageModelSession`.

**Tool selection**, in priority order:
1. `CommandLearner.hint` — phrases used ≥3 times get their proven tool pinned to
   position #1, skipping keyword scoring entirely for known patterns. Persisted to
   `sotto-data/learned_shortcuts.json`, survives restarts.
2. `JarvisToolbox.routed(for:)` — keyword-group scoring across ~24 tool groups,
   capped at the top 5 matches to keep prompt size bounded.
3. Escalation tools (`delegate_to_os_control`, `delegate_to_web_researcher`,
   `delegate_to_scripting_executor`) — always appended so the model can hand off
   compound/deep tasks even if the initial keyword routing missed.

**Lane system** (`JarvisProfile.swift`, gated by `SOTTO_FM27`, requires Swift 6.4 /
macOS 27+): classifies each turn into `chat` (small talk, tools forbidden,
temperature 0.7), `quick` (the default — routed tools + escalation, temperature
0.3), or `bigJob` (bulk repetitive work, `start_long_task` required, temperature
0.2). Expressed as a native `LanguageModelSession.DynamicProfile` so the framework
itself enforces the tool-calling mode per lane, rather than relying on prompt text
alone. On macOS 26 (or if the DynamicProfile path times out/fails after 40s),
falls back to a hand-built session with up to 12 tool schemas assembled manually —
functionally correct but reprocesses more context per turn.

**Clarification loop**: if the model is genuinely unsure, it replies with a
sentinel prefix (`kClarificationPrefix = "ASK:"`); `AppController` detects this,
speaks the question, and reopens the mic for one follow-up turn using the *same*
session (`isFollowUp: true`), so context isn't lost. Session times out and resets
after ~30s of no follow-up.

## Sub-agents — escalation for compound tasks

Three specialized agents, each a **session-caching actor** (as of 2026-07-01 —
previously stateless classes that rebuilt a `LanguageModelSession` from scratch on
every call, which reprocessed the full instructions + tool schema each time):

- **`OSControlAgent`** — native macOS control tasks (volume, brightness, power,
  notes, reminders, calendar), tools chosen via the same `JarvisToolbox.routed`
  keyword scoring the main Coordinator uses.
- **`WebResearcherAgent`** — fixed tool set: `read_screen_tree` →
  `click_screen_element` / `set_screen_element_value` (AX-tree-based UI automation,
  not OCR) plus Wikipedia lookup.
- **`ScriptingExecutorAgent`** — generates a Swift script for compute-y tasks
  (disk space, file stats, etc). **Never auto-executes**: drafts the script into
  `SkillStore` in a disabled state; the user must explicitly say "enable skill
  <name>" before it can run. This is the project's core security invariant for
  agent-generated code — do not weaken it.

Each caches its session for up to 12 turns before rebuilding (same bound
`SottoIntelligence` uses for its dictation-polish session), and exposes
`.unload()` for memory-pressure scenarios. This is the main per-turn cost fix
alongside the lane system — spinning up a fresh session on every single
delegation hop was pure overhead with no correctness benefit.

## Background jobs — staying responsive during long work

`LongTaskEngine.swift`: durable, resumable bulk jobs that process in small
batches (20 items), persist progress to `sotto-data/long_tasks/*.json` after every
batch, and run via `Task.detached(priority: .utility)` so the main Jarvis loop is
never blocked. Survives quit/crash — `resumePending()` re-launches any job still
`.running` at next app start. Currently the only supported goal type is bulk
promotional-email cleanup (`supports(goal:)` gate) — the mechanism generalizes
cleanly to other background job types (e.g. driving a browser extension and
polling for a result) but that generalization hasn't been built yet.

Model-primary classification inside a batch (Apple Intelligence + guided
`@Generable` decoding for structural correctness) with a keyword-heuristic
fallback if the model is unavailable.

## Dictation pipeline

`DictationPipeline.swift` → `SottoIntelligence.refine()`. Uses a dedicated, prewarmed Apple Intelligence session kept separate from the general-completion session specifically so the two never evict each other (see the session-architecture note at the top of `SottoIntelligence.swift`). Deliberately avoids `ContextOptions`/`reasoningLevel` — the on-device model on M1 8 GB doesn't declare the `.reasoning` capability, and using those options throws `unsupportedCapability` on every call.

## App / tool integration surface

~29 native tools in `JarvisTools.swift` (Spotify, volume/brightness, open
apps/URLs, notes, web search, screen OCR, click-by-visible-text, clipboard,
system/RAM/GPU status, geocoding, Wikipedia, persistent memory, "ask Claude
desktop app," Siri-delegated reminders/calendar/weather) plus the AX-tree-based
click/read/set-value tools in `CoordinatorAgent.swift` used by `WebResearcherAgent`.

**`ClaudeQuickEntry.swift`** is worth knowing about specifically: it drives the
Claude desktop app's quick-entry popover via synthesized keystrokes (double-tap
Option), pastes a prompt, then polls the screen via OCR until the response text
stabilizes and extracts it. This is the reference pattern for "delegate reasoning
to an already-open, already-paid-for AI tool and read the answer back via
automation" — the same pattern would extend to driving a browser extension
(open app/profile → click element → inject text → poll/OCR for result), which
hasn't been built yet but is a natural next step using existing primitives
(`ScreenParser`, `ClickElementTool`, `TextInjector`, the OCR-polling loop in
`ClaudeQuickEntry.sendAndReadResponse`).

## Not yet built

- Browser-extension delegation as a background job (see above) — the pieces
  exist, the wiring doesn't.
- Any smart-home integration (HomeKit/Matter/Alexa) — zero code currently. If
  pursued, HomeKit is the framework that matches this project's fully-local,
  no-cloud principle; Alexa's own Skill API is cloud-routed and would be a
  philosophical departure from how everything else here is built.
- `SottoInfra` as an actual separate target — README's project-layout diagram
  describes it, but `EventBus`/`CapabilityRegistry`/`LaneStats` currently live
  directly in `Sources/Sotto/`.
