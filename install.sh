#!/usr/bin/env bash
# voice-draft installer. Idempotent; never uses sudo.
#
#   ./install.sh                     install everything
#   OLLAMA_MODEL=llama3.2:3b ./install.sh   pull a different cleanup model
#   SKIP_WHISPER_MODEL=1 ./install.sh       don't download the Whisper model

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="$HOME/.local/share/voice-draft/models"
WHISPER_MODEL="${WHISPER_MODEL:-ggml-large-v3-turbo.bin}"
WHISPER_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_MODEL"
WHISPER_API="https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/main"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:3b}"
OLLAMA_URL="http://localhost:11434"
HS_DIR="$HOME/.hammerspoon"
HS_INIT="$HS_DIR/init.lua"

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warning: %s\n' "$*" >&2; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }

if [[ $EUID -eq 0 ]]; then die "do not run as root"; fi

step "Checking platform"
[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon (arm64) only"
ok "macOS $(sw_vers -productVersion) on $(sysctl -n machdep.cpu.brand_string)"

BREW="$(command -v brew || true)"
[[ -z "$BREW" && -x /opt/homebrew/bin/brew ]] && BREW=/opt/homebrew/bin/brew
[[ -n "$BREW" ]] || die "Homebrew not found. Install it from https://brew.sh and re-run."
ok "Homebrew at $BREW"

step "Installing command-line tools"
for formula in sox whisper-cpp; do
  if "$BREW" list --formula "$formula" >/dev/null 2>&1; then
    ok "$formula already installed"
  else
    "$BREW" install "$formula"
  fi
done

step "Installing Hammerspoon"
if [[ -d /Applications/Hammerspoon.app || -d "$HOME/Applications/Hammerspoon.app" ]]; then
  ok "Hammerspoon already installed"
else
  "$BREW" install --cask hammerspoon
fi

step "Installing Ollama"
if command -v ollama >/dev/null 2>&1 || [[ -d /Applications/Ollama.app ]]; then
  ok "Ollama already installed ($(command -v ollama || echo /Applications/Ollama.app))"
else
  "$BREW" install ollama
fi
OLLAMA_BIN="$(command -v ollama || echo /Applications/Ollama.app/Contents/Resources/ollama)"

step "Downloading Whisper model ($WHISPER_MODEL)"
mkdir -p "$MODEL_DIR"
MODEL_PATH="$MODEL_DIR/$WHISPER_MODEL"
if [[ -n "${SKIP_WHISPER_MODEL:-}" ]]; then
  ok "skipped (SKIP_WHISPER_MODEL set)"
elif [[ -s "$MODEL_PATH" ]]; then
  ok "already present: $MODEL_PATH"
else
  # Resumable download to a .part file, then verify and move into place.
  # Abort a stalled transfer (<10 KB/s for 60 s) and resume, up to 5 times.
  for attempt in 1 2 3 4 5; do
    if curl -L --fail --retry 3 --speed-limit 10240 --speed-time 60 \
         -C - -o "$MODEL_PATH.part" "$WHISPER_URL"; then
      break
    fi
    [[ $attempt -eq 5 ]] && die "download failed; re-run install.sh to resume"
    warn "download interrupted, resuming (attempt $((attempt + 1)) of 5)"
    sleep 2
  done
  expected=""
  if command -v python3 >/dev/null 2>&1; then
    expected="$(curl -s --fail "$WHISPER_API" | python3 -c '
import json, sys
name = sys.argv[1]
for f in json.load(sys.stdin):
    if f.get("path") == name and f.get("lfs"):
        print(f["lfs"].get("oid", ""))
' "$WHISPER_MODEL" 2>/dev/null || true)"
  fi
  if [[ -n "$expected" ]]; then
    actual="$(shasum -a 256 "$MODEL_PATH.part" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
      rm -f "$MODEL_PATH.part"
      die "checksum mismatch for $WHISPER_MODEL (expected $expected, got $actual)"
    fi
    ok "sha256 verified"
  else
    warn "could not fetch published checksum; skipping verification"
  fi
  mv "$MODEL_PATH.part" "$MODEL_PATH"
  ok "saved to $MODEL_PATH"
fi

step "Starting Ollama"
ollama_up() { curl -s --max-time 2 "$OLLAMA_URL/api/tags" >/dev/null 2>&1; }
if ollama_up; then
  ok "already running at $OLLAMA_URL"
else
  if "$BREW" list --formula ollama >/dev/null 2>&1; then
    "$BREW" services start ollama
  elif [[ -d /Applications/Ollama.app ]]; then
    open -a Ollama
  else
    nohup "$OLLAMA_BIN" serve >/dev/null 2>&1 &
  fi
  for _ in $(seq 1 30); do ollama_up && break; sleep 1; done
  ollama_up || die "Ollama did not start; try 'ollama serve' and re-run"
  ok "running at $OLLAMA_URL"
fi

step "Pulling cleanup model ($OLLAMA_MODEL)"
if "$OLLAMA_BIN" list | awk 'NR>1 {print $1}' | grep -qx -e "$OLLAMA_MODEL" -e "$OLLAMA_MODEL:latest"; then
  ok "already pulled"
else
  "$OLLAMA_BIN" pull "$OLLAMA_MODEL"
fi

step "Linking into Hammerspoon"
mkdir -p "$HS_DIR"
LINK="$HS_DIR/dictation"
if [[ -e "$LINK" && ! -L "$LINK" ]]; then
  die "$LINK exists and is not a symlink; move it aside and re-run"
fi
ln -sfn "$REPO_DIR/hammerspoon/dictation" "$LINK"
ok "$LINK -> $REPO_DIR/hammerspoon/dictation"

touch "$HS_INIT"
if grep -Eq '^[^-]*require[[:space:]]*\(?[[:space:]]*["'\'']dictation["'\'']' "$HS_INIT"; then
  ok "require(\"dictation\") already in $HS_INIT"
else
  printf '\n-- voice-draft\nrequire("dictation")\n' >> "$HS_INIT"
  ok "added require(\"dictation\") to $HS_INIT"
fi

if [[ "$OLLAMA_MODEL" != "qwen2.5:3b" ]]; then
  warn "remember to set cleanup.ollama.model = \"$OLLAMA_MODEL\" in ~/.config/voice-draft/overrides.lua"
fi

step "Starting Hammerspoon"
open -g -a Hammerspoon
HS_CLI="$(command -v hs || true)"
[[ -z "$HS_CLI" && -x /opt/homebrew/bin/hs ]] && HS_CLI=/opt/homebrew/bin/hs
if [[ -n "$HS_CLI" ]]; then
  "$HS_CLI" -c 'hs.reload()' >/dev/null 2>&1 || true
  sleep 3
fi

step "Running doctor"
# The hs CLI can block indefinitely (e.g. Hammerspoon not yet set up), and
# its -t flag does not bound that, so enforce our own timeout.
hs_doctor() {
  "$HS_CLI" -c 'dictation.doctor()' 2>/dev/null &
  local pid=$!
  ( sleep 15; kill "$pid" 2>/dev/null ) &
  local killer=$!
  local rc=0
  wait "$pid" || rc=$?
  kill "$killer" 2>/dev/null || true
  return $rc
}
if [[ -n "$HS_CLI" ]] && hs_doctor; then
  :
else
  # Shell-level checks; permissions can only be checked inside Hammerspoon.
  fail=0
  check() { if eval "$2" >/dev/null 2>&1; then echo "  [PASS] $1"; else echo "  [FAIL] $1"; fail=1; fi; }
  check "sox"                 "[[ -x /opt/homebrew/bin/sox || -x /usr/local/bin/sox ]]"
  check "whisper-cli"         "[[ -x /opt/homebrew/bin/whisper-cli || -x /usr/local/bin/whisper-cli ]]"
  check "whisper model"       "[[ -s '$MODEL_PATH' ]]"
  check "ollama reachable"    "ollama_up"
  check "ollama model pulled" "'$OLLAMA_BIN' list | awk 'NR>1 {print \$1}' | grep -qx -e '$OLLAMA_MODEL' -e '$OLLAMA_MODEL:latest'"
  check "hammerspoon link"    "[[ -L '$LINK' ]]"
  echo
  echo "Permissions (Accessibility, Microphone) can only be checked inside Hammerspoon:"
  echo "open the Hammerspoon console and run  dictation.doctor()"
  [[ $fail -eq 0 ]] || warn "some checks failed"
fi

cat <<EOF

Done. Next steps:
  1. Grant Hammerspoon Accessibility and Microphone access in
     System Settings > Privacy & Security.
  2. Press Ctrl+Option+D to start dictating, and again to stop.
EOF
