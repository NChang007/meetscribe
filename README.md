# Meetscribe

Bot-free meeting transcription for macOS. Captures **stereo audio** (mic = left, system = right), runs **FluidAudio** diarization + Parakeet ASR entirely on your Mac, remembers voices across sessions, and exports Markdown notes.

**Your meeting audio never leaves this computer.**

Inspired by [diarize](https://github.com/elien666/diarize) (MIT) and powered by [FluidAudio](https://github.com/FluidInference/FluidAudio).

## Requirements

- **macOS 14+**
- **Apple Silicon** (Parakeet ASR models)
- Permissions: **Microphone**, **Screen Recording** (system audio), **Accessibility** (active speaker names from Zoom/Meet/Teams)
- Optional: **[gcalcli](https://github.com/insanum/gcalcli)** for Google Calendar title + attendees (no macOS Calendar app needed)

### Google Calendar (optional)

Meetscribe reads your **Google Calendar** via `gcalcli` — not the macOS Calendar app.

```bash
brew install gcalcli
gcalcli init          # one-time Google OAuth in your browser
gcalcli agenda today  # verify it works
meetscribe doctor
```

If you use a non-default calendar:

```bash
meetscribe config set-gcalcli-calendar "you@gmail.com"
```

Disable calendar lookup: `meetscribe config set-use-calendar false`

## Privacy

| Data | Where |
|------|--------|
| Meeting audio | `~/.config/meetscribe/sessions/<id>/meeting.wav` (deleted after analysis by default) |
| Transcripts | Same session folder + SQLite FTS index |
| Speaker voices | `~/.config/meetscribe/speakers.sqlite` + embedding centroids in `voices/` |
| Model weights | FluidAudio cache under `~/Library/Caches/` (~1GB, one-time download) |
| Processing | On-device Core ML / Neural Engine only |

Optional one-time model download runs during **`meetscribe init`** or **`curl | sh` install** (open model weights only, not your recordings). Skip with `--skip-models` or `MEETSCRIBE_SKIP_MODELS=1`.

## Install

**Recommended** — one command (downloads binary, configures PATH, runs `init`):

```bash
curl -fsSL https://raw.githubusercontent.com/NChang007/meetscribe/main/scripts/install.sh | sh
```

**Homebrew** — requires [Homebrew](https://brew.sh). Third-party taps must be trusted once (Homebrew 4.6+):

```bash
brew tap NChang007/meetscribe
brew trust nchang007/meetscribe
brew install meetscribe && meetscribe init
```

One line (first time on a Mac):

```bash
brew tap NChang007/meetscribe && brew trust nchang007/meetscribe && brew install meetscribe && meetscribe init
```

After tapping once, upgrades are:

```bash
brew update && brew upgrade meetscribe
```

Tap repo: [homebrew-meetscribe](https://github.com/NChang007/homebrew-meetscribe)

**From source:**

```bash
cd meetscribe
swift build -c release --disable-sandbox
install -m 755 .build/release/meetscribe ~/.local/bin/meetscribe
meetscribe init
```

### Distribution signing

Downloaded binaries must be **codesigned and notarized** for smooth Gatekeeper experience. See `scripts/codesign.sh` and notarize with `xcrun notarytool` before publishing releases.

## Quick start

```bash
meetscribe init          # config dirs + model download (included in curl | sh install)
meetscribe doctor        # verify models + permissions

# One-time Google Calendar setup (optional)
brew install gcalcli && gcalcli init

meetscribe record start --title "Product sync"
# Ctrl+C or: meetscribe record stop
# gcalcli may update title/attendees in session.json shortly after start (never blocks recording)

meetscribe sessions list
meetscribe export
meetscribe search "roadmap"

# Later — label unknown voices (batch, when you have time)
meetscribe speakers review
meetscribe speakers review --session SESSION_ID
meetscribe speakers review --purge   # discard pending snippets
```

## CLI commands

| Command | Description |
|---------|-------------|
| `init` | Create config, download models |
| `doctor` | Check install, models, permissions |
| `record start` | Stereo capture + auto-process on stop |
| `record stop` | Stop background recording |
| `transcribe --session ID` | Re-process a session |
| `transcribe --file path.wav` | Import + process any audio file |
| `speakers list/label/merge/review` | Voice library + deferred labeling |
| `search "query"` | FTS search all transcripts |
| `watch start/stop` | Lightweight auto-record on calls |
| `config set-sessions-dir` | Change output location |
| `config set-language` | `auto`, `en`, or `de` |
| `config set-threshold` | Speaker match sensitivity |
| `config set-use-calendar` | Auto-fill title/attendees via gcalcli |
| `config set-gcalcli-path` | Path to gcalcli binary |
| `config set-gcalcli-calendar` | Google calendar name/email |
| `export` | Write `notes.md` |

## How it works

1. **Stereo record** — mic and system audio on separate channels (diarize pattern)
2. **Diarize each channel** — FluidAudio offline Pyannote pipeline
3. **Match speakers** — embeddings stored in SQLite, recognized next meeting
4. **Transcribe per segment** — Parakeet ASR via FluidAudio
5. **Accessibility overlay** — active speaker names from Zoom/Meet/Teams UI
6. **Export** — `notes.md` + JSON transcript

## Session output

```
~/.config/meetscribe/sessions/<id>/
  meeting.wav           # stereo: L=you, R=remote (removed after analysis by default)
  speaker-events.jsonl  # UI active-speaker timeline
  transcript.json
  transcript-resolved.json
  notes.md
  session.json
```

## Uninstall

```bash
rm -f ~/.local/bin/meetscribe
rm -rf ~/.config/meetscribe
# Optional: remove FluidAudio model cache under ~/Library/Caches/
```

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — on-device ASR + diarization
- [diarize](https://github.com/elien666/diarize) — stereo capture + pipeline architecture (MIT)
- [GRDB.swift](https://github.com/groue/GRDB.swift) — speaker + search storage

MIT License
