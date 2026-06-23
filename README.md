# Sotto — Fully Native, On-Device AI Dictation & Assistant for macOS (Apple Silicon)

Privacy-first speech-to-text **and** a JARVIS-style voice assistant for Apple Silicon Macs.
Everything runs on-device in Swift: **no Python, no local servers, no network at inference time.**

**Two interaction modes (push-to-talk):**
- **Dictation** — speak → transcript is polished and typed into the focused app.
- **Jarvis** — speak a command → the on-device agent acts on your Mac and talks back.

## The brain: two native on-device engines

Sotto uses **two brains, chosen per task** — the right tool for each job on 8 GB:

| Engine | Used for | Notes |
| --- | --- | --- |
| **Qwen via MLX-Swift** (0.5B-Instruct) | **Dictation polish** + heavier / long-form generation | Runs **in-process on the GPU** (MLX), loaded once and kept resident. Tiny enough to stay warm on an M1/8 GB, so polish is fast (~1.5–2.5 s) and the **same latency every time** — no Apple-Intelligence model eviction stalls. No `mlx_lm.server`, no Python. |
| **Apple Intelligence** (Foundation Models) | The **Jarvis tool-calling agent** + dictation-polish fallback | Native tool-calling (`@Generable` + `Tool`) is reliable in a way small models aren't, so the agent stays here. Kept **warm** via a prewarmed `LanguageModelSession`. Requires macOS 26+ with Apple Intelligence enabled. |

Why split: on 8 GB every model uses RAM; the win is a *small resident model* for the
speed-critical dictation path, while the agent keeps Apple's stronger tool-calling. Polish
falls back to Apple Intelligence if MLX isn't built in or the model can't load.

## Speech-to-text

- **Offline AI:** Parakeet TDT v3 on the Apple Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio).
- **Apple Speech:** `SFSpeechRecognizer` (Siri engine), on-device.

Choose the engine in Settings.

## Everything else is native too

- **System control** — volume (CoreAudio), brightness (DisplayServices), mute, sleep/lock/empty-trash.
- **Window management** — maximize / halves / quadrants / center / minimize / close via the **Accessibility (AX) API** (no AppleScript files).
- **Spotify control** — play/pause/skip and **search-and-play a specific song**, addressed to Spotify *by name* via AppleScript (never hijacks Apple Music). Song search uses the keyless Spotify Web API when credentials are set.
- **Weather** — current conditions + today's high/low for any city via the free, keyless [Open-Meteo](https://open-meteo.com) API.
- **Browser nav** — reload/back/forward/new-tab/close via synthetic keystrokes.
- **Voice feedback** — `AVSpeechSynthesizer` (native; the old Python Kokoro daemon is gone).
- **Screen OCR / on-screen reading** — Vision framework.
- **Text injection** — pasteboard + synthetic ⌘V, delivered with `CGEvent.postToPid` to the target app. Direct AX insertion is opt-in and gated on `AXUIElementIsAttributeSettable` so it can't silently no-op in Terminal/Electron apps.

### Jarvis tool calling & routing

The agent exposes **27 native Swift tools** (each a Foundation Models `Tool` with `@Generable`
arguments). Because tool-selection accuracy plateaus around 8 tools and drops beyond, each
utterance is **routed to only the ≤8 most relevant tools** by keyword group (`JarvisToolbox.routed`)
rather than handing the model the whole catalog — sharper choices, lower latency.

The legacy `osascript`/`.scpt` skill files, the `mlx_lm.server`, and the Python Kokoro TTS
daemon have all been removed and reimplemented in Swift.

## Requirements

- **Apple Silicon Mac** (arm64 — M1 or newer). Tuned for an M1 with 8 GB RAM.
- **macOS 26+ with Apple Intelligence enabled** — the Jarvis tool-calling agent and dictation-polish fallback use Apple's Foundation Models.
- **Xcode** (full app, not just Command Line Tools) — `make-app.sh` uses `xcodebuild` to compile MLX's Metal GPU shaders. A bare `swift build` is fine for type-checks but won't ship a runnable app.
- **Internet on first build/run** — to fetch SwiftPM packages and download the models below once. After that, inference is fully offline.

### What gets downloaded (not stored in the repo)

These are large and machine-specific, so they're **not** in git — each Mac fetches its own:

| Item | Size | When |
| --- | --- | --- |
| SwiftPM dependencies | ~hundreds MB | first build (`make-app.sh` / `swift build`) |
| Qwen MLX model (`Qwen2.5-0.5B-Instruct-4bit` default) | ~0.4–0.9 GB | first heavy Jarvis task |
| Parakeet TDT v3 speech model (FluidAudio) | ~0.6 GB | first offline-AI transcription |

The repo itself (Swift source + config) is **under ~1 MB**. The ~9 GB you may see in the working
folder is regenerated build cache (`.build`, `.xcbuild`, `build/`) and local runtime/model data
(`sotto-data/`) — all gitignored and safe to delete.

## Install on another Mac

```bash
git clone https://github.com/Stochastic96/Sotto.git
cd Sotto
./scripts/make-app.sh      # first build is slow: MLX Metal shader compilation
open build/Sotto.app
```

Then grant the [permissions](#permissions-one-time) below. The first heavy Jarvis task and first
offline transcription each trigger a one-time model download.

> **Note:** a few code paths currently hard-code `~/Projects/Sotto` (i.e.
> `/Users/prashantsharma/Projects/Sotto`). On a machine with a different username or clone location,
> those paths need updating.

## Build & run

```bash
./scripts/make-app.sh      # release build via xcodebuild → build/Sotto.app
open build/Sotto.app
```

- `make-app.sh` uses **xcodebuild** (needed to compile MLX's Metal GPU shaders) and bundles the
  SwiftPM `.bundle` resources into the app.
- `swift build` works for fast compile/type-checks.
- **First MLX build is heavy** (Metal shader compilation). **First Jarvis "heavy" task downloads the
  Qwen model** (~0.9 GB for `Qwen2.5-1.5B-Instruct-4bit`) once, then runs fully offline.

### MLX on/off

The in-process MLX engine is gated by the `SOTTO_MLX` compile flag (defined in `Package.swift`).
With it off, `MLXEngine` is a no-op and **all** generation uses Apple Intelligence — the app still
builds and works without the MLX packages.

## Model choice (8 GB Macs)

Default MLX model: **`mlx-community/Qwen2.5-0.5B-Instruct-4bit`** — tiny enough to stay resident
alongside Apple Intelligence on an M1/8 GB, giving fast, consistent dictation polish. Change it in
Settings ▸ On-Device Brain. Larger models (e.g. `Qwen3-1.7B-4bit`) give sharper polish if you have
RAM headroom.

### Optional: Spotify song search

To let "play <song> on Spotify" auto-play (not just open search), add free [Spotify Developer](https://developer.spotify.com/dashboard)
app credentials — no user login needed (Client Credentials flow):

```bash
defaults write local.sotto.app sotto_spotify_client_id "<your-client-id>"
defaults write local.sotto.app sotto_spotify_client_secret "<your-client-secret>"
```

## Permissions (one-time)

1. **Microphone** — dictation.
2. **Accessibility** — global hotkey, window management, and synthetic ⌘V.
3. **Screen Recording** — Screen OCR / on-screen reading.
4. **Automation (System Events / Notes)** — dark-mode toggle, sleep, note creation (prompted on first use).

## Why not the App Store

Apple rejects apps that inject text via synthetic key events (Guideline 2.4.5). Sotto requires text
injection, so it's built for Developer ID distribution.

---

**Location:** `~/Projects/Sotto` · **License:** Open source
