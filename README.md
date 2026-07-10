# Sotto — On-Device AI Voice Assistant for macOS

**"Jarvis, open Xcode"** — speak it and your Mac acts. Sotto is a privacy-first, fully on-device voice assistant for Apple Silicon Macs. No cloud, no Python, no servers. Everything runs in Swift, on your hardware.

Two modes, each on its own hotkey:

- **Dictation** — speak → polished text types itself into whatever app you're using.
- **Jarvis** — speak a command → Sotto understands it and acts on your Mac.

---

## How to use Jarvis

**Activate:** Press the Jarvis hotkey (default: ⌘⇧J). You can also reach Jarvis from dictation: open your utterance with "Jarvis, …" or "Hey Jarvis, …" (e.g. "Jarvis, open Xcode") and it's delegated to Jarvis instead of typed. The wake word only counts at the *start* of what you say — mentioning "Jarvis" mid-sentence stays ordinary dictation. There is no hands-free / always-listening mode.

**Speak your command** while the HUD shows "Listening…"

**Release the key** (or stop speaking) — Jarvis processes and acts.

**If Jarvis asks a clarifying question:** the HUD shows "❓ question — press Jarvis to answer". Press the Jarvis hotkey again to give your answer. The session continues with full context.

> Jarvis stays ready for ~30 seconds after a clarifying question. After that the session resets automatically.

---

## Jarvis learns from you

Every time Jarvis handles a command, `CommandLearner` records the phrase and which tool was used. After **3 uses**, the phrase is **promoted** — on future invocations, the right tool is placed first in the model's tool list, so it picks it immediately instead of scoring keyword groups.

Learned shortcuts persist across restarts in `sotto-data/learned_shortcuts.json`. The more you use Jarvis, the faster and more accurate it gets for your specific patterns.

---

## What Jarvis handles

### Instant (no AI — zero latency)

These fire the moment you stop speaking, before any model is involved:

| What to say | What happens |
|---|---|
| "maximize" / "full screen" / "tile left" / "snap right" | Window tiling |
| "top left" / "bottom right" / "top half" | Window corners and halves |
| "volume up" / "louder" / "turn up the volume" | Volume increase |
| "volume down" / "quieter" / "turn it down" | Volume decrease |
| "set volume to 70 percent" | Exact volume level |
| "mute" / "unmute" | Mute toggle |
| "brightness up" / "brighter" / "dim the screen" | Brightness |
| "set brightness to 50 percent" | Exact brightness level |
| "play" / "pause" / "next" / "skip" / "previous" | Media controls |
| "sleep mac" / "put laptop to sleep" | Mac sleep |
| "lock screen" / "lock my mac" | Screen lock |
| "empty trash" / "clear trash" | Empty trash |
| "reload page" / "new tab" / "close tab" / "go back" | Browser controls |

### Weather — answered directly (no AI, no Siri)

"what's the weather" / "is it raining" / "will it snow tomorrow" — Sotto calls a keyless weather service directly and shows the answer in the HUD. The model is never woken for an obvious weather ask.

### Via Siri

For things only Apple's own apps can do, Jarvis hands the request to Siri (via the `ask_siri` tool):

| What to say | Siri handles |
|---|---|
| "remind me to…" / "set a reminder for…" | Reminders |
| "add to my calendar" / "schedule a meeting" / "what's my schedule" | Calendar |
| "set alarm for 7am" / "timer for 10 minutes" | Alarms & timers |
| "message John saying I'll be late" / "text Sarah" | iMessage |
| "call Mum" / "FaceTime Dad" | Calls |
| "email Priya" / "send an email to…" | Mail |

You can also say **"ask Siri to…"** or **"tell Siri to…"** with anything and it goes straight through.

### Via Jarvis AI (Apple Foundation Models, on-device)

When no instant rule matches, Jarvis picks the right tool. Frequently-used commands are pre-routed by `CommandLearner` after 3 uses.

