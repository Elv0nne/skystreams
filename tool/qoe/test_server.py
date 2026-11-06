"""server.py's control endpoint, each test on a server of its own.

From the repository: python3 -B -m unittest discover -s tool/qoe
"""
import json, os, socket, subprocess, sys, tempfile, time, unittest, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class Server:
    """server.py serving a folder with one 4 KB file, a.bin, on a free port; env adds to its environment."""

    def __init__(self, env=None):
        self.dir = tempfile.TemporaryDirectory()
        with open(os.path.join(self.dir.name, 'a.bin'), 'wb') as f:
            f.write(bytes(4096))
        self.port = free_port()
        self.log = os.path.join(self.dir.name, 'server.csv')
        self.proc = subprocess.Popen(
            [sys.executable, os.path.join(HERE, 'server.py'), self.dir.name, str(self.port), '--log', self.log],
            env={**os.environ, **(env or {})}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 10
        while True:
            try:
                self.control('requests')
                return
            except OSError:
                if time.time() > deadline:
                    self.close()
                    raise
                time.sleep(0.1)

    def get(self, path, headers=None):
        """The status, headers and body of a GET; an error status is an answer too."""
        req = urllib.request.Request(f'http://127.0.0.1:{self.port}/{path}', headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read()

    def control(self, cmd, **query):
        q = '&'.join(f'{k}={v}' for k, v in query.items())
        with urllib.request.urlopen(f'http://127.0.0.1:{self.port}/_control/{cmd}?{q}', timeout=5) as resp:
            return json.loads(resp.read())

    def close(self):
        self.proc.terminate()
        self.proc.wait(timeout=5)
        self.dir.cleanup()


class Requests(unittest.TestCase):
    def setUp(self):
        self.server = Server()
        self.addCleanup(self.server.close)

    def test_each_request_carries_its_method_and_range(self):
        # The suite tells the check's first kilobyte from a player's requests by the range.
        self.server.get('a.bin', {'Range': 'bytes=0-1023'})
        self.server.get('a.bin?qoe=x', {'Range': 'bytes=2048-'})
        self.server.get('a.bin')
        rows = self.server.control('requests', since=0)
        self.assertEqual([(r['method'], r['path'], r['status'], r['range']) for r in rows], [
            ('GET', '/a.bin', 206, 'bytes=0-1023'),
            ('GET', '/a.bin?qoe=x', 206, 'bytes=2048-'),
            ('GET', '/a.bin', 200, ''),
        ])


class Status(unittest.TestCase):
    def setUp(self):
        self.server = Server()
        self.addCleanup(self.server.close)

    def test_a_status_window_answers_every_request_with_its_code(self):
        self.server.control('status', code=503, secs=30, retryAfter=4)
        status, headers, body = self.server.get('a.bin', {'Range': 'bytes=0-1023'})
        self.assertEqual((status, headers['Retry-After'], body), (503, '4', b''))
        self.server.control('status', code=403, secs=30)
        status, headers, _ = self.server.get('a.bin')
        # The later window wins while both are open, as a server changing its mind does.
        self.assertEqual((status, headers['Retry-After']), (403, None))
        self.assertEqual([r['status'] for r in self.server.control('requests', since=0)], [503, 403])

    def test_a_status_window_ends(self):
        self.server.control('status', code=503, secs=0.3)
        time.sleep(0.5)
        self.assertEqual(self.server.get('a.bin')[0], 200)

    def test_reset_ends_a_status_window(self):
        self.server.control('status', code=503, secs=30)
        self.server.control('reset', kbps=0)
        self.assertEqual(self.server.get('a.bin')[0], 200)


class Offline(unittest.TestCase):
    """The offline mode takes the run's Android device off its network through adb; here adb is a script that records
    what it was asked and reports Wi-Fi off and mobile data on, as run.sh leaves a phone emulator."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.calls = os.path.join(self.dir.name, 'calls')
        adb = os.path.join(self.dir.name, 'adb')
        with open(adb, 'w') as f:
            f.write('#!/bin/sh\necho "$*" >> "$ADB_CALLS"\n'
                    'case "$*" in *mobile_data*) echo 1 ;; *wifi_on*) echo 0 ;; esac\n')
        os.chmod(adb, 0o755)
        self.env = {'QOE_ADB': adb, 'ADB_CALLS': self.calls}

    def test_offline_takes_the_device_off_its_network_and_puts_back_what_it_had(self):
        server = Server({**self.env, 'QOE_ADB_SERIAL': 'emulator-5554'})
        self.addCleanup(server.close)
        answer = server.control('offline', secs=0.5)
        self.assertEqual((answer['ok'], answer['delayMs']), (True, 1000))
        time.sleep(0.5)
        # The answer is on its way to the device before it goes: nothing yet.
        self.assertFalse(os.path.exists(self.calls))
        time.sleep(2.5)
        with open(self.calls) as f:
            calls = f.read().splitlines()
        self.assertEqual(calls, [
            '-s emulator-5554 shell settings get global wifi_on',
            '-s emulator-5554 shell settings get global mobile_data',
            '-s emulator-5554 shell svc data disable',
            '-s emulator-5554 shell svc wifi disable',
            '-s emulator-5554 shell svc data enable',
        ])
        with open(server.log) as f:
            marks = [line.split(',')[2] for line in f if line.startswith('C,')]
        self.assertEqual(marks, ['offline', 'offline-on', 'offline-off'])

    def test_without_a_device_offline_says_why_and_does_nothing(self):
        server = Server({**self.env, 'QOE_ADB_SERIAL': ''})
        self.addCleanup(server.close)
        answer = server.control('offline', secs=1)
        self.assertFalse(answer['ok'])
        self.assertIn('no Android device', answer['why'])
        time.sleep(1.5)
        self.assertFalse(os.path.exists(self.calls))


if __name__ == '__main__':
    unittest.main()
