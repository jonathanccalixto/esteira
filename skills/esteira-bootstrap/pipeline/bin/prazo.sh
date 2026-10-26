#!/usr/bin/env bash
# Run a command with a time limit, wherever we are.
#   prazo.sh <seconds> <command...>      e.g. prazo.sh 1800 npm test
# Linux: exactly coreutils `timeout <seconds> <command...>` (exec'd, nothing in
# between). macOS has no `timeout`: Homebrew coreutils' `gtimeout` when it is
# there, otherwise a small Python stand-in with the same contract -- TERM to the
# command's process group when the time runs out, exit 124 in that case, the
# command's own exit code otherwise.
set -euo pipefail
secs=${1:?usage: prazo.sh <seconds> <command...>}; shift
if command -v timeout >/dev/null; then exec timeout "$secs" "$@"; fi
if command -v gtimeout >/dev/null; then exec gtimeout "$secs" "$@"; fi
exec python3 -c '
import os, signal, subprocess, sys
secs, cmd = float(sys.argv[1]), sys.argv[2:]
p = subprocess.Popen(cmd, start_new_session=True)
def stop(sig, _frame):
    try: os.killpg(p.pid, sig)
    except ProcessLookupError: pass
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(s, stop)
try:
    rc = p.wait(timeout=secs)
    sys.exit(128 - rc if rc < 0 else rc)   # killed by a signal: 128+N, as the shell reports it
except subprocess.TimeoutExpired:
    stop(signal.SIGTERM, None)
    try:
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        stop(signal.SIGKILL, None); p.wait()
    sys.exit(124)
' "$secs" "$@"
