#!/usr/bin/env python3
"""Kill only a spawned SQLite fixture after durable commits, then reopen it."""
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    root = Path(__file__).resolve().parents[1]
    dart = os.environ.get('DART_BIN', 'dart')
    with tempfile.TemporaryDirectory(prefix='cosmos-sync-crash-') as temporary:
        directory = Path(temporary)
        database = directory / 'cache.sqlite'
        ready = directory / 'ready'
        # Keep the complete native-asset bundle next to the executable. A plain
        # `dart compile exe` omits sqlite3's code asset on Linux.
        executable = directory / 'bundle' / 'bin' / 'crash_cache_fixture'
        subprocess.run([dart, 'build', 'cli', '--target=bin/crash_cache_fixture.dart',
                        '--output=' + str(directory)],
                       cwd=root / 'packages/cosmos_sync', check=True, timeout=120)
        child = subprocess.Popen([str(executable), 'write', str(database), str(ready)])
        try:
            deadline = time.monotonic() + 20
            while not ready.exists():
                if child.poll() is not None:
                    raise RuntimeError('Crash fixture failed before durable commits')
                if time.monotonic() >= deadline:
                    raise TimeoutError('Crash fixture did not signal durable commit')
                time.sleep(0.05)
            child.kill()  # Popen-owned fixture process only; no other processes touched.
            child.wait(timeout=10)
            subprocess.run([str(executable), 'read', str(database)], check=True, timeout=20)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=10)


if __name__ == '__main__':
    main()
