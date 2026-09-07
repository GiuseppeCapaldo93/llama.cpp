#!/usr/bin/env python3
"""Summarise ab_toggle / cpu_per_token JSONL results: per-arm medians, per-round pairwise
deltas against the first (alphabetical) arm, and win counts. Usage:
    py summarize_ab.py <file-or-dir> [...]
"""
import glob
import json
import os
import statistics
import sys


def load(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def summarize(path):
    rows = load(path)
    if not rows:
        return
    arms = sorted({r["arm"] for r in rows})
    base = arms[0]
    metrics = [m for m in ("tg_ts", "pp_ts", "cpu_ms_per_tok", "cores_busy") if any(r.get(m) for r in rows)]
    print(f"\n== {os.path.basename(path)}  model={rows[0].get('model')}  env={rows[0].get('env')}")
    print(f"   arms: {', '.join(a + '=' + str(rows[0] if False else next(r['value'] for r in rows if r['arm']==a)) for a in arms)}")
    by_round = {}
    for r in rows:
        by_round.setdefault(r["round"], {})[r["arm"]] = r
    for m in metrics:
        print(f"   [{m}]")
        for a in arms:
            vals = [r[m] for r in rows if r["arm"] == a and r.get(m) is not None]
            if not vals:
                continue
            med = statistics.median(vals)
            line = f"     {a:<12} median {med:8.2f}   rounds " + " ".join(f"{v:.2f}" for v in vals)
            if a != base:
                deltas = []
                wins = 0
                for rnd, d in sorted(by_round.items()):
                    if a in d and base in d and d[a].get(m) and d[base].get(m):
                        dl = 100.0 * (d[a][m] / d[base][m] - 1.0)
                        deltas.append(dl)
                        wins += dl > 0
                if deltas:
                    line += f"   | vs {base}: pairwise " + " ".join(f"{x:+.1f}%" for x in deltas)
                    line += f"  median {statistics.median(deltas):+.1f}%  wins {wins}/{len(deltas)}"
            print(line)


def main():
    paths = []
    for arg in sys.argv[1:]:
        if os.path.isdir(arg):
            paths += sorted(glob.glob(os.path.join(arg, "*.jsonl")))
        else:
            paths.append(arg)
    for p in paths:
        try:
            summarize(p)
        except Exception as e:  # keep going over the rest
            print(f"\n== {os.path.basename(p)}: error {e}")


if __name__ == "__main__":
    main()
