#!/usr/bin/env python3
"""Analyse the logs written by h43-rolling-update.sh: errors per load generator and per rollout phase."""
import os
import sys
from collections import Counter

w = sys.argv[1]


def read(name):
    p = os.path.join(w, name)
    return open(p).read().splitlines() if os.path.exists(p) else []


events = []  # (ms, label)
for l in read("events.log"):
    t, label = l.split(" ", 1)
    events.append((int(t), label))
t0 = events[0][0]


def phase(ms):
    """Name of the rollout phase a timestamp falls into."""
    name = "baseline"
    for t, label in events:
        if ms >= t:
            if label.startswith("start-"):
                name = "rollout-" + label[6:]
            elif label.startswith("done-"):
                name = "after-" + label[5:]
            elif label.startswith("settled-"):
                name = "settled"
    return name


def rel(ms):
    return f"{(ms - t0) / 1000:+.1f}s"


print("timeline (relative to the end of the baseline):")
for t, label in events:
    print(f"  {rel(t):>8}  {label}")

for name in ("manifest", "blob"):
    rows = []
    for l in read(name + ".log"):
        parts = l.split()
        rows.append((int(parts[0]), parts[1], float(parts[2]), parts[3]))
    total = Counter(phase(r[0]) for r in rows)
    bad = [r for r in rows if r[1] != "200"]
    badc = Counter(phase(r[0]) for r in bad)
    codes = Counter(r[1] + " " + r[3] for r in bad)
    slow = max((r[2] for r in rows), default=0)
    print(f"\n{name}: {len(rows)} requests, {len(bad)} not 200, slowest {slow:.2f}s")
    for ph in sorted(total):
        print(f"  {ph:<16} requests={total[ph]:<5} errors={badc.get(ph, 0)}")
    if codes:
        print("  error kinds:", dict(codes))
        for r in bad[:8]:
            print(f"    {rel(r[0]):>8} {phase(r[0]):<14} http={r[1]} {r[3]} t={r[2]:.2f}s")

pulls = []
for l in read("pull.log"):
    parts = l.split()
    pulls.append((int(parts[0]), int(parts[1]), parts[2], int(parts[3])))
fails = [p for p in pulls if p[2] != "rc=0"]
retried = [p for p in pulls if p[3] > 0]
tot = Counter(phase(p[0]) for p in pulls)
failc = Counter(phase(p[0]) for p in fails)
print(f"\ndocker pull: {len(pulls)} pulls, {len(fails)} failed, {len(retried)} needed client retries")
for ph in sorted(tot):
    print(f"  {ph:<16} pulls={tot[ph]:<4} failed={failc.get(ph, 0)}")
for f in read("pull-errors.log")[:5]:
    print("   ", f[:200])
