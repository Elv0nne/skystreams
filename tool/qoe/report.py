#!/usr/bin/env python3
"""report.py name=log[+log...] ... [--compare baselines.json]

Turns the QoE suite's output into one table, a column per platform. A log is a test run's output (lines holding
`QOE {json}`) or a .jsonl of the same objects; several joined with + make one column, later ones overriding earlier
ones scenario by scenario. A scenario the runner marked failed (`<name> [E]`) shows as FAILED.

With --compare, each column is also checked against the baselines saved for its name (macos, ios, android,
androidtv, windows, linux): a time more than 10 % and 200 ms worse, a count of stalls that rose, or memory more
than 10 % up is printed as a regression, and the script exits 1.

An outage row reads PASS, or **FAIL** with the first rule it broke (`outage_rule`): the picture moving at the end,
kept through the recovery, standing still no longer than the outage plus 4 s, coming back where it stopped, and the
reopen soon after the server answered. A row the suite couldn't run here reads "skipped" with why.
"""
import json, re, statistics, sys


def load(path):
    out = {}
    with open(path, errors='replace') as f:
        lines = f.readlines()
    for line in lines:
        m = re.search(r'QOE (\{.*\})', line)
        text = m.group(1) if m else (line.strip() if line.lstrip().startswith('{') else None)
        if text:
            try:
                d = json.loads(text)
            except ValueError:
                continue
            if 'scenario' in d:
                out[d['scenario']] = d
            continue
        m = re.search(r'\d+:\d+ \+\d+(?: -\d+)?: (\S+) \[E\]', line)
        if m and m.group(1) not in out:
            out[m.group(1)] = {'failed': True}
    return out


def load_all(spec):
    out = {}
    for path in spec.split('+'):
        out.update(load(path))
    return out


def s(ms):
    return '—' if ms is None else f'{ms / 1000:.1f}'


def seeks(r):
    vals = [x.get('resumeMs') for x in r.get('seeks', [])]
    got = [v for v in vals if v is not None]
    miss = len(vals) - len(got)
    text = f'{s(min(got))}–{s(max(got))}' if got else '—'
    return text + (f', {miss} never' if miss else '') + f"; {r.get('stalls', 0)} stalls"


def switches(r):
    return ', '.join(f"{s(x.get('switchedMs'))} / {s(x['rebufferMs'])}" for x in r['switches'])


def memory(r):
    grew = f" (+{r['maxRssMb'] - r['rssAtOpenMb']})" if 'rssAtOpenMb' in r else ''
    return f"{r['maxRssMb']}{grew}"


def torrent(r):
    """A real torrent's start (s), what its server start did to the buffer
    settings and what TorrServer read back, the write's own time, and the
    peers connected at the first frame."""
    t = r.get('torrent') or {}
    back = r.get('readBack') or {}
    cache = back.get('CacheSize')
    held = f"{cache // (1 << 20)} MB / {back.get('ReaderReadAHead', '—')} %" if isinstance(cache, int) else '—'
    write = f"; set {s(t['setMs'])} s" if t.get('setMs') is not None else ''
    return f"{s(r.get('ttffMs'))}; {t.get('settings', '—')} {held}{write}; {r.get('peersAtFirstFrame', '—')} peers"


# The spec's outage target: the reopen "within 2 s of the server answering again" (spec, Goals, Failures). While it
# waits, recovery checks every 2 s, and a reopen's first request reaches the server after the app's own part of an
# open (up to 0.45 s on Part 2's emulators): 2.5 s is that target with both counted.
REOPEN_WITHIN_MS = 2500

# How far from where the picture stopped a reopen may start: an HLS start lands on the first picture of its segment,
# up to a segment (6 s here) early, and a file's on a keyframe before it.
SPOT_MS = {'hls': 6000, 'file': 2000}

# The status lines over the picture, by the label the QoE log's waits carry (the app's en strings).
TEXTS = {'reconnecting': 'Reconnecting…', 'waitingForNetwork': 'Waiting for network…'}