| What to say | What happens |
|---|---|
| "open Xcode" / "launch Safari" / "switch to VS Code" | Opens or switches to app |
| "open github.com" / "go to notion.so" | Opens URL in browser |
| "play Bohemian Rhapsody on Spotify" / "search Spotify for Daft Punk" | Plays specific song |
| "search the web for Swift concurrency" | Google search in browser |
| "look up Einstein on Wikipedia" | Wikipedia summary |
| "where is the Eiffel Tower" | Geocode + open in Maps |
| "read the screen" / "what does this say" | OCR screen text |
| "click the Sign In button" | Finds and clicks on-screen element |
| "create a note: buy milk" | Apple Notes |
| "copy this to clipboard" / "what's in my clipboard" | Clipboard read/write |
| "battery level" / "wifi status" / "ram usage" / "disk space" | System status |
| "find large files" / "organize downloads" | File management |
| "explain this code" / "find the bug" / "generate git commit message" | Code assistant |
| "morning brief" / "start a focus session" / "end workday" | Productivity workflows |
| "remember that my project deadline is June 30" | Persistent memory |
| "what did you do today" / "what have you learned" | Activity history |
| "ask Claude: what is a monad" | Sends prompt to Claude desktop app |

---

## Skills (user-approved scripts)

Jarvis can draft reusable scripts for tasks you do often (`draft_skill`). Drafted skills are saved **disabled** — you must say **"enable skill [name]"** before they run. This is a security gate: no agent-generated code ever auto-executes.

---

## Dictation mode

Activate with the dictation hotkey (default: ⌘K). Speak — when you stop, the text is polished and typed into whatever app was focused.

**If the wrong text gets pasted:** this is a race condition with some apps (Electron, heavy browsers). Try again — the injector aborts silently rather than pasting stale clipboard content, so a second attempt will paste the correct text.

---

## Requirements

- **Apple Silicon Mac** — M1 or newer. Tuned for M1 / 8 GB.
- **macOS 27 with Apple Intelligence enabled** — required for the Jarvis agent and its chat / quick / bigJob lanes.
- **Xcode or Command Line Tools** — to build.
- **Internet on first run only** — downloads Swift packages and models. After that, fully offline.

### Permissions (prompted once on first use)

1. **Microphone** — voice input
2. **Accessibility** — hotkeys, window management, text injection
3. **Screen Recording** — OCR / screen reading
4. **Automation** — dark mode toggle, Notes, sleep

---

## Install

```bash
git clone https://github.com/Stochastic96/Sotto.git
cd Sotto
swift build -c release
./.build/release/Sotto
```

> **Note:** a few code paths hard-code `~/Projects/Sotto`. Update those after cloning to a different path.

---

## Architecture

```
Voice → SpeechAnalyzer (on-device dictation) → transcript
                              ↓
        Zero-latency shortcuts          ← instant, no AI (window tiling, volume…)
                              ↓
        Deterministic weather           ← WeatherService, keyless, no model
                              ↓
        Kernel reflex router            ← cheapest capable path, 0 tokens ("open xcode",
                                           compounds like "open finder and open xcode")
                              ↓
        Jarvis Brain                    ← learned/seeded commands matched by MEANING
                                           (on-device NLEmbedding), safe tools replay natively
                              ↓
        CoordinatorAgent (Foundation Models)
          ├─ CommandLearner.hint → pre-select known tool  ← learned
          ├─ JarvisToolbox.routed (keyword scoring)       ← fallback
          └─ JarvisProfile.classify → per-lane session: chat / quick / bigJob  ← macOS 27
```

Each layer only runs if the one above it didn't match — the cheapest path wins.

Dictation polish: `SottoIntelligence.refine()` → Apple Intelligence (Foundation Models) → polished text → `TextInjector` → ⌘V.

**CommandLearner:** records `(phrase → toolName)` after every Jarvis turn. Promoted phrases (≥3 uses) are cached in `learned_shortcuts.json` and injected as position-#1 tool in `JarvisToolbox.routed`, so the model sees the correct tool immediately rather than scoring 24 keyword groups.

---

## Project layout

```
Sources/
  Sotto/         — executable: AppKit menu bar, audio, agent, all platform code
                   (incl. infrastructure: EventBus, CapabilityRegistry, LaneStats)
  SottoCore/     — pure Swift (no AppKit): testable logic, vocab correction, context detection
Tests/
  SottoTests/    — unit tests for SottoCore
sotto-data/
  learned_shortcuts.json  — CommandLearner: promoted phrase → tool mappings
  jarvis_brain.json        — Jarvis Brain: semantic command memory (matched by meaning)
  jarvis_memory.json       — persistent key-value facts (profile, wikipedia cache)
  journal.jsonl            — Jarvis turn log
  skills/jarvis/           — user-approved skill scripts
```

---

## License

Open source. Free to use, modify, and distribute.
