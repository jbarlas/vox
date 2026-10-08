#!/usr/bin/env bash
# Update a source install without changing the user's configuration or models.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=""
CLI=""
PULL=true
RESTART=true
ALLOW_PERMISSION_RESET=false
WHISPER=vendor/whisper.cpp
# whisper.cpp's CMake configure rewrites this tracked file on every build.
WHISPER_GENERATED=bindings/javascript/package.json

usage() {
  cat <<'HELP'
Usage: scripts/update.sh [--repo PATH] [--app PATH] [--cli PATH] [--no-pull] [--no-restart] [--allow-permission-reset]

Pull a clean main checkout, rebuild/install the CLI and app, and restart the
app if it was running. Defaults to the running app, /Applications/Vox.app
if installed there, or the checkout's dist/Vox.app.

--no-pull      Reinstall local changes without pulling or updating submodules.
--no-restart   Leave the app closed after the update.
--repo PATH    Source checkout to update.
--app PATH     App bundle to install and relaunch.
--cli PATH     Installed vox to replace (defaults to the vox on PATH).
--allow-permission-reset   Allow a new signing identity; app permissions may need regranting.
HELP
}

fail() { echo "error: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo|--app|--cli)
      [[ $# -ge 2 && -n "$2" ]] || fail "$1 needs a path"
      case "$1" in
        --repo) ROOT="$2" ;;
        --app) APP="$2" ;;
        --cli) CLI="$2" ;;
      esac
      shift 2 ;;
    --no-pull) PULL=false; shift ;;
    --no-restart) RESTART=false; shift ;;
    --allow-permission-reset) ALLOW_PERMISSION_RESET=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || fail "Vox updates require macOS."

