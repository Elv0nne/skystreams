#!/usr/bin/env python3
"""server.py ROOT PORT [options]: the QoE suite's scenario server (the research harness's streamserver.py) with a control endpoint and a live TS channel for tests.

  streamserver.py ROOT PORT [--bind 127.0.0.1] [--rate KBPS] [--schedule T:KBPS,...] [--rtt MS]
                  [--stall T:DUR,...] [--drop T:DUR,...] [--idle-close S] [--log FILE]

Times in --schedule/--stall/--drop are seconds after the first request. One token bucket is shared by every
connection (one link). A stall sends nothing but keeps connections open; a drop closes them and refuses
new ones. Log lines (epoch ms): R request, P progress (file offset reached, every 250 ms), D done, X aborted.

/_control/status?code=C&secs=S[&retryAfter=R] answers every request with status C for S seconds, with Retry-After
when given. /_control/offline?secs=S takes the run's Android device (QOE_ADB_SERIAL, which run.sh sets for a phone
emulator) off its network through adb for S seconds, starting a second after it answers.
"""
import argparse, collections, functools, http.server, json, os, re, shutil, signal, socket, subprocess, sys, threading, time
from urllib.parse import urlsplit, parse_qs

class Link:
    def __init__(self, a):
        self.lock = threading.Lock()
        self.first = None
        self.tokens = 0.0
        self.last = time.monotonic()
        self.schedule = [(0.0, a.rate)] + [tuple(map(float, p.split(':'))) for p in filter(None, a.schedule.split(','))]
        self.stalls = [tuple(map(float, p.split(':'))) for p in filter(None, a.stall.split(','))]
        self.drops = [tuple(map(float, p.split(':'))) for p in filter(None, a.drop.split(','))]
        # /_control/status windows: (start, secs, code, Retry-After seconds or 0).
        self.statuses = []
        self.rtt = a.rtt / 1000.0
        self.idle_close = a.idle_close or None
        self.a = a; self.active = 0; self.rng = __import__('random').Random(7); self.etag_n = 0
        self.log_lock = threading.Lock()
        self.logf = open(a.log, 'a', buffering=1) if a.log else None
        self.ids = 0
        # The last requests, for the suite: /_control/requests answers from here.
        self.recent = collections.deque(maxlen=2000)
        # The live feed /_control/live started, if one is running.
        self.live = None

    def since_first(self):
        with self.lock:
            if self.first is None:
                self.first = time.monotonic()
            return time.monotonic() - self.first

    def rate_bps(self, t):
        kbps = 0.0
        for start, k in self.schedule:
            if t >= start:
                kbps = k
        return kbps * 1000 / 8

    def in_window(self, windows, t):
        for start, dur in windows:
            if start <= t < start + dur:
                return start + dur - t
        return 0.0

    def status_now(self, t):
        """The status every request gets at t, with its Retry-After, from the latest open window; (None, 0) for none."""
        for start, dur, code, retry_after in reversed(self.statuses):
            if start <= t < start + dur:
                return code, retry_after
        return None, 0.0

    def acquire(self, n):
        while True:
            t = self.since_first()
            wait = self.in_window(self.stalls, t)
            if wait:
                time.sleep(min(wait, 0.25))
                continue
            if self.in_window(self.drops, t):
                raise ConnectionAbortedError('link dropped')
            rate = self.rate_bps(t)
            if rate <= 0:
                return
            with self.lock:
                now = time.monotonic()
                self.tokens = min(max(rate * 0.05, n), self.tokens + rate * (now - self.last))
                self.last = now
                if self.tokens >= n:
                    self.tokens -= n
                    return
                need = (n - self.tokens) / rate
            time.sleep(min(need, 0.05))

    def log(self, *fields):
        with self.log_lock:
            if fields and fields[0] == 'R':
                # The method and Range too: the suite tells a recovery check's first kilobyte (bytes=0-1023) and its
                # HEAD from the player's own requests.
                self.recent.append({'t': float(fields[1]), 'id': fields[2], 'method': fields[3], 'path': str(fields[4]),
                                    'status': fields[6] if len(fields) > 6 else None,
                                    'range': fields[5] if str(fields[5]).startswith('bytes=') else ''})
            if self.logf:
                self.logf.write(','.join(str(f) for f in fields) + '\n')

    def next_id(self):
        with self.lock:
            self.ids += 1
            return self.ids

def ms():
    return '%.3f' % (time.time() * 1000)

# How long after its answer /_control/offline takes the device off the network: the answer has to reach it first.
OFFLINE_DELAY_MS = 1000


