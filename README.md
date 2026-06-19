# Sotto — Fully Native, On-Device AI Dictation & Assistant for macOS (Apple Silicon)

Privacy-first speech-to-text **and** a JARVIS-style voice assistant for Apple Silicon Macs.
Everything runs on-device in Swift: **no Python, no local servers, no network at inference time.**

**Two interaction modes (push-to-talk):**
- **Dictation** — speak → transcript is polished and typed into the focused app.
- **Jarvis** — speak a command → the on-device agent acts on your Mac and talks back.

## The brain: two native on-device engines

Sotto's intelligence is 100% native and chosen per task:

| Engine | Used for | Notes |
| --- | --- | --- |
| **Apple Intelligence** (Foundation Models) | Dictation polish, the Jarvis tool-calling agent, quick answers | In-process, kept **warm** via one reused `LanguageModelSession` so there's no per-call cold start. Requires macOS 26+ with Apple Intelligence enabled. |
| **Qwen via MLX-Swift** | Heavier / long-form generation (`getCompletion`: LinkedIn posts, ad copy, research, explanations) | Runs the model **in-process on the GPU** (MLX), loaded once and kept resident. No `mlx_lm.server`, no Python. |

Routing: fast/short → Apple Intelligence; heavy/long → warm MLX Qwen (falls back to Apple
Intelligence if MLX isn't built in or the model isn't ready).

## Speech-to-text

- **Offline AI:** Parakeet TDT v3 on the Apple Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio).
- **Apple Speech:** `SFSpeechRecognizer` (Siri engine), on-device.

Choose the engine in Settings.

## Everything else is native too

- **System control** — volume (CoreAudio), brightness (DisplayServices), mute, sleep/lock/empty-trash.
- **Window management** — maximize / halves / quadrants / center / minimize / close via the **Accessibility (AX) API** (no AppleScript files).
- **Media control** — play/pause/next/previous via system media keys (works for Spotify, Music, browsers).
- **Browser nav** — reload/back/forward/new-tab/close via synthetic keystrokes.
- **Voice feedback** — `AVSpeechSynthesizer` (native; the old Python Kokoro daemon is gone).
- **Screen OCR / on-screen reading** — Vision framework.
- **Text injection** — pasteboard + synthetic ⌘V, delivered with `CGEvent.postToPid` to the target app.

The legacy `osascript`/`.scpt` skill files, the `mlx_lm.server`, and the Python Kokoro TTS
daemon have all been removed and reimplemented in Swift.

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

Default MLX model: **`mlx-community/Qwen2.5-1.5B-Instruct-4bit`** — small and fast enough to sit
alongside Apple Intelligence on an M1/8 GB. Change it in Settings ▸ On-Device Brain. Larger models
(e.g. `Qwen2.5-3B-Instruct-4bit`) give better quality if you have RAM headroom.

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
