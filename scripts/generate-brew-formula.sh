#!/usr/bin/env bash
# Generates a Homebrew formula for the Vox CLI into dist/vox.rb.
#
# The formula builds from source (SwiftPM + the whisper.cpp submodule) rather
# than shipping a bottle, so it does not need a signed release artifact — which
# means a tap can be published before code signing is set up.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --always)}"
REPO_URL="${REPO_URL:-$(git -C "$ROOT" remote get-url origin | sed 's/\.git$//')}"
TAG="${TAG:-$VERSION}"
OUTPUT="$ROOT/dist/vox.rb"

mkdir -p "$ROOT/dist"
cat > "$OUTPUT" <<FORMULA
class Vox < Formula
  desc "Local, offline speech-to-text with a scriptable JSON interface"
  homepage "$REPO_URL"
  url "$REPO_URL.git", tag: "$TAG"
  version "${VERSION#v}"
  license "MIT"
  head "$REPO_URL.git", branch: "main"

  depends_on :macos
  depends_on xcode: ["15.0", :build]
  depends_on "cmake" => :build

  def install
    # Builds the vendored whisper.cpp into a single static archive, then the CLI
    # against it. Both steps must run from the repo root.
    system "./scripts/build-whisper.sh"
    system "swift", "build", "-c", "release", "--product", "vox", "--disable-sandbox"
    bin.install ".build/release/vox"
  end

  def caveats
    <<~EOS
      Download the default model before first use:
        vox models download

      Grant microphone access on first run:
        vox permissions --request
    EOS
  end

  test do
    assert_match "vox", shell_output("#{bin}/vox --help")
  end
end
FORMULA

echo "==> Wrote $OUTPUT (version $VERSION, tag $TAG)"
echo "    Publish it by copying into your tap: Formula/vox.rb"