def adb(serial, *args):
    """One `adb shell` command on the run's device; what it printed, or '' when it failed."""
    try:
        out = subprocess.run([os.environ.get('QOE_ADB', 'adb'), '-s', serial, 'shell', *args],
                             capture_output=True, text=True, timeout=20)
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ''


def offline(link, serial, secs):
    """Turns the device's mobile data and Wi-Fi off for secs, then puts back the ones it had on."""
    time.sleep(OFFLINE_DELAY_MS / 1000)
    wifi = adb(serial, 'settings', 'get', 'global', 'wifi_on') == '1'
    data = adb(serial, 'settings', 'get', 'global', 'mobile_data') == '1'
    adb(serial, 'svc', 'data', 'disable')
    adb(serial, 'svc', 'wifi', 'disable')
    link.log('C', ms(), 'offline-on', json.dumps({'wifi': wifi, 'data': data}))
    time.sleep(secs)
    if data:
        adb(serial, 'svc', 'data', 'enable')
    if wifi:
        adb(serial, 'svc', 'wifi', 'enable')
    link.log('C', ms(), 'offline-off', '{}')

TYPES = {'.m3u8': 'application/vnd.apple.mpegurl', '.ts': 'video/mp2t', '.vtt': 'text/vtt', '.mp4': 'video/mp4',
         '.mkv': 'video/x-matroska', '.srt': 'application/x-subrip', '.aac': 'audio/aac', '.m4s': 'video/iso.segment'}

