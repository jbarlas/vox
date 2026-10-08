#!/usr/bin/env bash
# Update a source install without changing the user's configuration or models.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=""
PULL=true
RESTART=true
WHISPER=vendor/whisper.cpp
# whisper.cpp's CMake configure rewrites this tracked file on every build.
WHISPER_GENERATED=bindings/javascript/package.json

usage() {
  cat <<'HELP'
Usage: scripts/update.sh [--repo PATH] [--app PATH] [--no-pull] [--no-restart]

Pull a clean main checkout, rebuild/install the CLI and app, and restart the
app if it was running. Defaults to the running app, /Applications/Vox.app
if installed there, or the checkout's dist/Vox.app.

--no-pull      Reinstall local changes without pulling or updating submodules.
--no-restart   Leave the app closed after the update.
--repo PATH    Source checkout to update.
--app PATH     App bundle to install and relaunch.
HELP
}

fail() { echo "error: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo|--app)
      [[ $# -ge 2 && -n "$2" ]] || fail "$1 needs a path"
      if [[ "$1" == --repo ]]; then ROOT="$2"; else APP="$2"; fi
      shift 2 ;;
    --no-pull) PULL=false; shift ;;
    --no-restart) RESTART=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || fail "Vox updates require macOS."

# Resolve a bundle path through symlinks so it compares equal to the
# executable path ps reports.
canonical() {
  if [[ -d "$(dirname "$1")" ]]; then
    echo "$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
  else
    echo "$1"
  fi
}

# Resolve --app against the caller's directory, before changing into ROOT.
if [[ -n "$APP" ]]; then
  [[ "$(basename "$APP")" == Vox.app ]] || fail "--app must name a Vox.app bundle."
  [[ "$APP" == /* ]] || APP="$PWD/$APP"
  [[ -d "$(dirname "$APP")" ]] || fail "Directory not found: $(dirname "$APP")"
  APP="$(canonical "$APP")"
fi

ROOT="$(cd "$ROOT" && pwd -P)"
[[ -f "$ROOT/Package.swift" && -f "$ROOT/scripts/bundle-app.sh" ]] || fail "Not a Vox checkout: $ROOT"
cd "$ROOT"

if $PULL; then
  [[ "$(git branch --show-current)" == main ]] || fail "Switch to main first, or use --no-pull to install the current checkout."
  # An outdated submodule pointer is not a local change: the submodule
  # update below is what repairs it.
  [[ -z "$(git status --porcelain --ignore-submodules=all)" ]] || fail "Commit or stash local changes first, or use --no-pull."
  if [[ -e "$WHISPER/.git" ]]; then
    edits="$(git -C "$WHISPER" status --porcelain --untracked-files=no | grep -v " $WHISPER_GENERATED\$" || true)"
    [[ -z "$edits" ]] || fail "$WHISPER has local edits. Revert them, or use --no-pull."
  fi
fi

# Match only the app executable, never the CLI or unrelated processes. With
# --app, only copies running from that bundle are stopped and restarted.
PIDS=()
RUNNING_APP=""
while read -r pid executable; do
  case "$executable" in
    */Vox.app/Contents/MacOS/Vox)
      bundle="$(canonical "${executable%/Contents/MacOS/Vox}")"
      if [[ -n "$APP" ]]; then
        [[ "$bundle" == "$APP" ]] || continue
      elif [[ -n "$RUNNING_APP" && "$RUNNING_APP" != "$bundle" ]]; then
        fail "Multiple Vox copies are running. Choose the installation with --app PATH."
      fi
      RUNNING_APP="$bundle"
      PIDS+=("$pid") ;;
  esac
done < <(ps -axww -o pid=,comm=)

if [[ -z "$APP" ]]; then
  if [[ -n "$RUNNING_APP" ]]; then
    APP="$RUNNING_APP"
  elif [[ -d /Applications/Vox.app ]]; then
    APP=/Applications/Vox.app
  else
    mkdir -p "$ROOT/dist"
    APP="$ROOT/dist/Vox.app"
  fi
fi

# An ad hoc signature would replace a Developer ID one and reset the app's
# microphone and Accessibility permissions.
if [[ -d "$APP" && -z "${DEVELOPER_ID:-}" ]]; then
  team="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)"
  if [[ -n "$team" && "$team" != "not set" ]]; then
    fail "$APP is signed by team $team. Set DEVELOPER_ID to that signing identity and rerun."
  fi
fi

if $PULL; then
  echo "==> Pulling origin/main"
  git pull --ff-only origin main
  if [[ -e "$WHISPER/.git" ]]; then
    git -C "$WHISPER" checkout -- "$WHISPER_GENERATED" 2>/dev/null || true
  fi
  git submodule update --init --recursive
fi

# Build the new bundle beside the destination, so nothing the running app
# uses changes until it has quit. Replacing the whole bundle also drops
# resources and signatures left by earlier builds.
STAGING=""
STOPPED=false
REPLACED=false
RESTARTED=false
cleanup() {
  local status=$?
  if [[ -n "$STAGING" ]]; then
    if [[ -d "$STAGING/previous.app" ]] && ! $REPLACED; then
      echo "==> Previous app preserved at $STAGING/previous.app" >&2
    else
      rm -rf "$STAGING"
    fi
  fi
  # Never leave the app stopped because a later step failed.
  if [[ $status -ne 0 ]] && $STOPPED && ! $RESTARTED && [[ -d "$APP" ]]; then
    echo "==> Relaunching $APP" >&2
    open "$APP" || true
  fi
}
trap cleanup EXIT
STAGING="$(mktemp -d "$(dirname "$APP")/.vox-update.XXXXXX")"

echo "==> Building Vox"
make app sign APP_BUNDLE="$STAGING/Vox.app"

echo "==> Installing the CLI"
make install

if [[ ${#PIDS[@]} -gt 0 ]]; then
  echo "==> Quitting the running app"
  # The app quits normally on SIGTERM. Signal every copy before waiting, so
  # one copy that hangs does not leave the others stopped without a restart.
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  STOPPED=true
  alive=()
  for ((attempt = 0; attempt < 50; attempt++)); do
    alive=()
    for pid in "${PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then alive+=("$pid"); fi
    done
    [[ ${#alive[@]} -gt 0 ]] || break
    sleep 0.2
  done
  if [[ ${#alive[@]} -gt 0 ]]; then
    fail "Vox (PID ${alive[*]}) did not quit. The CLI was updated; quit Vox and rerun to update the app."
  fi
fi

echo "==> Installing $APP"
if [[ -e "$APP" ]]; then mv "$APP" "$STAGING/previous.app"; fi
if ! mv "$STAGING/Vox.app" "$APP"; then
  if [[ -d "$STAGING/previous.app" ]]; then mv "$STAGING/previous.app" "$APP" || true; fi
  fail "Could not replace $APP."
fi
REPLACED=true

if $RESTART && [[ ${#PIDS[@]} -gt 0 ]]; then
  echo "==> Restarting $APP"
  RESTARTED=true
  open "$APP"
fi
# --no-restart: leaving the app closed is what was asked for.
RESTARTED=true
echo "==> Updated CLI and $APP"
