#!/usr/bin/env python3
"""Analyse the logs of h47-role-failure.sh: per-generator errors and outage windows per phase, plus the
integrity of acknowledged writes (PostgreSQL ids and the Redis counter).
usage: h47_analyze.py <workdir> <final redis counter>"""
import os
import re
import sys
from calendar import timegm
from collections import Counter
from datetime import datetime

w = sys.argv[1]
redis_final = sys.argv[2].strip() if len(sys.argv) > 2 else ""


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


ORDER = ["baseline"] + [lab for _, lab in events]


def ts_ms(s):
    """RFC3339 (kubectl logs --timestamps) -> epoch ms"""
    m = re.match(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?Z", s)
    y, mo, d, h, mi, se, frac = m.groups()
    ms = int((frac or "0").ljust(9, "0")[:3])
    return timegm((int(y), int(mo), int(d), int(h), int(mi), int(se), 0, 0, 0)) * 1000 + ms


def windows(stamps, gap):
    out = []
    for s in sorted(stamps):
        if out and s - out[-1][1] <= gap:
            out[-1][1] = s
            out[-1][2] += 1
        else:
            out.append([s, s, 1])
    return out


def report(name, rows, gap=4000):
    """rows: (start_ms, ok, duration_s). Prints totals per phase, error windows and the longest gap without a success."""
    if not rows:
        print(f"\n{name}: no data")
        return
    tot = Counter(phase(r[0]) for r in rows)
    bad = [r for r in rows if not r[1]]
    badc = Counter(phase(r[0]) for r in bad)
    print(f"\n{name}: {len(rows)} operations, {len(bad)} failed, slowest {max(r[2] for r in rows):.1f}s")
    for ph in ORDER:
        if tot.get(ph):
            print(f"  {ph:<18} ops={tot[ph]:<5} errors={badc.get(ph, 0)}")
    for a, b, n in windows([r[0] for r in bad], gap):
        print(f"  error window {rel(a)} .. {rel(b)}  ({(b - a) / 1000:.1f}s, {n} errors)")
    oks = sorted(r[0] for r in rows if r[1])
    if len(oks) > 1:
        g = max(((oks[i + 1] - oks[i]), oks[i]) for i in range(len(oks) - 1))
        print(f"  longest time without a success: {g[0] / 1000:.1f}s (starting {rel(g[1])})")


print("timeline (relative to node-down):")
for t, label in events:
    print(f"  {rel(t)}  {label}")

for name in ("manifest", "blob"):
    rows = []
    for l in read(name + ".log"):
        p = l.split()
        rows.append((int(p[0]), p[1] == "200" and p[3] == "rc=0", float(p[2])))
    report(name + " (curl through the Infra LB)", rows)

for name, label in (("pull", "docker pull"), ("push", "docker push")):
    rows = []
    for l in read(name + ".log"):
        p = l.split()
        rows.append((int(p[0]), p[2] == "rc=0", (int(p[1]) - int(p[0])) / 1000))
    report(label, rows, 15000)

# ---- writers: pod logs with --timestamps, each line "<ts> rc=<n> <output>"
pg_acked, pg_rows = set(), []
for l in read("pgw.log"):
    m = re.match(r"(\S+Z)\s+rc=(\d+)\s*(.*)", l)
    if not m:
        continue
    ms, rc, out = ts_ms(m.group(1)), int(m.group(2)), m.group(3).strip()
    ok = rc == 0 and bool(re.fullmatch(r"\d+", out.split("\n")[0].split()[0] if out else ""))
    if ok:
        pg_acked.add(int(out.split()[0]))
    pg_rows.append((ms, ok, 0.0))
report("PostgreSQL writer (INSERT through harbor-lb:5432)", pg_rows, 3000)

present = set()
for l in read("pg_ids.txt"):
    if l.strip().isdigit():
        present.add(int(l.strip()))
lost = sorted(pg_acked - present)
print(f"  acknowledged inserts: {len(pg_acked)}, rows present: {len(present)}, "
      f"LOST acknowledged: {len(lost)}" + (f"  ids {lost[:10]}{'...' if len(lost) > 10 else ''}" if lost else ""))

rd_rows, last_acked, prev_reply, regress = [], 0, None, []
for l in read("redisw.log"):
    m = re.match(r"(\S+Z)\s+rc=(\d+)\s*(.*)", l)
    if not m:
        continue
    ms, rc, out = ts_ms(m.group(1)), int(m.group(2)), m.group(3).strip()
    ok = rc == 0 and out.isdigit()
    if ok:
        v = int(out)
        # INCR replies must grow by one; a reply <= the previous one means the write went to a stale master
        # and will be (or was) thrown away when that master is demoted
        if prev_reply is not None and v <= prev_reply:
            regress.append((ms, prev_reply, v))
        prev_reply = v
        last_acked = max(last_acked, v)
    rd_rows.append((ms, ok, 0.0))
report("Redis writer (INCR through harbor-lb:6379)", rd_rows, 3000)
print(f"  acknowledged INCR replies that went BACKWARDS (writes to a stale master, lost): {len(regress)}"
      + (f"  first at {rel(regress[0][0])}: {regress[0][1]} -> {regress[0][2]}" if regress else ""))
if redis_final.isdigit():
    lost_r = last_acked - int(redis_final)
    print(f"  last acknowledged counter: {last_acked}, final value in Redis: {redis_final}, "
          f"LOST acknowledged increments: {max(lost_r, 0)}" + ("  (value went back)" if lost_r > 0 else ""))
else:
    print(f"  final Redis value unavailable ({redis_final!r})")