@functools.lru_cache(maxsize=None)
def h264_encoder():
    """The Mac's hardware encoder when ffmpeg has it, else x264 tuned for latency: either keeps up in real time."""
    out = subprocess.run(['ffmpeg', '-hide_banner', '-encoders'], capture_output=True, text=True).stdout
    if 'h264_videotoolbox' in out:
        return ['-c:v', 'h264_videotoolbox', '-realtime', '1']
    return ['-c:v', 'libx264', '-preset', 'veryfast', '-tune', 'zerolatency']


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    link = None

    def log_message(self, *a):
        pass

    def setup(self):
        super().setup()
        try:
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 32768)
        except OSError:
            pass
        if self.link.idle_close:
            # A CDN closes a connection whose client stops reading (nginx send_timeout).
            self.connection.settimeout(self.link.idle_close)

    def do_HEAD(self):
        self.serve(head=True)

    def do_GET(self):
        self.serve(head=False)

    def control(self):
        link = self.link
        u = urlsplit(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        cmd = u.path.rsplit('/', 1)[-1]
        t = link.since_first()
        if cmd == 'requests':
            since = float(q.get('since', 0))
            with link.log_lock:
                body = json.dumps([r for r in link.recent if r['t'] >= since]).encode()
        else:
            extra = {}
            with link.lock:
                if cmd == 'stall':
                    link.stalls.append((t, float(q.get('secs', 10))))
                elif cmd == 'drop':
                    link.drops.append((t, float(q.get('secs', 10))))
                elif cmd == 'rate':
                    link.schedule = [(0.0, float(q.get('kbps', 0)))]
                elif cmd == 'reset':
                    link.stalls, link.drops, link.statuses = [], [], []
                    link.schedule = [(0.0, float(q.get('kbps', 0)))]
                elif cmd == 'status':
                    link.statuses.append((t, float(q.get('secs', 10)), int(q.get('code', 503)),
                                          float(q.get('retryAfter', 0))))
                elif cmd == 'offline':
                    serial = os.environ.get('QOE_ADB_SERIAL', '')
                    if serial:
                        threading.Thread(target=offline, args=(link, serial, float(q.get('secs', 10))),
                                         daemon=True).start()
                        extra = {'delayMs': OFFLINE_DELAY_MS}
                    else:
                        extra = {'ok': False, 'why': 'no Android device: QOE_ADB_SERIAL is unset'}
                elif cmd == 'schedule':
                    steps = [tuple(map(float, s.split(':'))) for s in q.get('steps', '').split(',') if s]
                    link.schedule = [(0.0, steps[0][1] if steps else 0.0)] + [(t + s, k) for s, k in steps]
                elif cmd in ('live', 'live-stop'):
                    if link.live is not None and link.live.poll() is None:
                        link.live.kill()
                        link.live.wait()
                    link.live = None
                    # The last feed's files go before this call returns: a client polling for the new feed
                    # would otherwise read the old playlist as it.
                    shutil.rmtree(os.path.join(os.path.abspath(link.a.root), 'live'), ignore_errors=True)
                    if cmd == 'live':
                        here = os.path.dirname(os.path.abspath(__file__))
                        link.live = subprocess.Popen(
                            ['bash', os.path.join(here, 'live.sh'), q.get('kind', 'hls'), q.get('secs', '200'),
                             os.path.abspath(link.a.root)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            link.log('C', ms(), cmd, json.dumps(q))
            # epochMs: the suite reads the Mac's clock from here, to place a device's clock against the feed's dates.
            body = json.dumps({'ok': True, 'cmd': cmd, 't': round(t, 3), 'epochMs': round(time.time() * 1000),
                               **extra}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def live_ts(self, rid, head):
        """An IPTV-style channel: MPEG-TS from a fresh real-time encoder for every connection, until it hangs up."""
        link = self.link
        link.log('R', ms(), rid, self.command, self.path, '', 200, 0, 0)
        self.send_response(200)
        self.send_header('Content-Type', 'video/mp2t')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        if head:
            return
        ff = subprocess.Popen(
            ['ffmpeg', '-hide_banner', '-loglevel', 'error',
             '-re', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=25,noise=alls=10:allf=t',
             '-re', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
             *h264_encoder(), '-b:v', '3M', '-g', '50', '-c:a', 'aac', '-b:a', '128k', '-f', 'mpegts', 'pipe:1'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        sent = 0
        try:
            while True:
                buf = ff.stdout.read1(16384)
                if not buf:
                    break
                link.acquire(len(buf))
                self.wfile.write(buf)
                sent += len(buf)
            link.log('D', ms(), rid, sent, 0)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, socket.timeout, OSError) as e:
            link.log('X', ms(), rid, sent, type(e).__name__)
        finally:
            ff.kill()
            ff.wait()

    def serve(self, head):
        if self.path.startswith('/_control/'):
            return self.control()
        link = self.link
        rid = link.next_id()
        t = link.since_first()
        if link.in_window(link.drops, t):
            link.log('X', ms(), rid, self.command, self.path, 'refused')
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            return
        code, retry_after = link.status_now(t)
        if code:
            self.send_response(code)
            if retry_after:
                self.send_header('Retry-After', str(int(retry_after)))
            self.send_header('Content-Length', '0')
            self.end_headers()
            link.log('R', ms(), rid, self.command, self.path, 'status', code, 0, 0)
            return
        if self.path.split('?')[0] == '/live.ts':
            return self.live_ts(rid, head)
        a = link.a
        if a.redirect and 'sig=' not in self.path:
            self.send_response(302); self.send_header('Location', self.path + ('&' if '?' in self.path else '?') + f'sig={rid}')
            self.send_header('Content-Length', '0'); self.end_headers(); link.log('R', ms(), rid, self.command, self.path, 'redirect', 302, 0, 0); return
        if a.expire_after and t > a.expire_after:
            self.send_error(403); link.log('R', ms(), rid, self.command, self.path, 'expired', 403, 0, 0); return
        if a.max_conns and link.active >= a.max_conns:
            self.send_error(503); link.log('R', ms(), rid, self.command, self.path, 'busy', 503, 0, 0); return
        if a.error_rate and re.search(a.error_paths, self.path.split('?')[0]) and link.rng.random() < a.error_rate:
            self.send_response(a.error_status)
            if a.retry_after: self.send_header('Retry-After', str(int(a.retry_after)))
            self.send_header('Content-Length', '0'); self.end_headers()
            link.log('R', ms(), rid, self.command, self.path, 'injected', a.error_status, 0, 0); return
        if a.etag_flip and (self.headers.get('If-Match') or self.headers.get('If-Range')):
            self.send_response(412); self.send_header('Content-Length', '0'); self.end_headers()
            link.log('R', ms(), rid, self.command, self.path, 'if-match', 412, 0, 0); return
        path = self.translate_path(self.path.split('?')[0])
        if not os.path.isfile(path):
            self.send_error(404)
            link.log('R', ms(), rid, self.command, self.path, '', 404, 0, 0)
            return
        size = os.path.getsize(path)
        rng = None if (a.no_range or a.chunked) else self.headers.get('Range')
        start, end, status = 0, size - 1, 200
        if rng:
            m = re.match(r'bytes=(\d*)-(\d*)', rng)
            if m and m.group(1):
                start = int(m.group(1))
                end = min(int(m.group(2)) if m.group(2) else size - 1, size - 1)
            elif m and m.group(2):
                start, end = max(0, size - int(m.group(2))), size - 1
            if start >= size:
                self.send_response(416)
                self.send_header('Content-Range', f'bytes */{size}')
                self.send_header('Content-Length', '0')
                self.end_headers()
                link.log('R', ms(), rid, self.command, self.path, rng, 416, start, end)
                return
            status = 206
        link.log('R', ms(), rid, self.command, self.path, rng or '', status, start, end)
        if link.rtt:
            time.sleep(link.rtt)
        self.send_response(status)
        self.send_header('Content-Type', TYPES.get(os.path.splitext(path)[1], 'application/octet-stream'))
        if not (a.no_range or a.chunked): self.send_header('Accept-Ranges', 'bytes')
        if a.chunked: self.send_header('Transfer-Encoding', 'chunked')
        else: self.send_header('Content-Length', str(end - start + 1))
        if a.etag_flip:
            link.etag_n += 1; self.send_header('ETag', f'"e{link.etag_n}"')
        else: self.send_header('ETag', '"stable"')
        if status == 206:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        if head:
            link.log('D', ms(), rid, 0, 0)
            return
        sent, t_begin, next_p = 0, time.monotonic(), time.monotonic() + 0.25
        conn_bps = a.conn_rate * 1000 / 8
        link.active += 1
        try:
            with open(path, 'rb') as f:
                f.seek(start)
                remaining = end - start + 1
                while remaining > 0:
                    n = min(16384, remaining)
                    link.acquire(n)
                    buf = f.read(n)
                    if not buf:
                        break
                    if a.chunked: self.wfile.write(b'%x\r\n' % len(buf) + buf + b'\r\n')
                    else: self.wfile.write(buf)
                    if conn_bps:
                        ahead = sent + len(buf) - conn_bps * (time.monotonic() - t_begin)
                        if ahead > 0: time.sleep(ahead / conn_bps)
                    sent += len(buf)
                    remaining -= len(buf)
                    if time.monotonic() >= next_p:
                        link.log('P', ms(), rid, start + sent)
                        next_p = time.monotonic() + 0.25
            if a.chunked: self.wfile.write(b'0\r\n\r\n')
            link.log('D', ms(), rid, sent, '%.3f' % (time.monotonic() - t_begin))
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, socket.timeout, OSError) as e:
            link.log('X', ms(), rid, sent, type(e).__name__)
            self.close_connection = True
        finally:
            link.active -= 1

def main():
    p = argparse.ArgumentParser()
    p.add_argument('root'); p.add_argument('port', type=int)
    p.add_argument('--bind', default='127.0.0.1')
    p.add_argument('--rate', type=float, default=0.0)
    p.add_argument('--schedule', default='')
    p.add_argument('--rtt', type=float, default=0.0)
    p.add_argument('--stall', default='')
    p.add_argument('--drop', default='')
    p.add_argument('--log', default='')
    p.add_argument('--idle-close', type=float, default=0.0)
    # Server behaviours we don't control (file hosts, CDNs), all off by default:
    p.add_argument('--no-range', action='store_true', help='ignore Range: always 200 with the whole body, no Accept-Ranges')
    p.add_argument('--conn-rate', type=float, default=0.0, help='per-connection cap in kbit/s (file-host style)')
    p.add_argument('--max-conns', type=int, default=0, help='refuse (503) a request while this many transfers are active')
    p.add_argument('--etag-flip', action='store_true', help='a new ETag on every response; If-Match / If-Range then fail (412)')
    p.add_argument('--expire-after', type=float, default=0.0, help='403 for requests that start this many seconds after the first')
    p.add_argument('--error-rate', type=float, default=0.0, help='probability that a request matching --error-paths fails')
    p.add_argument('--error-status', type=int, default=503)
    p.add_argument('--error-paths', default=r'\.(ts|m4s|mp4|mkv|vtt)$')
    p.add_argument('--retry-after', type=float, default=0.0, help='Retry-After seconds on --error-status replies')
    p.add_argument('--redirect', action='store_true', help='302 every request to the same path with a signature query')
    p.add_argument('--chunked', action='store_true', help='no Content-Length: chunked 200 replies, no Range')
    a = p.parse_args()
    Handler.link = Link(a)
    handler = functools.partial(Handler, directory=a.root)
    server = http.server.ThreadingHTTPServer((a.bind, a.port), handler)
    server.daemon_threads = True
    link = Handler.link

    def stop(*_):
        # A feed outlives a killed server otherwise, and ffmpeg goes on writing into the media folder.
        if link.live is not None and link.live.poll() is None:
            link.live.kill()
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f'serving {a.root} on {a.bind}:{a.port}', flush=True)
    server.serve_forever()

if __name__ == '__main__':
    main()
