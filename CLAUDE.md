# Vox — agent notes

Project-specific facts and gotchas for working on this repo. User-facing docs
are in `README.md`; this file is for whoever (human or agent) is editing the
code.

## Build/test loop

```bash
make setup    # first time only: builds whisper.cpp + CLI, writes config, downloads default model
make test     # swift test — only VoxKit has an XCTest target (platform-independent core)
make app      # rebuilds dist/Vox.app
make install  # rebuilds + installs vox to $(brew --prefix)/bin
```

`VoxCore`/`VoxCLI`/`VoxApp` are macOS-only/GUI and have no automated test
coverage — verify changes there by actually running the CLI or the app.

## Things that will bite you

- **`make app` and `make install` can drift out of sync.** Both build the
  `vox` CLI, but only `make install` copies it to `$PATH`. If you change
  `VoxConfig`'s shape and only run `make app`, the app picks up the new
  schema while the installed `vox` on `$PATH` doesn't — they'll then fail to
  decode each other's writes to the shared `config.json`. `make app` prints a
  note when the CLI it just built differs from the one on `$PATH`; run
  `make install` when it does.

- **A running `Vox.app` caches `config.json` in memory and can clobber
  external edits.** `AppState.save()` reloads the file fresh immediately
  before applying one change, so a `vox config set` made while the app is
  running now survives the next Settings tweak. It does *not* mean the
  running app's live `state.config` (used for the in-flight hotkey/dictation
  pipeline) picks up an external edit — that still only happens on launch or
  an explicit save. After editing `config.json` via the CLI while testing,
  kill and relaunch the app to be sure it's using what you just wrote:
  `pkill -f Vox.app/Contents/MacOS/Vox; open dist/Vox.app`. There's no
  auto-reload and no auto-restart.

- **`dist/Vox.app` never updates itself.** `make app` only rewrites the file
  on disk; a running instance keeps running the old binary. Always kill and
  reopen after rebuilding if you need to see a change take effect.

- **The default macOS volume format (APFS) is case-insensitive.**
  `scripts/bundle-app.sh` names the CLI it embeds `Contents/MacOS/vox-cli`,
  not `vox` — a same-named copy next to `Contents/MacOS/Vox` (the app binary)
  would silently overwrite it. `scripts/sign.sh` signs `vox-cli` at that path
  for the same reason. Don't rename either back to `vox`.

- **Adding a field to `SessionEntry`, `VoxConfig`, or any of its nested
  structs must be `Optional`.** Both `config.json` and `sessions.json` are
  long-lived files that predate whatever field you're adding; a
  non-Optional new field with no custom decode logic makes every existing
  file fail to decode (`keyNotFound`). Synthesized `Decodable` treats a
  missing key as `nil` for an `Optional` property, which is what you want.

- **whisper.cpp's Metal shader compile is occasionally very slow (multi-
  second) on a fresh process launch** (`ggml_metal_library_init: loaded in
  N sec` in stderr) — this is macOS's system-wide Metal shader cache being
  cold, not a Vox bug. It's why the CLI (a fresh process every invocation)
  can feel inconsistent while the app (one long-lived `WhisperEngine`,
  loaded once) doesn't pay this cost per-dictation.

- **LLM modes send the transcript wrapped in `<transcript>…</transcript>`**
  (`ModeRunner.run`), not as a bare user message. A raw transcript that
  happens to mention "the LLM" or "this transcript" reads to a small model as
  a live message directed at it otherwise, and it answers instead of editing.
  Any custom mode prompt should assume that shape and say so.

- **`llm.max_output_tokens` defaults to `nil`** (omits `max_tokens` from the
  request). A reasoning-capable local model can burn an arbitrarily small cap
  entirely on chain-of-thought and never reach its actual answer — hit this
  directly with `gemma4:26b`. Don't reintroduce a small default cap.

- **A mode (LLM) failure never throws past `DictationPipeline.run()`.**
  Whisper has already succeeded by the time a mode runs; a mode failure
  degrades to `RecordResult.transcript = rawTranscript` with
  `RecordResult.modeError` set, rather than losing the already-successful
  transcription. Preserve this if you touch that code path — don't let a
  mode/LLM failure bubble up and discard a good transcript.
