#!/usr/bin/env python3
"""live_delay.py name=log[+log...] ...

Picks the live delay (spec 1.9, decision 12) from QoE suite runs made with QOE_LIVE_DELAYS: a column per platform,
its rounds' logs joined with +. For each delay it prints how far behind real time the live start played, and the
jittery link's stalls (stalled seconds) summed over the rounds. The pick is the lowest delay under 15 s that, in
every column, stalled no more often than 15 s did, reopened no more often, and was playing at the end of every round.
With none, 15 s stays. The last line is `PICK <ms>`.
"""
import json, re, sys

REFERENCE = 15000


def load(path):
    rows = []
    for line in open(path, errors='replace'):
        m = re.search(r'QOE (\{.*\})', line)
        if m:
            try:
                rows.append(json.loads(m.group(1)))
            except ValueError:
                pass
    return rows


def by_delay(rows, scenario):
    out = {}
    for r in rows:
        name, _, ms = r.get('scenario', '').partition('@')
        if name == scenario and ms.isdigit():
            out.setdefault(int(ms), []).append(r)
    return out


def s(ms):
    return '—' if ms is None else f'{ms / 1000:.1f}'


def totals(runs):
    return (sum(r.get('stalls', 0) for r in runs), sum(r.get('stalledMs', 0) for r in runs),
            sum(1 for r in runs if r.get('endedOrError')), sum(1 for r in runs if not r.get('playingAtEnd')))


def fine(runs, ref):
    if not runs or len(runs) != len(ref):
        return False
    stalls, _, reopens, lost = totals(runs)
    ref_stalls, _, ref_reopens, _ = totals(ref)
    return lost == 0 and stalls <= ref_stalls and reopens <= ref_reopens


def main(argv):
    cols = [a.split('=', 1) for a in argv]
    data = {}
    for name, spec in cols:
        rows = [r for path in spec.split('+') for r in load(path)]
        data[name] = (by_delay(rows, 'live-hls-start'), by_delay(rows, 'live-hls-jitter'))
    delays = sorted({d for _, jitter in data.values() for d in jitter})
    print('| Delay (s) | ' + ' | '.join(f'{n}: behind real time at start (s) | {n}: jitter stalls (stalled s)'
                                       for n, _ in cols) + ' |')
    print('|---|' + '---|---|' * len(cols))
    for d in delays:
        cells = []
        for name, _ in cols:
            start, jitter = data[name]
            cells.append(' / '.join(s(r.get('behindRealTimeMs')) for r in start.get(d, [])) or 'not run')
            runs = jitter.get(d, [])
            stalls, ms, reopens, lost = totals(runs)
            notes = (f', {reopens} reopened' if reopens else '') + (f', {lost} lost' if lost else '')
            cells.append(f'{stalls} ({s(ms)}){notes}' if runs else 'not run')
        print(f'| {d / 1000:g} | ' + ' | '.join(cells) + ' |')
    if any(REFERENCE not in jitter for _, jitter in data.values()):
        print('No 15 s runs to compare with: put 15000 in QOE_LIVE_DELAYS.')
        sys.exit(1)
    ok = [d for d in delays if d < REFERENCE and all(fine(j.get(d, []), j[REFERENCE]) for _, j in data.values())]
    print(f'PICK {min(ok) if ok else REFERENCE}')


if __name__ == '__main__':
    main(sys.argv[1:])
