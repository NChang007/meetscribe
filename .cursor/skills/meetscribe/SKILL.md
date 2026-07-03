---
name: meetscribe
description: >-
  Install, configure, and operate the meetscribe macOS CLI for bot-free on-device
  meeting transcription. Use when the user mentions meetscribe, meeting transcription,
  record start/stop, speakers review, gcalcli calendar, init, doctor, or wants to
  build/run this project.
---

# Meetscribe

macOS CLI: stereo mic+system capture → FluidAudio diarization + Parakeet ASR → local SQLite + Markdown. **Audio never leaves the Mac.**

## Requirements

- macOS 14+, Apple Silicon
- Permissions: Microphone, Screen Recording, Accessibility (Zoom/Meet/Teams speaker names)
- Optional: `gcalcli` for Google Calendar title/attendees (not macOS Calendar)

## Install

**From source (this repo):**

```bash
cd meetscribe
swift build -c release --disable-sandbox
install -m 755 .build/release/meetscribe ~/.local/bin/meetscribe
export PATH="$HOME/.local/bin:$PATH"
meetscribe init
```

Skip model download (~1GB): `MEETSCRIBE_SKIP_MODELS=1 meetscribe init`

**Release installer (after GitHub publish):**

```bash
curl -fsSL https://raw.githubusercontent.com/NChang007/meetscribe/main/scripts/install.sh | sh
```

**Google Calendar (optional, non-blocking):**

```bash
brew install gcalcli
gcalcli init
gcalcli agenda today   # verify
meetscribe doctor
```

Calendar enrichment runs **in the background after recording starts** — it never delays `record start`.

## Verify

```bash
meetscribe doctor
meetscribe --version
```

Doctor checks: binary, models, mic/screen/accessibility, gcalcli if enabled.

## Daily workflow

```bash
# Start (title optional — gcalcli may update session.json shortly after)
meetscribe record start --title "Product sync"

# Stop (foreground: Ctrl+C; background:)
meetscribe record stop

# List / search / export
meetscribe sessions list
meetscribe search "roadmap"
meetscribe export --session SESSION_ID

# Deferred speaker labeling (batch, when you have time)
meetscribe speakers review
meetscribe speakers review --session SESSION_ID
meetscribe speakers review --purge
```

## Auto-record on calls

```bash
meetscribe watch start
meetscribe watch status
meetscribe watch stop
```

## Key config

Config file: `~/.config/meetscribe/config.json`

```bash
meetscribe config show
meetscribe config set-use-calendar true|false
meetscribe config set-gcalcli-calendar "you@gmail.com"
meetscribe config set-language auto|en|de
meetscribe config set-threshold 0.75
meetscribe config set-sessions-dir /path/to/sessions
```

Per-session overrides:

- `meetscribe record start --no-calendar`
- `meetscribe record start --no-auto-process`

## Data locations

| Path | Contents |
|------|----------|
| `~/.config/meetscribe/sessions/<id>/` | WAV, transcript, notes.md, session.json |
| `~/.config/meetscribe/speakers.sqlite` | Speaker profiles + FTS search index |
| `~/.config/meetscribe/voices/` | Voice embedding centroids |
| `~/Library/Caches/` | FluidAudio model weights |

Session layout: `meeting.wav` (stereo L=mic R=system), `transcript.json`, `notes.md`, `session.json`.

## Build & test

```bash
swift build -c release --disable-sandbox
swift test   # requires full Xcode (not CLT-only)
./scripts/build-release.sh
```

## Agent rules

1. **Never upload meeting audio** — processing is local only.
2. **Do not block recording on gcalcli** — calendar is best-effort background enrichment.
3. **Prefer deferred labeling** — user runs `speakers review` in batches, not after every meeting.
4. **Apple Silicon only** for ASR; Intel is unsupported.
5. When editing this project: match existing Swift style; no single-letter variable names in new code.
6. Do not create extra docs in `docs/` unless the user asks — README is the user-facing doc.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Stale recording lock | `meetscribe doctor` or delete `~/.config/meetscribe/sessions/.recording-state.json` if worker dead |
| No system audio | Grant Screen Recording in System Settings |
| Wrong speaker names | Run `speakers review`; AX detection is best-effort |
| gcalcli not found | `brew install gcalcli && gcalcli init` |
| Models missing | `meetscribe init` |
| Gatekeeper blocks binary | Needs codesign + notarize for public releases (`scripts/codesign.sh`) |

## Uninstall

```bash
rm -f ~/.local/bin/meetscribe
rm -rf ~/.config/meetscribe
```
