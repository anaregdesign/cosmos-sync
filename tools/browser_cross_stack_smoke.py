#!/usr/bin/env python3
"""Real Chrome IndexedDB/fetch/CORS/SSE against disposable Go JWT BFF."""
import functools
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path != '/result':
            self.send_error(404)
            return
        length = int(self.headers.get('Content-Length', '0'))
        if length > 1024:
            self.send_error(413)
            return
        self.server.result = self.rfile.read(length).decode('utf-8')
        self.send_response(204)
        self.end_headers()
        self.server.finished.set()

    def log_message(self, *args):
        pass


def main():
    root = Path(__file__).resolve().parents[1]
    chrome = os.environ.get('CHROME_EXECUTABLE') or shutil.which('google-chrome')
    if not chrome:
        raise RuntimeError('Set CHROME_EXECUTABLE to an installed Chromium browser')
    with tempfile.TemporaryDirectory(prefix='cosmos-sync-browser-') as temporary:
        directory = Path(temporary)
        handler = functools.partial(QuietHandler, directory=str(directory))
        web = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        web.finished = threading.Event()
        web.result = None
        origin = f'http://127.0.0.1:{web.server_port}'
        thread = threading.Thread(target=web.serve_forever, daemon=True)
        thread.start()
        (directory / 'index.html').write_text('<!doctype html><div id="result">RUNNING</div><script defer src="main.js"></script>')
        ready = directory / 'fixture.json'
        stop = directory / 'stop'
        log = directory / 'go-test.log'
        dart = os.environ.get('DART_BIN', 'dart')
        subprocess.run([dart, 'compile', 'js', 'tool/browser_cross_stack.dart', '-o', str(directory / 'main.js')],
                       cwd=root / 'packages/cosmos_sync', check=True, timeout=120)
        env = dict(os.environ, COSMOS_SYNC_E2E_READY_FILE=str(ready),
                   COSMOS_SYNC_E2E_STOP_FILE=str(stop), COSMOS_SYNC_E2E_ORIGIN=origin)
        with log.open('w+') as output:
            server = subprocess.Popen(['go', 'test', './tests', '-run', '^TestDartFixture$', '-count=1', '-v'],
                                      cwd=root / 'bff', env=env, stdout=output, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 60
                while not ready.exists():
                    if server.poll() is not None:
                        raise RuntimeError('Go browser fixture exited before ready')
                    if time.monotonic() >= deadline:
                        raise TimeoutError('Go browser fixture not ready in 60 seconds')
                    time.sleep(0.1)
                json.loads(ready.read_text())  # Never print the disposable token.
                browser = subprocess.Popen([chrome, '--headless=new', '--no-sandbox', '--disable-gpu',
                                            '--no-first-run', '--no-default-browser-check',
                                            f'--user-data-dir={directory / "chrome-profile"}', origin],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                           start_new_session=True)
                try:
                    if not web.finished.wait(40):
                        raise TimeoutError('Browser fixture did not finish in 40 seconds')
                    if not web.result.startswith('PASS browser IndexedDB + Go JWT HTTP:'):
                        print(web.result)  # Fixed status only; no credentials.
                        raise RuntimeError('Browser cross-stack contract failed')
                finally:
                    if browser.poll() is None:
                        os.killpg(browser.pid, signal.SIGTERM)
                        try:
                            browser.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            os.killpg(browser.pid, signal.SIGKILL)
                            browser.wait(timeout=10)
                print('PASS real Chromium IndexedDB/fetch + Go OIDC: CORS, reopen, ACK, snapshot, SSE, resume, query, tombstone, purge')
                stop.touch()
                if server.wait(timeout=10) != 0:
                    raise RuntimeError('Go fixture failed')
            finally:
                stop.touch()
                if server.poll() is None:
                    server.terminate()
                    try:
                        server.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait()
                web.shutdown()
                web.server_close()
                output.seek(0)
                print(output.read(), end='')


if __name__ == '__main__':
    main()
