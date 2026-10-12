#!/usr/bin/env bash
# Installer for git clones. Same as 'bin/voice-draft setup'.
#   OLLAMA_MODEL=llama3.2:3b ./install.sh   pull a different cleanup model
#   SKIP_WHISPER_MODEL=1 ./install.sh       don't download the Whisper model
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/voice-draft" setup "$@"
