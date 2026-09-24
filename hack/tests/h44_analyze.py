#!/usr/bin/env python3
"""Analyse the logs written by h44-node-loss.sh: client errors per phase and error windows."""
import os
import sys
from collections import Counter

w = sys.argv[1]


def read(name):
    p = os.path.join(w, name)
    return open(p).read().splitlines() if os.path.exists(p) else []


events = []
for l in read("events.log"):
    t, label = l.split(" ", 1)
    events.append((int(t), label))
down = next(t for t, lab in events if lab == "node-down")


def phase(ms):
    name = "baseline"
    for t, label in events:
        if ms >= t:
            name = label
    return name


def rel(ms):
    return f"{(ms - down) / 1000:+7.1f}s"


ORDER = [lab for _, lab in events]
print("timeline (relative to node-down):")
for t, label in events:
    print(f"  {rel(t)}  {label}")


def windows(stamps, gap=3000):
    """Group error timestamps into windows separated by more than `gap` ms."""
    out = []
    for s in sorted(stamps):
        if out and s - out[-1][1] <= gap:
            out[-1][1] = s
            out[-1][2] += 1
        else:
            out.append([s, s, 1])
    return out


for name in ("manifest", "blob"):
    rows = []
    for l in read(name + ".log"):
        p = l.split()
        rows.append((int(p[0]), p[1], float(p[2]), p[3]))
    bad = [r for r in rows if r[1] != "200"]
    slow = sorted(rows, key=lambda r: -r[2])[:1]
    print(f"\n{name}: {len(rows)} requests, {len(bad)} failed, slowest {slow[0][2]:.1f}s at {rel(slow[0][0])}" if rows else f"\n{name}: no data")
    tot = Counter(phase(r[0]) for r in rows)
    badc = Counter(phase(r[0]) for r in bad)
    slowc = Counter(phase(r[0]) for r in rows if r[2] > 2.0)
    maxc = {}
    for r in rows:
        maxc[phase(r[0])] = max(maxc.get(phase(r[0]), 0), r[2])
    for ph in ["baseline"] + ORDER:
        if tot.get(ph):
            print(f"  {ph:<18} requests={tot[ph]:<5} errors={badc.get(ph, 0):<3} slower_than_2s={slowc.get(ph, 0):<3} max={maxc[ph]:.1f}s")
    if bad:
        print("  error kinds:", dict(Counter(f"http {r[1]} {r[3]}" for r in bad)))
        for a, b, n in windows([r[0] for r in bad]):
            print(f"  error window {rel(a)} .. {rel(b)}  ({(b - a) / 1000:.1f}s, {n} errors)")

pulls = []
for l in read("pull.log"):
    p = l.split()
    pulls.append((int(p[0]), int(p[1]), p[2]))
fails = [p for p in pulls if p[2] != "rc=0"]
durs = sorted((p[1] - p[0]) / 1000 for p in pulls)
print(f"\ndocker pull: {len(pulls)} pulls, {len(fails)} failed, median {durs[len(durs) // 2]:.1f}s, slowest {durs[-1]:.1f}s")
tot = Counter(phase(p[0]) for p in pulls)
failc = Counter(phase(p[0]) for p in fails)
slowc = Counter(phase(p[0]) for p in pulls if (p[1] - p[0]) / 1000 > 5.0)
maxc = {}
for p in pulls:
    maxc[phase(p[0])] = max(maxc.get(phase(p[0]), 0), (p[1] - p[0]) / 1000)
for ph in ["baseline"] + ORDER:
    if tot.get(ph):
        print(f"  {ph:<18} pulls={tot[ph]:<4} failed={failc.get(ph, 0):<3} slower_than_5s={slowc.get(ph, 0):<3} max={maxc[ph]:.1f}s")
if fails:
    for a, b, n in windows([p[0] for p in fails], 15000):
        print(f"  failure window {rel(a)} .. {rel(b)}  ({n} failed pulls)")
    for f in read("pull-errors.log")[:4]:
        print("   ", f[:180])
