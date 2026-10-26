#!/usr/bin/env python3
"""Stand-in for util-linux `flock` on systems that don't ship it (macOS).

  flock.py [-w seconds] <fd>

Same contract as `flock [-w seconds] <fd>` used by lock.sh and evidence.sh:
the shell opens the lock file on <fd> (`exec 9>file`) and this process takes an
exclusive flock() on that inherited descriptor. A flock() lock belongs to the
open file description, not to the process, so it stays held by the shell's fd
after this helper exits -- exactly how the util-linux binary works. Exit 0 when
locked, 1 when the wait ran out (the same codes as util-linux).

Only used when `flock` is not on the PATH: on Linux the real binary runs.
"""
import fcntl
import sys
import time

args = sys.argv[1:]
wait = None
if args[:1] == ["-w"]:
    wait = float(args[1])
    args = args[2:]
if len(args) != 1 or not args[0].isdigit():
    sys.exit("usage: flock.py [-w seconds] <fd>")
fd = int(args[0])

if wait is None:
    fcntl.flock(fd, fcntl.LOCK_EX)
    sys.exit(0)
deadline = time.monotonic() + wait
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(0)
    except BlockingIOError:
        if time.monotonic() >= deadline:
            sys.exit(1)
        time.sleep(0.5)
