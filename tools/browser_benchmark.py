#!/usr/bin/env python3
"""Bounded real Chromium/IndexedDB timing; disposable profile, no cloud access."""
import argparse
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


class ResultHandler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path != '/result':
            self.send_error(404)
            return
        length = int(self.headers.get('Content-Length', '0'))
        if not 0 < length <= 65536:
            self.send_error(413)
            return
        try:
            self.server.result = json.loads(self.rfile.read(length))
        except (ValueError, UnicodeError):
            self.send_error(400)
            return
        self.send_response(204)
        self.end_headers()
        self.server.finished.set()

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--documents', type=int, default=1000)
    arguments = parser.parse_args()
    if not 1 <= arguments.documents <= 1000:
        parser.error('--documents must be 1..1000')
    root = Path(__file__).resolve().parents[1]
    chrome = os.environ.get('CHROME_EXECUTABLE') or shutil.which('google-chrome')
    if not chrome:
        raise RuntimeError('Set CHROME_EXECUTABLE to installed Chromium')
    dart = os.environ.get('DART_BIN', 'dart')
    with tempfile.TemporaryDirectory(prefix='cosmos-sync-browser-benchmark-') as temporary:
        directory = Path(temporary)
        subprocess.run([dart, 'compile', 'js', '-O2', 'tool/browser_benchmark.dart', '-o', str(directory / 'main.js')],
                       cwd=root / 'packages/cosmos_sync', check=True, timeout=120)
        (directory / 'index.html').write_text('<!doctype html><title>Cosmos Sync browser benchmark</title><script defer src="main.js"></script>')
        handler = functools.partial(ResultHandler, directory=str(directory))
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        server.result = None
        server.finished = threading.Event()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = f'http://127.0.0.1:{server.server_port}/?documents={arguments.documents}'
        browser = None
        try:
            browser = subprocess.Popen([chrome, '--headless=new', '--no-sandbox', '--disable-gpu',
                                        '--no-first-run', '--no-default-browser-check',
                                        f'--user-data-dir={directory / "profile"}', url],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       start_new_session=True)
            if not server.finished.wait(60):
                raise TimeoutError('Real browser benchmark exceeded 60 seconds')
            result = server.result
            print(json.dumps(result, indent=2))
            if result.get('status') != 'PASS':
                raise RuntimeError('Browser benchmark correctness or cleanup failed')
            if result['fixture']['documents'] != arguments.documents:
                raise RuntimeError('Browser result did not match requested count')
        finally:
            if browser is not None and browser.poll() is None:
                os.killpg(browser.pid, signal.SIGTERM)
                try:
                    browser.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(browser.pid, signal.SIGKILL)
                    browser.wait(timeout=10)
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