# What an outage row expects besides the common rules:
#   timingMs=N or None   the reopen's limit after the server answered (REOPEN_WITHIN_MS by default); None: no target,
#                        as for a stall, whose server answers throughout and so never "answers again", or offline,
#                        where the device's network comes back, not the server
#   wait=LABEL           a wait with this label, and its line over the picture
#   check=KIND           a check answered with this class
#   failoverTo=N         exactly one failover, to source N, whose start-up view is expected
#   failoverAfterMs, failoverWithinMs   bounds on that failover, after the first check of the class above
#   busyGapMs=N          busy checks at least N ms apart: Retry-After honoured
EXPECT = {
    'stall20-hls': {'timingMs': None},
    'drop60-mp4': {'wait': 'reconnecting'},
    'drop60-hls': {'wait': 'reconnecting'},
    'outage120-hls': {'wait': 'reconnecting'},
    'offline-120': {'wait': 'waitingForNetwork', 'timingMs': None},
    # 403 fails over at once (spec 2), to the second server's copy.
    'gone403-2src': {'check': 'gone', 'failoverTo': 1, 'failoverWithinMs': 5000},
    # Retry-After: 4 spaces the checks; the reopen comes at the first check after the server is back, up to 4 s later.
    'busy503-ra': {'check': 'busy', 'busyGapMs': 3500, 'timingMs': 6500},
    # 30 s with no answer while the other host answers: this host is down, fail over (spec 2). 28 s allows for when
    # the policy starts counting against when the first check is logged.
    'hostdown-2src': {'check': 'network', 'failoverTo': 1, 'failoverAfterMs': 28000, 'failoverWithinMs': 40000},
    # A live reconnect may keep the 2 s spacing of the live branch.
    'live-drop20': {'timingMs': 4500},
}


def ended_film(r):
    """A film played to its end: whether the ended card stayed up, and every
    reopen, failover or error the QoE log had by then (none, for a clean end)."""
    after = r.get('afterEnd') or []
    return ('card' if r.get('endedCard') else 'NO CARD') + (f"; {', '.join(after)}" if after else '; nothing reopened')


def outage_rule(r):
    """The first rule an outage row breaks, or None when it keeps them all (spec 2 and 7.2)."""
    expect = EXPECT.get(r.get('scenario'), {})
    moving = r.get('pictureMovingAtEnd')
    if moving is None:
        return "the picture wasn't measured: no decoder counts"
    if r.get('gaveUp'):
        return f"gave up ({r['gaveUp']})"
    if not moving:
        return f"the picture isn't moving at the end ({r.get('finalState', '?')})"
    if not r.get('playingAtEnd'):
        return f"not playing at the end ({r.get('finalState', '?')})"
    failovers = r.get('failovers') or []
    to = expect.get('failoverTo')
    went = [f.get('to') for f in failovers]
    if to is None and went:
        return f'failed over to source {went[0]}'
    if to is not None and went != [to]:
        return f'expected one failover, to source {to}, not {went}'
    checks = r.get('checks') or []
    kind = expect.get('check')
    if kind and not any(c.get('kind') == kind for c in checks):
        return f'no check answered {kind}'
    waits = r.get('waits') or []
    label = expect.get('wait')
    if label and not any(w.get('label') == label for w in waits):
        return f'no wait labelled {label}'
    if to is None and r.get('startupViews', 0):
        return f"the start-up view was up for {s(r['startupViews'] * 250)} s"
    reopens = r.get('reopens') or []
    if any(not x.get('keptPicture') for x in reopens):
        return "a reopen didn't keep the picture"
    if reopens and not r.get('heldPictureSeen'):
        return 'no reopen held the picture on screen'
    seen = r.get('statusSeen') or []
    if label and label not in seen:
        return f"'{TEXTS[label]}' never showed over the picture"
    # A wait lasts a check at least (2 s). A reopen that needed none can come and go between two looks at the
    # screen (about 0.4 s apart), so its line isn't required.
    if to is None and waits and not seen:
        return "a wait with no 'Reconnecting…' or 'Waiting for network…' over the picture"
    frozen = r.get('pictureFrozenMs')
    if frozen is None or frozen > r.get('outageMs', 0) + 4000:
        return f"the picture stood still {s(frozen)} s, through a {s(r.get('outageMs'))} s outage"
    if (reopens or failovers) and r.get('media') != 'live':
        off = r.get('spotOffMs')
        if off is None:
            return 'the reopen has no start to judge'
        if abs(off) > SPOT_MS.get(r.get('media'), SPOT_MS['file']):
            return f'reopened {s(off)} s from where the picture stopped'
    within = expect.get('timingMs', REOPEN_WITHIN_MS)
    if within is not None and to is None and (reopens or waits):
        after = r.get('reopenAfterServerMs')
        if r.get('requestsRead') is False:
            return "the server's request log could not be read: no reopen timing"
        if after is None:
            return 'no request of the reopen reached the server after it answered'
        if after > within:
            return f'reopened {s(after)} s after the server answered, past {s(within)} s'
    if to is not None and kind:
        first = next(c.get('afterCutMs') for c in checks if c.get('kind') == kind)
        took = failovers[0].get('afterCutMs', 0) - first
        if took < expect.get('failoverAfterMs', took):
            return f"failed over {s(took)} s after the first {kind} check, before {s(expect['failoverAfterMs'])} s"
        if took > expect.get('failoverWithinMs', took):
            return f"failed over {s(took)} s after the first {kind} check, past {s(expect['failoverWithinMs'])} s"
    gap = expect.get('busyGapMs')
    if gap:
        busy = [c.get('afterCutMs') for c in checks if c.get('kind') == 'busy']
        gaps = [b - a for a, b in zip(busy, busy[1:])]
        if gaps and min(gaps) < gap:
            return f'busy checks only {s(min(gaps))} s apart, sooner than Retry-After asked'
    return None


