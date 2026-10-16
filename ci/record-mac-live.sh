#!/bin/bash
# Real hosted-Mac desktop, Carbon shortcut, screenshot OCR and local inference.
set -euo pipefail
cd "$(dirname "$0")/../dot-question-mac"
OUT="$PWD/dist/live-video"
mkdir -p "$OUT/probe" "$OUT/real-model"
APP="$PWD/dist/dot question.app/Contents/MacOS/DotQuestion"
HARNESS="$PWD/dist/mac-desktop-harness"
APP_PID=''; OLLAMA_PID=''
cleanup() {
  if [[ -n "$APP_PID" ]]; then kill "$APP_PID" 2>/dev/null || true; fi
  if [[ -n "$OLLAMA_PID" ]]; then kill "$OLLAMA_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 ../ci/mac-desktop-harness.swift -o "$HARNESS"
"$HARNESS" --preflight > "$OUT/preflight.json"
cat "$OUT/preflight.json"
run_capture() {
  local mode="$1" directory="$2"
  "$APP" --ci-live-test "$directory" > "$directory/app.log" 2>&1 & APP_PID=$!
  for i in {1..20}; do [[ -f "$directory/app-ready.json" ]] && break; sleep 1; done
  python3 - "$directory/app-ready.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['hotkeyStatus']==0, p
assert p['screenCaptureAllowed'] is True, 'BLOCKED: app screen capture permission absent; no settings changed'
assert p['windowVisible'] is False, p
PY
  "$HARNESS" "$mode" "$directory" > "$directory/harness.log" 2>&1
  kill "$APP_PID"; wait "$APP_PID" || true; APP_PID=''
}
# Verify real recording and global shortcut delivery BEFORE downloading a model.
run_capture --probe "$OUT/probe"
# Official vendor distribution only; CLI runs in job directory, no installer/GUI.
TOOLS="$RUNNER_TEMP/dot-question-ollama"
mkdir -p "$TOOLS"
curl --fail --location --max-time 180 https://ollama.com/download/Ollama-darwin.zip -o "$TOOLS/Ollama.zip"
ditto -x -k "$TOOLS/Ollama.zip" "$TOOLS"
OLLAMA="$TOOLS/Ollama.app/Contents/Resources/ollama"
test -x "$OLLAMA"
export OLLAMA_HOST=127.0.0.1:11434 OLLAMA_NO_CLOUD=1
export OLLAMA_MODELS="$TOOLS/models" OLLAMA_NUM_PARALLEL=1
"$OLLAMA" serve > "$OUT/ollama-server.log" 2>&1 & OLLAMA_PID=$!
for i in {1..30}; do curl --fail --silent http://127.0.0.1:11434/api/tags > "$OUT/model-tags-before.json" && break; sleep 1; done
"$OLLAMA" --version > "$OUT/ollama-version.txt"
"$OLLAMA" pull qwen2.5:1.5b > "$OUT/model-pull.log" 2>&1
curl --fail --silent http://127.0.0.1:11434/api/tags > "$OUT/model-tags.json"
# Warm model without an answer fixture; the actual question comes only through OCR.
curl --fail --silent --max-time 180 http://127.0.0.1:11434/api/generate -d '{"model":"qwen2.5:1.5b","prompt":"","stream":false,"keep_alive":"5m","options":{"num_ctx":16384}}' > "$OUT/model-warmup.json"
run_capture --record "$OUT/real-model"
