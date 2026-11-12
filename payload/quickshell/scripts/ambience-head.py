#!/usr/bin/env python3
# usage: ambience-head.py <head-file> <byte-limit>
#
# Pass stdin through to stdout while copying the first <byte-limit> bytes to
# <head-file>. The head is a byte prefix of the same download, so a later
# download of the same format can be joined to it by skipping the same number
# of leading bytes. Playback never has to wait for the copy.

import signal
import sys

signal.signal(signal.SIGPIPE, signal.SIG_DFL)

head_path = sys.argv[1]
limit = int(sys.argv[2])
remaining = limit
head = None

try:
    head = open(head_path, "wb")
except OSError:
    head = None

source = sys.stdin.buffer
target = sys.stdout.buffer

try:
    while True:
        chunk = source.read(65536)
        if not chunk:
            break
        target.write(chunk)
        target.flush()
        if head is not None and remaining > 0:
            piece = chunk[:remaining]
            head.write(piece)
            head.flush()
            remaining -= len(piece)
            if remaining <= 0:
                head.close()
                head = None
except (BrokenPipeError, OSError):
    pass
finally:
    if head is not None:
        head.close()
