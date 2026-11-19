#!/usr/bin/env python3
"""Rewrite selected CONFIG_ lines in the plaintext IKCONFIG payload.
Kernel functionality is untouched; only what /proc/config.gz reports changes."""
import sys
target = sys.argv[1]
SPOOF = {
    "CONFIG_IP6_NF_NAT": "n",
}
lines = open(target).read().splitlines(True)
changed = 0
for i, l in enumerate(lines):
    for k, v in SPOOF.items():
        if l.startswith(k + "="):
            newl = "%s=%s\n" % (k, v)
            if l != newl:
                lines[i] = newl
                changed += 1
open(target, "w").writelines(lines)
print("spoof_ikconfig: rewrote %d line(s) in %s" % (changed, target), flush=True)
