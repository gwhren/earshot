#!/usr/bin/env bash
# End-to-end check of the real HTTP client: runs earshot-cli against
# Tools/fake_mlx_studio.py, which mimics MLX Studio's gateway and vMLX's quirks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-18080}"
WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
cd "$ROOT"

echo "==> Preparing the fake MLX Studio"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet --disable-pip-version-check fastapi uvicorn python-multipart
"$WORK/venv/bin/python" Tools/make_test_audio.py "$WORK/speech.wav" >/dev/null
"$WORK/venv/bin/python" Tools/fake_mlx_studio.py --port "$PORT" --gateway --delay 0 >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.2
done

echo "==> Building earshot-cli"
swift build --product earshot-cli
CLI="$(swift build --show-bin-path)/earshot-cli"

echo "==> TranslateGemma via raw completions, through the gateway's routing fallback"
"$CLI" --server "http://127.0.0.1:$PORT" --to fr "$WORK/speech.wav" | tee "$WORK/gemma.txt"
grep -q "→ \[French\]" "$WORK/gemma.txt"

echo "==> Two target languages"
"$CLI" --server "http://127.0.0.1:$PORT" --to en,uk "$WORK/speech.wav" | tee "$WORK/two.txt"
grep -q "EN → \[English\]" "$WORK/two.txt"
grep -q "UK → \[Ukrainian\]" "$WORK/two.txt"

echo "==> Chat model with thinking turned off"
"$CLI" --server "http://127.0.0.1:$PORT" --model Qwen3-8B-4bit --from es --to de "$WORK/speech.wav" | tee "$WORK/chat.txt"
grep -q "→ (German)" "$WORK/chat.txt"
if grep -q "<think>" "$WORK/chat.txt"; then
  echo "reasoning leaked into the output" >&2
  exit 1
fi

echo "==> Unreachable server is reported"
if "$CLI" --server "http://127.0.0.1:1" --to fr "$WORK/speech.wav" 2>"$WORK/err.txt"; then
  echo "expected a failure" >&2
  exit 1
fi
grep -q "Can't reach" "$WORK/err.txt"

echo "End-to-end OK"
