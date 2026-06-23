# Sotto — On-Device AI Voice Assistant for macOS

**"Hey Jarvis"** — say it and your Mac acts. Sotto is a privacy-first, fully on-device voice assistant for Apple Silicon Macs. No cloud, no Python, no servers. Everything runs in Swift, on your hardware.

Two modes, one hotkey (or your voice):

- **Dictation** — speak → polished text types itself into whatever app you're using.
- **Jarvis** — speak a command → Sotto understands it and acts on your Mac.

---

## What Jarvis can do

Out of the box, Jarvis handles 27 categories of native Mac actions:

| Category | Example commands |
|---|---|
| **System control** | "volume up", "mute", "set brightness to 50", "lock screen", "sleep", "empty trash" |
| **Window management** | "maximize this window", "move to left half", "tile to top right" |
| **App & web** | "open Xcode", "open github.com", "switch to Safari" |
| **Spotify** | "play", "pause", "skip", "play Bohemian Rhapsody on Spotify" |
| **Weather** | "weather in Berlin", "what's the forecast for Tokyo" |
| **Search & research** | "search Google for Swift actors", "look up SwiftUI on Wikipedia" |
| **Notes & reminders** | "create a note: buy milk", "remind me to call Priya at 5pm" |
| **Calendar** | "what's on my calendar today", "add meeting at 3pm" |
| **Screen reading (OCR)** | "read the screen", "what does this error say" |
| **Clipboard** | "copy this to clipboard", "what's in my clipboard" |
| **Morning brief** | "morning brief", "daily summary" |
| **Focus sessions** | "start a focus session", "end workday" |
| **Code assistant** | "explain this code", "generate a git commit message", "find the bug" |
| **File management** | "organize my downloads", "find large files" |
| **System status** | "ram usage", "battery level", "wifi status" |
| **Location** | "where is Trier", "geocode this address" |

Everything above runs **100% on-device, zero network**.

---

## Wake word

Say **"Hey Jarvis"** (or just **"Jarvis"**) to activate hands-free. The wake word detector runs continuously on the Apple Neural Engine using `SFSpeechRecognizer` with `requiresOnDeviceRecognition` — no audio ever leaves your Mac.

Push-to-talk hotkeys also available (configurable in Settings).

---

## The two on-device brains

| Engine | Used for | Notes |
|---|---|---|
| **Parakeet TDT v3** (FluidAudio / ANE) | Speech-to-text | Offline Whisper-class model, Neural Engine |
| **Qwen 0.5B via MLX-Swift** | Dictation polish | Tiny, stays resident on 8 GB RAM |
| **Apple Foundation Models** | Jarvis tool-calling agent | Requires macOS 26 + Apple Intelligence |

Why split: dictation polish needs speed (1–2 s every time), the agent needs reliable tool-calling. Each brain does what it's best at.

---

## Requirements

- **Apple Silicon Mac** — M1 or newer. Tuned for M1 / 8 GB.
- **macOS 26 with Apple Intelligence enabled** — required for the Jarvis agent.
- **Xcode or Command Line Tools** — to build (compiles MLX Metal shaders).
- **Internet on first run only** — to fetch Swift packages and download models. After that, fully offline.

### First-run downloads (not in the repo)

| Item | Size | When |
|---|---|---|
| Swift package dependencies | ~hundreds MB | `swift build` |
| Qwen MLX model (default: `Qwen2.5-0.5B-Instruct-4bit`) | ~0.4–0.9 GB | first Jarvis command |
| Parakeet speech model (FluidAudio) | ~0.6 GB | first offline transcription |

---

## Install

```bash
git clone https://github.com/Stochastic96/Sotto.git
cd Sotto
swift build -c release
./.build/release/Sotto
```

Grant permissions when prompted (one-time):

1. **Microphone** — voice input
2. **Accessibility** — hotkeys, window management, text injection
3. **Screen Recording** — OCR / on-screen reading
4. **Automation** — dark mode toggle, Notes, sleep (prompted on first use of each)

> **Note:** a few code paths hard-code `~/Projects/Sotto`. On a different machine, update those paths after cloning.

---

## Why not the App Store

Apple Guideline 2.4.5 rejects apps that inject text via synthetic key events. Sotto requires text injection to work in every app, so it's distributed as a Developer ID build only.

---

## Optional: Spotify song search

To enable "play \<song\> on Spotify" (auto-plays instead of opening search), add free [Spotify Developer](https://developer.spotify.com/dashboard) credentials — no user login needed:

```bash
defaults write local.sotto.app sotto_spotify_client_id "<your-client-id>"
defaults write local.sotto.app sotto_spotify_client_secret "<your-client-secret>"
```

---

## Architecture in brief

```
Voice → Parakeet (ANE) → transcript
                              ↓
              CommandEngine (zero-latency shortcuts)
                              ↓
              Kernel reflex router (open app / compound commands)
                              ↓
              JarvisAgent (Foundation Models, ≤8 routed tools)
                              ↓
              MLX fallback (Qwen via mlx-swift)
```

Dictation polish runs on a separate fast path: `QwenRefiner` → Qwen 0.5B → polished text → `TextInjector` → ⌘V.

---

## Project layout

```
Sources/
  Sotto/         — executable: AppKit menu bar, audio, agent, all platform code
  SottoCore/     — pure Swift (no AppKit): testable logic, vocab correction, context detection
Tests/
  SottoTests/    — unit tests for SottoCore
```

---

## License

Open source. Free to use, modify, and distribute.
