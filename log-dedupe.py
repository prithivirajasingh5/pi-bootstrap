#!/usr/bin/env python3
"""log-dedupe: pass log lines through, dropping exact repeats seen in the last REPEAT_SECONDS.

`claude remote-control` redraws its status panel (6 lines) every few seconds, even without a
terminal, which put ~20,000 identical lines a day into the journal and pushed real messages out.
claude-remote.service pipes its output through this: changes, errors and new session links still
appear at once; an unchanged panel is logged again at most once per REPEAT_SECONDS.
"""
import re
import sys
import time

REPEAT_SECONDS = 3600
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")

last_seen = {}
for raw in sys.stdin:
    line = ANSI.sub("", raw).rstrip()
    if not line.strip():
        continue
    now = time.monotonic()
    if now - last_seen.get(line, -REPEAT_SECONDS) >= REPEAT_SECONDS:
        print(line, flush=True)
        last_seen[line] = now
        if len(last_seen) > 5000:   # bounded memory: forget the oldest half
            for key, _ in sorted(last_seen.items(), key=lambda kv: kv[1])[:2500]:
                del last_seen[key]
    # A dropped repeat keeps its original time, so a steady panel is re-logged once per window.