def outage(r):
    """An outage row's cell: PASS with how long the picture stood still, and the reopen's time where the row judges
    it, or **FAIL** with the first rule broken."""
    broken = outage_rule(r)
    if broken is not None:
        return f'**FAIL**: {broken}'
    after = r.get('reopenAfterServerMs')
    timed = EXPECT.get(r.get('scenario'), {}).get('timingMs', REOPEN_WITHIN_MS) is not None
    reopened = f'; reopened {s(after)} s after the server' if after is not None and timed else ''
    return f"PASS (still {s(r['pictureFrozenMs'])} s{reopened})"


ROWS = [
    ('First open after launch (s)', 'warmup', lambda r: s(r.get('ttffMs'))),
    ('Start, MP4 at 8 Mbit/s (s)', 'start-mp4-8M', lambda r: s(r['ttffMs'])),
    ('Start, MKV at 8 Mbit/s (s)', 'start-mkv-8M', lambda r: s(r['ttffMs'])),
    ('Start, HLS at 8 Mbit/s (s)', 'start-hls-8M', lambda r: s(r['ttffMs'])),
    ('Start, MP4 at 30 Mbit/s (s)', 'start-mp4-30M', lambda r: s(r['ttffMs'])),
    ("Start's app part / libVLC part (ms)", 'start-mp4-30M', lambda r: f"{r.get('appMs', '—')} / {r.get('engineMs', '—')}"),
    ('Live TS start (s)', 'live-ts-start', lambda r: s(r['ttffMs'])),
    ('Live HLS, behind real time at first frame (s)', 'live-hls-start', lambda r: s(r.get('behindRealTimeMs'))),
    ('Resume at 3 min, MP4 at 8 Mbit/s (s)', 'resume-mp4-8M', lambda r: s(r['ttffMs'])),
    ('Resume at 3 min, HLS at 8 Mbit/s (s)', 'resume-hls-8M', lambda r: s(r['ttffMs'])),
    ('Seeks ±10/60 s, MP4 at 30 Mbit/s (s)', 'seeks-mp4-30M', seeks),
    ('Seeks ±10/60 s, MP4 at 8 Mbit/s (s)', 'seeks-mp4-8M', seeks),
    ('Seeks, HLS at 8 Mbit/s (s)', 'seeks-hls-8M', seeks),
    ('17-seek storm, MP4 at 30 Mbit/s: last resume / stalled (s)', 'storm-mp4-30M', lambda r: f"{s(r['finalResumeMs'])} / {s(r['stalled'])}"),
    ('Weak 3.5 Mbit/s HLS: stalls in 75 s / in 90 s (stalled s), height', 'weak-hls-3500',
     lambda r: f"{r['stalls']} / {r.get('stalls90', '—')} ({s(r['stalledMs'])}), {int(r.get('height') or 0)}p"),
    ('Collapse 30→3→30 Mbit/s HLS: stalls (s)', 'collapse-hls', lambda r: f"{r['stalls']} ({s(r['stalledMs'])})"),
    ('20 s drop, MP4', 'drop20-mp4', outage),
    ('20 s stall, HLS', 'stall20-hls', outage),
    ('20 s drop, HLS', 'drop20-hls', outage),
    ('60 s drop, MP4', 'drop60-mp4', outage),
    ('60 s drop, HLS', 'drop60-hls', outage),
    ('2-minute outage, HLS', 'outage120-hls', outage),
    ('Offline 2 minutes, HLS (Android phone)', 'offline-120', outage),
    ('403 on source A, HLS: fails over to B', 'gone403-2src', outage),
    ('503 with Retry-After: 4 until two busy checks, HLS', 'busy503-ra', outage),
    ('Host A down 2 minutes while B answers, HLS: fails over', 'hostdown-2src', outage),
    ('20 s drop, live HLS', 'live-drop20', outage),
    ('Audio switch, MKV: track on / rebuffer (s)', 'switch-audio-mkv', switches),
    ('Audio switch, HLS: track on / rebuffer (s)', 'switch-audio-hls', switches),
    ('Subtitle switch, MKV: track on / rebuffer (s)', 'switch-subs-mkv', switches),
    ('Memory after 60 s of MP4 at 30 Mbit/s (MB; growth)', 'memory-mp4-30M', memory),
    ('Memory after 60 s of the 4K-class file (MB; growth)', 'memory-4k', memory),
    ('Live HLS on a jittery link: stalls (stalled s); behind (s)', 'live-hls-jitter',
     lambda r: f"{r['stalls']} ({s(r['stalledMs'])}); {s(r.get('behindRealTimeMs'))}"),
    ('Live seek back 30 s in a 2-min window: landed off (s)', 'live-hls-seek', lambda r: s(r.get('landedOffMs'))),
    ('Live pause 15 s: behind live before / after (s)', 'live-hls-pause',
     lambda r: f"{s(r.get('behindBeforeMs'))} / {s(r.get('behindAfterMs'))}"),
    ('A film played to its end: the ended card; what followed', 'end-mp4', ended_film),
    ('Leaving during an HLS stall (s; longest UI pause)', 'leave-during-stall-hls',
     lambda r: s(r['leaveMs']) + (f"; {r['leaveBlockMs']} ms" if 'leaveBlockMs' in r else '')),
    ('Real torrent, Sintel, 1080p label: start (s); settings; write; peers', 'torrent-sintel', torrent),
    ('The same in a new session: no write', 'torrent-sintel-again', torrent),
    ('Sintel, 720p label', 'torrent-sintel-720p', torrent),
]