# Resolve a path through symlinks, including its last component, so a
# symlinked bundle compares equal to the executable path ps reports and is
# replaced at its real location rather than by overwriting the link.
canonical() {
  local path="$1" target
  while [[ -L "$path" ]]; do
    target="$(readlink "$path")"
    [[ "$target" == /* ]] || target="$(dirname "$path")/$target"
    path="$target"
  done
  if [[ -d "$(dirname "$path")" ]]; then
    echo "$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")"
  else
    echo "$path"
  fi
}

# Resolve --app against the caller's directory, before changing into ROOT.
if [[ -n "$APP" ]]; then
  [[ "$(basename "$APP")" == Vox.app ]] || fail "--app must name a Vox.app bundle."
  [[ "$APP" == /* ]] || APP="$PWD/$APP"
  [[ -d "$(dirname "$APP")" ]] || fail "Directory not found: $(dirname "$APP")"
  APP="$(canonical "$APP")"
  [[ "$(basename "$APP")" == Vox.app ]] || fail "--app resolves to $APP, which is not a Vox.app bundle."
fi

# Install the CLI where the one being run lives, so a custom PREFIX install
# is updated in place. A CLI inside an app bundle (the embedded vox-cli) is
# replaced along with the bundle.
[[ -n "$CLI" ]] || CLI="$(command -v vox 2>/dev/null || true)"
[[ -z "$CLI" ]] || CLI="$(canonical "$CLI")"
INSTALL_ARGS=()
INSTALL_CLI=true
case "$CLI" in
  "") ;;
  */Vox.app/Contents/MacOS/vox-cli)
    cli_app="${CLI%/Contents/MacOS/vox-cli}"
    [[ -z "$APP" || "$APP" == "$cli_app" ]] \
      || fail "This CLI belongs to $cli_app. Use that bundle for --app so the CLI is updated too."
    APP="$cli_app"
    INSTALL_CLI=false ;;
  */bin/vox) INSTALL_ARGS=(PREFIX="${CLI%/bin/vox}") ;;
esac

ROOT="$(cd "$ROOT" && pwd -P)"
[[ -f "$ROOT/Package.swift" && -f "$ROOT/scripts/bundle-app.sh" ]] || fail "Not a Vox checkout: $ROOT"
cd "$ROOT"

if $PULL; then
  [[ "$(git branch --show-current)" == main ]] || fail "Switch to main first, or use --no-pull to install the current checkout."
  # An outdated submodule pointer is not a local change: the submodule
  # update below is what repairs it.
  # Git itself rejects a pull that would overwrite an untracked file.
  [[ -z "$(git status --porcelain --ignore-submodules=all --untracked-files=no)" ]] || fail "Commit or stash local changes first, or use --no-pull."
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
done < <(ps -U "$(id -u)" -ww -o pid=,comm=)

if [[ -z "$APP" ]]; then
  if [[ -n "$RUNNING_APP" ]]; then
    APP="$RUNNING_APP"
  elif [[ -d /Applications/Vox.app ]]; then
    APP="$(canonical /Applications/Vox.app)"
  else
    mkdir -p "$ROOT/dist"
    APP="$ROOT/dist/Vox.app"
  fi
fi

# Older versions terminate immediately on SIGTERM, so even the new updater
# cannot safely stop them during a dictation. Require a manual quit once.
if [[ ${#PIDS[@]} -gt 0 ]]; then
  waits_for_dictation="$(plutil -extract VoxWaitsForDictationOnQuit raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$waits_for_dictation" == true ]] \
    || fail "This running Vox version cannot finish dictation before quitting. Finish dictation and quit Vox manually, then rerun the update."
fi

# Microphone and Accessibility grants follow the signing team, so a bundle
# signed ad hoc or by another team would lose them. The staged bundle's team
# is checked against this after signing.
team_of() {
  local team
  team="$(codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)"
  [[ "$team" == "not set" ]] || echo "$team"
}
INSTALLED_TEAM=""
[[ ! -d "$APP" ]] || INSTALLED_TEAM="$(team_of "$APP")"
if [[ -n "$INSTALLED_TEAM" && -z "${DEVELOPER_ID:-${CODE_SIGN_IDENTITY:-}}" ]] && ! $ALLOW_PERMISSION_RESET; then
  fail "$APP is signed by team $INSTALLED_TEAM. Set DEVELOPER_ID to that signing identity and rerun."
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
apps_still_running() {
  local pid
  for pid in "${PIDS[@]+"${PIDS[@]}"}"; do
    if kill -0 "$pid" 2>/dev/null; then return 0; fi
  done
  return 1
}
cleanup() {
  local status=$?
  if [[ -n "$STAGING" ]]; then
    if [[ -d "$STAGING/previous.app" ]] && ! $REPLACED; then
      echo "==> Previous app preserved at $STAGING/previous.app" >&2
    else
      rm -rf "$STAGING"
    fi
  fi
  # Never leave the app stopped because a later step failed, unless it was
  # asked to stay closed.
  if [[ $status -ne 0 ]] && $RESTART && $STOPPED && ! $RESTARTED && ! apps_still_running && [[ -d "$APP" ]]; then
    echo "==> Relaunching $APP" >&2
    open "$APP" || true
  fi
}
trap cleanup EXIT
STAGING="$(mktemp -d "$(dirname "$APP")/.vox-update.XXXXXX")"

echo "==> Building Vox"
make app sign APP_BUNDLE="$STAGING/Vox.app"

if [[ -n "$INSTALLED_TEAM" ]] && ! $ALLOW_PERMISSION_RESET; then
  staged_team="$(team_of "$STAGING/Vox.app")"
  [[ "$staged_team" == "$INSTALLED_TEAM" ]] \
    || fail "DEVELOPER_ID signs for team ${staged_team:-none}, but $APP is signed by team $INSTALLED_TEAM. Use an identity from team $INSTALLED_TEAM."
fi

# Team IDs alone do not establish continuity (including ad-hoc and local
# certificate signatures). Check both designated requirements, as macOS does
# when deciding whether two versions share privacy grants. Never weaken a
# requirement to make a changed ad-hoc build look like the previous binary.
requirement_of() {
  codesign --display --requirements - "$1" 2>/dev/null \
    | sed -n -e 's/^designated => //p' -e 's/^# designated => //p'
}
if [[ -d "$APP" ]]; then
  requirement_of "$APP" > "$STAGING/installed.requirement" || true
  requirement_of "$STAGING/Vox.app" > "$STAGING/staged.requirement" || true
  if [[ ! -s "$STAGING/installed.requirement" || ! -s "$STAGING/staged.requirement" ]] \
    || ! codesign --verify -R "$STAGING/installed.requirement" "$STAGING/Vox.app" >/dev/null 2>&1 \
    || ! codesign --verify -R "$STAGING/staged.requirement" "$APP" >/dev/null 2>&1; then
    if ! $ALLOW_PERMISSION_RESET; then
      fail "The new app has a different signing identity. Ad-hoc rebuilds can lose Accessibility and Microphone permissions. Reuse CODE_SIGN_IDENTITY or DEVELOPER_ID, or pass --allow-permission-reset and grant permissions again after updating."
    fi
    echo "==> Signing identity changed; grant Accessibility and Microphone permissions again after updating."
  fi
fi

if [[ ${#PIDS[@]} -gt 0 ]]; then
  echo "==> Waiting for Vox to finish dictation and quit (Ctrl+C cancels the update)"
  # The app quits normally on SIGTERM. Signal every copy before waiting, so
  # one copy that hangs does not leave the others stopped without a restart.
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  STOPPED=true
  while apps_still_running; do
    sleep 0.2
  done
fi

# Wait for output delivery before changing either installed executable.
if $INSTALL_CLI; then
  echo "==> Installing the CLI"
  make install "${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}"
else
  echo "==> $CLI is inside an app bundle; it is updated with the app"
fi

echo "==> Installing $APP"
if [[ -e "$APP" ]]; then mv "$APP" "$STAGING/previous.app"; fi
if ! mv "$STAGING/Vox.app" "$APP"; then
  if [[ -d "$STAGING/previous.app" ]]; then mv "$STAGING/previous.app" "$APP" || true; fi
  fail "Could not replace $APP."
fi
REPLACED=true

# Set before `open`, so a failed relaunch is not retried by cleanup, and
# also covers --no-restart, where leaving the app closed is what was asked.
RESTARTED=true
if $RESTART && [[ ${#PIDS[@]} -gt 0 ]]; then
  echo "==> Restarting $APP"
  open "$APP"
fi
echo "==> Updated CLI and $APP"
