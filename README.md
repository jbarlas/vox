<p align="center">
  <img src="assets/cover.png" alt="Vox" width="240">
</p>

# Vox

Local, offline speech-to-text for macOS: a menu bar app you dictate into with a
hotkey, plus a CLI over the same core, built directly on
[whisper.cpp](https://github.com/ggerganov/whisper.cpp).

Audio never leaves the machine. Hold **⌃⌥Space** anywhere, talk, let go, and the
transcript is on your clipboard — optionally cleaned up or rewritten first by a
local LLM.

The CLI is the same pipeline without the GUI, for scripting and for agents that
want a transcript as JSON on stdout; it does not need the app to be running.

## Requirements

- macOS 13 or later (Apple silicon recommended; Metal is enabled by default)
- Xcode command line tools and `cmake` (`brew install cmake`)
- Optional: `ffmpeg`, only for `vox transcribe` on formats AVFoundation cannot decode
- Optional: an OpenAI-compatible `/v1/chat/completions` endpoint, only for LLM
  modes — [LiteLLM](https://github.com/BerriAI/litellm) (the default) or
  something like Ollama directly both work

## Setup

```bash
git clone --recurse-submodules https://github.com/jbarlas/vox.git
cd vox
make setup            # builds whisper.cpp + the CLI, writes a config, downloads the default model
make app              # builds dist/Vox.app
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

`make sign` ad-hoc signs the app (set `DEVELOPER_ID` for a distributable build)
and `make notarize` submits it to Apple. `make brew-formula` writes a
build-from-source formula to `dist/vox.rb` for a tap.

The bundle also carries the CLI at `Vox.app/Contents/MacOS/vox-cli`, so an
app-only install (drag `Vox.app` to `/Applications`, no `make install`) can
still expose `vox` on your `PATH`:

```bash
ln -s /Applications/Vox.app/Contents/MacOS/vox-cli /opt/homebrew/bin/vox
```

## Menu bar app

`dist/Vox.app` runs as a menu bar item (no Dock icon). The icon reflects idle,
recording, and transcribing; the popover has start/stop, a level meter, the mode
picker, and the last transcript; Settings covers model, language, hotkey,
recording limits, vocabulary, modes, output, and feedback. Settings → Modes
creates, renames, edits, and deletes modes; a new mode starts from a prompt
skeleton that already has the `<transcript>` framing described under [Modes](#modes).

Default hotkey is **⌃⌥Space**, press-and-hold (switchable to toggle in
Settings). Settings → General has a "Record new shortcut…" button that
captures the next chord you press (must include at least one modifier); the
same key/modifiers are settable directly with `vox config set hotkey.key_code`
and `vox config set hotkey.modifiers`. It is registered through Carbon's
`RegisterEventHotKey`, so it needs no Accessibility permission.

While recording, a click-through waveform strip floats under the menu bar (on
whichever screen the pointer is on), and stock macOS sounds mark four events:
recording started, recording stopped, dictation finished, and failure. The
overlay and each sound are configurable in Settings → Feedback, or under
`feedback.*` via `vox config set`.

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
`--save-audio`, `--pretty`, `--quiet`, `--verbose` (adds whisper.cpp's own
native logging, which is otherwise silenced).

Recording stops on trailing silence, on `--timeout`, at
`recording.max_duration_seconds`, or on the first Ctrl+C (a second one aborts).

### Output destinations

`--output` accepts `clipboard` (default), `auto-paste`, `stdout`, `json`, `none`.
Only `auto-paste` needs Accessibility permission. Progress messages always go to
stderr, so stdout carries the transcript or the JSON envelope and nothing else.

### For agents

Run `vox record --output json --timeout <secs>` as a subprocess and parse
stdout. No clipboard, no GUI, no Accessibility permission:

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

Failures are reported the same way — `ok: false` with a stable `error.code` —
and the exit code is nonzero:

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

A mode failure is the one exception to the table: whisper.cpp has already
succeeded by then, so `result.transcript` falls back to `raw_transcript`, the
envelope stays `ok: true` with exit 0, and `result.mode_error` describes what
did not run. Scripts that require the mode's output should check
`result.mode_error` rather than the exit code alone.

## Configuration

One JSON file is shared by the CLI and the app, at
`~/Library/Application Support/Vox/config.json` (override the directory with
`$VOX_HOME`). Edit it with `vox config set <key> <value>`; `vox config list` shows
every key.

Notable keys: `model`, `default_mode`, `language`, `vocab`, `hotkey.*`,
`recording.max_duration_seconds`, `recording.silence_timeout_seconds`,
`recording.silence_threshold_db`, `output.destination`,
`output.session_history_limit` (`null`/`off` keeps every entry forever),
`feedback.*`, `llm.provider`, `llm.base_url`, `llm.model`, `llm.api_key_env_var`,
`llm.max_output_tokens` (`null` by default — omits the cap entirely).

Vox never stores an API key: `llm.api_key_env_var` names the environment variable
to read it from.

`llm.base_url` may only use `http://` for a loopback host (the default
`http://127.0.0.1:4000/v1` qualifies); anything else has to be `https://`, since
the transcript and the API key would otherwise cross the network in cleartext.
For a plain-HTTP LiteLLM on a network you trust,
`vox config set llm.allow_insecure_http true` opts out.

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
- your own — Settings → Modes (`+`), or `vox modes add <name> --prompt "..."`

A mode's prompt is the system message; the transcript arrives as the user
message wrapped in `<transcript>…</transcript>`, which keeps a small model from
answering a transcript instead of editing it. Write custom prompts against that
shape, and tell the model not to echo the tags.

LLM modes talk to an OpenAI-compatible `/v1/chat/completions` endpoint, by
default a local LiteLLM at `http://127.0.0.1:4000/v1`.

```bash
vox modes add bullets --prompt "Rewrite the given transcript as terse bullet points. Output only the bullets, no tags or commentary."
vox modes test bullets "so we should probably ship the fix today and tell support"
vox record --mode bullets
```

### Setting up LiteLLM

The shipped default (`llm.provider` `litellm`, `llm.base_url`
`http://127.0.0.1:4000/v1`) assumes a LiteLLM proxy on this machine in front of
a local model. Nothing in `make setup` starts one; this is the path from
nothing installed to a working LLM mode. To skip the proxy and talk to Ollama
directly, or to use a hosted API, see [Providers](#providers) instead.

Install LiteLLM and [Ollama](https://ollama.com), pull a model, and write a
`config.yaml` that routes a model name to it:

```bash
pip install 'litellm[proxy]'
ollama pull phi4-mini
```

```yaml
model_list:
  - model_name: vox
    litellm_params:
      model: ollama/phi4-mini
      api_base: http://localhost:11434
```

Run the proxy on the port Vox expects, and point `llm.model` at the name you
declared:

```bash
litellm --config config.yaml --port 4000
vox config set llm.model vox
vox modes test prompt "um so can you uh write this up as a request for the api team"
```

Pick a small, fast, **non-reasoning** instruction model. LLM modes are short
edits of a transcript, not open-ended chat, so a 3–4B instruct model such as
[`phi4-mini`](https://ollama.com/library/phi4-mini) is quick enough that the
mode step stops being noticeable. Reasoning/"thinking" models (DeepSeek-R1
distills, `gemma` thinking variants, Qwen3 in thinking mode, and the like) are
a bad fit: they spend the whole output-token budget on chain-of-thought and
never emit an answer, which surfaces in Vox as
`LLM response contained no message content`. If you see that error, switch
models rather than raising `llm.max_output_tokens`.

### Providers

A provider is a preset for the endpoint and key-variable pair, so a hosted API
is one choice rather than a URL to look up. `vox config providers` lists them
with their key variables and whether each is set in the current environment.

```bash
vox config providers
vox config set llm.provider openai
vox config set llm.model gpt-4o-mini
export OPENAI_API_KEY=…
```

Anything not in that list works by setting `llm.base_url` and
`llm.api_key_env_var` directly. Settings → LLM edits the same fields, and shows
whether the key variable is visible to the app — the menu bar app inherits the
login environment, not your shell's, so a hosted key usually needs
`launchctl setenv OPENAI_API_KEY …` (or a login item) rather than a line in
`.zshrc`.

A single mode can go somewhere else — a cheap local model for `cleanup`-style
rewrites, a hosted one for `email`:

```bash
vox modes add email-pro --prompt "..." --provider openai --model gpt-4o
```

The same fields are per-mode in Settings → Modes. A mode's endpoint does not
inherit the global key variable or the `llm.allow_insecure_http` opt-in, both of
which were chosen for the global endpoint: give the mode its own
`--api-key-env`. Modes that override nothing keep using `llm.*`.

### Session history

Every dictation — successful or not — is logged to
`~/Library/Application Support/Vox/sessions.json`, newest first: start/finish
time, mode, model, stop reason, per-stage timings, both the raw whisper.cpp
transcript and the mode output, and on failure the error code/message. It
doubles as a correction/fine-tuning dataset, not just a clipboard safety net.
Unbounded by default; `output.session_history_limit` caps it if you want that.

```bash
vox config set output.keep_session_history false      # turn logging off
vox config set output.session_history_limit 200        # cap it instead of keeping everything
```

In the app, Settings → Output → History has the same controls plus "View
session data" (opens the file) and "Clear history now".

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

Not implemented yet: voice commands and live streaming transcription. Deferred
feature work is tracked as [`feature`-labeled
issues](https://github.com/jbarlas/vox/issues?q=is%3Aissue+is%3Aopen+label%3Afeature).
