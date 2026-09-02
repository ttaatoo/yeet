#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-"${ROOT}/dist/Yeet.app"}"
BINARY="${APP}/Contents/MacOS/yeet"

if [[ ! -x "$BINARY" ]]; then
  echo "error: missing Yeet executable at ${BINARY}" >&2
  echo "run bash scripts/package.sh first" >&2
  exit 1
fi

BENCH_DIR="$(mktemp -d -t yeet-resource-bench)"
REPORT="${BENCH_DIR}/report.json"
LOG="${BENCH_DIR}/process.log"
SAMPLE="${BENCH_DIR}/timeout.sample.txt"

"$BINARY" --resource-bench --bench-out="$REPORT" >"$LOG" 2>&1 &
BENCH_PID=$!

for _ in {1..60}; do
  if ! kill -0 "$BENCH_PID" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

if kill -0 "$BENCH_PID" 2>/dev/null; then
  sample "$BENCH_PID" 3 -file "$SAMPLE" >/dev/null 2>&1 || true
  kill -TERM "$BENCH_PID" 2>/dev/null || true
  sleep 1
  kill -KILL "$BENCH_PID" 2>/dev/null || true
  echo "error: resource benchmark exceeded 30 seconds" >&2
  echo "log: ${LOG}" >&2
  echo "sample: ${SAMPLE}" >&2
  exit 1
fi

set +e
wait "$BENCH_PID"
BENCH_STATUS=$?
set -e

if [[ "$BENCH_STATUS" -ne 0 ]]; then
  echo "error: resource benchmark exited ${BENCH_STATUS}" >&2
  sed -n '1,160p' "$LOG" >&2
  if [[ -f "$REPORT" ]]; then
    /usr/bin/plutil -p "$REPORT" >&2
  fi
  exit "$BENCH_STATUS"
fi

if [[ ! -f "$REPORT" ]]; then
  echo "error: resource benchmark produced no report" >&2
  sed -n '1,160p' "$LOG" >&2
  exit 1
fi

STATUS="$(/usr/bin/plutil -extract status raw -o - "$REPORT")"
if [[ "$STATUS" != "passed" ]]; then
  echo "error: resource benchmark reported ${STATUS}" >&2
  /usr/bin/plutil -p "$REPORT" >&2
  exit 1
fi

echo "Resource benchmark passed:"
/usr/bin/plutil -p "$REPORT"
echo "Report: ${REPORT}"