def cell(d, sc, f):
    r = d.get(sc)
    if r is None:
        return 'not run'
    if r.get('failed'):
        return 'FAILED'
    if r.get('skipped'):
        return f"skipped: {r['skipped']}"
    try:
        return f(r)
    except (KeyError, TypeError, ValueError):
        return '?'


def table(cols, data):
    print('| | ' + ' | '.join(n for n, _ in cols) + ' |')
    print('|---|' + '---|' * len(cols))
    for label, sc, f in ROWS:
        print(f'| {label} | ' + ' | '.join(cell(data[n], sc, f) for n, _ in cols) + ' |')


def compare(cols, data, baselines):
    worse = []
    for name, _ in cols:
        base = baselines.get(name, {})
        for sc, now in data[name].items():
            was = base.get(sc)
            if not was or now.get('failed'):
                continue
            for key in ('ttffMs', 'finalResumeMs', 'stalledMs', 'leaveMs'):
                if isinstance(now.get(key), int) and isinstance(was.get(key), int):
                    if now[key] > was[key] * 1.1 and now[key] - was[key] > 200:
                        worse.append(f'{name} {sc} {key}: {was[key]} -> {now[key]}')
            if isinstance(now.get('stalls'), int) and isinstance(was.get('stalls'), int) and now['stalls'] > was['stalls']:
                worse.append(f"{name} {sc} stalls: {was['stalls']} -> {now['stalls']}")
            if isinstance(now.get('maxRssMb'), int) and isinstance(was.get('maxRssMb'), int) and now['maxRssMb'] > was['maxRssMb'] * 1.1:
                worse.append(f"{name} {sc} maxRssMb: {was['maxRssMb']} -> {now['maxRssMb']}")
    for line in worse:
        print('REGRESSION ' + line)
    return worse


def main(argv):
    baselines = None
    if '--compare' in argv:
        i = argv.index('--compare')
        baselines = json.load(open(argv[i + 1]))
        argv = argv[:i] + argv[i + 2:]
    cols = [a.split('=', 1) for a in argv]
    data = {name: load_all(spec) for name, spec in cols}
    table(cols, data)
    if baselines is not None and compare(cols, data, baselines):
        sys.exit(1)


if __name__ == '__main__':
    main(sys.argv[1:])
