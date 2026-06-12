#!/bin/bash
# End-to-end check: real tarmacd + Swift tarmac-smoke client + tarmac CLI,
# all on a fresh isolated socket. Safe to re-run; never touches the default
# socket in ~/Library/Application Support.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARMACD="$ROOT/core/target/debug/tarmacd"
TARMAC_CLI="$ROOT/core/target/debug/tarmac"
SMOKE="$ROOT/app/.build/debug/tarmac-smoke"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tarmac-e2e.XXXXXX")"
export TARMAC_SOCKET="$WORK/tarmacd.sock"
# M1 daemons persist dock state; without this the e2e daemon would read and
# write the user's real state.json.
export TARMAC_STATE="$WORK/state.json"
DAEMON_LOG="$WORK/tarmacd.log"
DAEMON_PID=""

fail() {
  echo "FAIL: $*" >&2
  if [ -s "$DAEMON_LOG" ]; then
    echo "--- tarmacd log ---" >&2
    cat "$DAEMON_LOG" >&2
  fi
  echo "RESULT: FAIL"
  exit 1
}

cleanup() {
  if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null
    for _ in $(seq 1 20); do
      kill -0 "$DAEMON_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -9 "$DAEMON_PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

for bin in "$TARMACD" "$TARMAC_CLI" "$SMOKE"; do
  [ -x "$bin" ] || fail "missing binary $bin (build with: make core app)"
done

echo "==> socket: $TARMAC_SOCKET"

"$TARMACD" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

echo "==> waiting for daemon socket"
for _ in $(seq 1 100); do
  [ -S "$TARMAC_SOCKET" ] && break
  kill -0 "$DAEMON_PID" 2>/dev/null || fail "tarmacd exited before binding"
  sleep 0.1
done
[ -S "$TARMAC_SOCKET" ] || fail "socket did not appear within 10 s"
echo "    daemon up (pid $DAEMON_PID)"

echo "==> running tarmac-smoke"
SMOKE_OUT="$("$SMOKE" 2>&1)"
SMOKE_RC=$?
echo "$SMOKE_OUT" | sed 's/^/    /'
[ $SMOKE_RC -eq 0 ] || fail "tarmac-smoke exited $SMOKE_RC"
echo "$SMOKE_OUT" | grep -q "RESULT: PASS" || fail "tarmac-smoke did not print RESULT: PASS"

echo "==> running tarmac open on a temp markdown file"
DOC="$WORK/e2e-doc.md"
printf '# e2e\n\nhello from e2e.sh\n' > "$DOC"
CLI_OUT="$("$TARMAC_CLI" open "$DOC" 2>&1)"
CLI_RC=$?
echo "$CLI_OUT" | sed 's/^/    /'
[ $CLI_RC -eq 0 ] || fail "tarmac open exited $CLI_RC"

echo "==> waiting for state.json to record the doc"
for _ in $(seq 1 40); do
  grep -qs "e2e-doc.md" "$TARMAC_STATE" && break
  sleep 0.1
done
grep -qs "e2e-doc.md" "$TARMAC_STATE" || fail "state.json did not record the opened doc within 4 s"

echo "==> stopping daemon"
kill "$DAEMON_PID" 2>/dev/null
for _ in $(seq 1 20); do
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$DAEMON_PID" 2>/dev/null && fail "tarmacd did not exit after SIGTERM"
[ -S "$TARMAC_SOCKET" ] && fail "tarmacd left its socket behind after SIGTERM"
DAEMON_PID=""

echo "RESULT: PASS"
exit 0
