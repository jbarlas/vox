# Vox

Local, offline speech-to-text for macOS: a menu bar app and a CLI over one shared
core, built directly on [whisper.cpp](https://github.com/ggerganov/whisper.cpp).

Audio never leaves the machine. The CLI is headless — it does not need the app to
be running — and can emit a single JSON object on stdout, which is the intended
way for an agent to use it: no clipboard, no GUI, no Accessibility permission.

```bash
vox record --output json --timeout 30
```

```json
{
  "schema_version": 1,
  "ok": true,
  "result": {
    "transcript": "check the deploy logs for errors",
    "raw_transcript": "uh check the deploy logs for errors",
    "mode": "cleanup",
    "mode_kind": "cleanup",
    "model": "small.en",
    "language": "en",
    "duration_ms": 2340,
    "audio_duration_ms": 1800,
    "stop_reason": "silence",
    "started_at": "2026-08-31T14:02:11Z",
    "finished_at": "2026-08-31T14:02:13Z",
    "timings": {
      "recording_ms": 1800,
      "normalize_ms": 0,
      "transcribe_ms": 500,
      "mode_ms": 40,
      "total_ms": 2340
    }
  }
}
```

## Requirements

- macOS 13 or later (Apple silicon recommended; Metal is enabled by default)
- Xcode command line tools and `cmake` (`brew install cmake`)
- Optional: `ffmpeg`, only for `vox transcribe` on formats AVFoundation cannot decode
- Optional: a [LiteLLM](https://github.com/BerriAI/litellm) instance, only for LLM modes

## Setup

```bash
git clone --recurse-submodules https://github.com/jbarlas/vox.git
cd vox
make setup            # builds whisper.cpp + the CLI, writes a config, downloads the default model
make install          # optional: copies the CLI to your Homebrew prefix's bin/ (e.g. /opt/homebrew/bin/vox on Apple silicon, /usr/local/bin/vox on Intel); pass PREFIX=... to override
vox permissions --request
```

`make setup` is non-interactive. It installs `small.en` (~466 MB), a good
latency/accuracy tradeoff for dictation; swap it any time:

```bash
make setup MODEL=large-v3-turbo-q5_0   # at setup time
vox models list                        # see everything, and what is installed
vox models download large-v3-turbo     # fetch another one
vox models set large-v3-turbo          # and use it (also in Settings → General)
```

Build the menu bar app with `make app`, which produces `dist/Vox.app`; `make sign`
ad-hoc signs it (set `DEVELOPER_ID` for a distributable build) and `make notarize`
submits it to Apple. `make brew-formula` writes a build-from-source formula to
`dist/vox.rb` for a tap.

The bundle also carries the CLI at `Vox.app/Contents/MacOS/vox-cli`, so an
app-only install (drag `Vox.app` to `/Applications`, no `make install`) can
still expose `vox` on your `PATH`:

```bash
ln -s /Applications/Vox.app/Contents/MacOS/vox-cli /opt/homebrew/bin/vox
```

## CLI

| Command | Purpose |
| --- | --- |
| `vox record` | Record from the microphone and transcribe |
| `vox transcribe <file>` | Transcribe an existing audio file |
| `vox config get/set/list` | Read and edit the shared config |
| `vox config vocab` | Manage custom vocabulary |
| `vox models list/download/set/remove` | Manage whisper models |
| `vox modes list/add/remove/set-default/test` | Manage post-processing modes |
| `vox permissions` | Check microphone and Accessibility access |

Recording options: `--mode`, `--model`, `--language`, `--output`, `--timeout`,
`--save-audio`, `--pretty`, `--quiet`.

Recording stops on trailing silence, on `--timeout`, at
`recording.max_duration_seconds`, or on the first Ctrl+C (a second one aborts).

### Output destinations

`--output` accepts `clipboard` (default), `auto-paste`, `stdout`, `json`, `none`.
Only `auto-paste` needs Accessibility permission. Progress messages always go to
stderr, so stdout carries the transcript or the JSON envelope and nothing else.

### For agents

Run `vox record --output json --timeout <secs>` as a subprocess and parse stdout.
Failures are reported the same way — `ok: false` with a stable `error.code` — and
the exit code is nonzero:

| Code | Exit | Meaning |
| --- | --- | --- |
| `config` | 2 | Bad config, unknown mode, or unknown model |
| `microphone` | 3 | No usable input device |
| `permission` | 4 | Microphone or Accessibility access denied |
| `audio` | 5 | Capture, decode, or normalization failure |
| `model` | 6 | Model missing, corrupt, or failed to load |
| `transcription` | 7 | whisper.cpp failed |
| `timeout` | 8 | `--timeout` elapsed |
| `llm` | 9 | LLM mode failed |
| `output` | 10 | Could not deliver the transcript |
| `cancelled` | 11 | Interrupted |
| `internal` | 1 | Anything else |

`schema_version` is bumped only for breaking changes to this envelope.

## Configuration

One JSON file is shared by the CLI and the app, at
`~/Library/Application Support/Vox/config.json` (override the directory with
`$VOX_HOME`). Edit it with `vox config set <key> <value>`; `vox config list` shows
every key.

Notable keys: `model`, `default_mode`, `language`, `vocab`, `hotkey.*`,
`recording.max_duration_seconds`, `recording.silence_timeout_seconds`,
`output.destination`, `feedback.*`, `llm.base_url`, `llm.model`,
`llm.api_key_env_var`.

Vox never stores an API key: `llm.api_key_env_var` names the environment variable
to read it from.

### Custom vocabulary

```bash
vox config vocab --add "Kubernetes, LiteLLM, GGUF"
vox config vocab --show-prompt
```

Terms are injected as whisper.cpp's initial prompt, so they bias the decode
itself rather than being search-and-replaced afterwards.

### Modes

- `raw` — the transcript, untouched
- `cleanup` — local rule-based filler and stutter removal, no network
- `prompt`, `email` — built-in LLM modes
- your own — `vox modes add <name> --prompt "..."`

LLM modes always talk to one OpenAI-compatible `/v1/chat/completions` endpoint,
by default a local LiteLLM at `http://127.0.0.1:4000/v1`. Whether a mode's model
runs on Ollama or a hosted provider is LiteLLM routing, not a Vox concern.

```bash
vox modes add bullets --prompt "Rewrite the transcript as terse bullet points."
vox modes test bullets "so we should probably ship the fix today and tell support"
vox record --mode bullets
```

## Menu bar app

`dist/Vox.app` runs as a menu bar item (no Dock icon). The icon reflects idle,
recording, and transcribing; the popover has start/stop, a level meter, the mode
picker, and the last transcript; Settings covers model, language, hotkey,
recording limits, vocabulary, modes, output, and feedback.

While recording, a click-through waveform strip floats under the menu bar (on
whichever screen the pointer is on), and Vox plays a stock macOS sound when
recording starts and stops. Both are configurable:

```bash
vox config set feedback.start_sound Glass   # any sound in /System/Library/Sounds
vox config set feedback.stop_sound off      # silence just this one
vox config set feedback.sounds_enabled false
vox config set feedback.show_overlay false
```

Default hotkey is **⌃⌥Space**, press-and-hold (switchable to toggle in
Settings). Settings → General has a "Record new shortcut…" button that
captures the next chord you press (must include at least one modifier); the
same key/modifiers are settable directly with `vox config set hotkey.key_code`
and `vox config set hotkey.modifiers`. It is registered through Carbon's
`RegisterEventHotKey`, so it needs no Accessibility permission.

## Development

```bash
make test    # swift test — the platform-independent core
make lint    # swift-format lint, if installed
make clean   # or: make distclean, which also drops the whisper.cpp build
```

`VoxKit` holds everything portable (config, modes, LLM client, JSON contract) and
is what the test suite covers. `VoxCore` holds the macOS-only pipeline (audio
capture, whisper.cpp bridge, output routing); `VoxCLI` and `VoxApp` are thin
front-ends over it — neither wraps the other.

Not implemented yet: voice commands and live streaming transcription.
