#!/usr/bin/env python3
"""Keep essential package-local documentation identical to reviewed monorepo docs."""

import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
FILES = ("protocol.md", "query.md", "security.md", "authorization.md")


def content(name):
    text = (ROOT / "docs" / name).read_text()

    def link(match):
        label, target = match.groups()
        if ":" in target or target.startswith("#") or target.split("#")[0] in FILES:
            return match[0]
        return f"[{label}](https://github.com/anaregdesign/cosmos-sync/blob/main/docs/{target})"

    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    directory = ROOT / "packages/cosmos_sync/doc"
    if not args.check:
        directory.mkdir(exist_ok=True)
    stale = []
    for name in FILES:
        destination = directory / name
        expected = content(name)
        if args.check:
            if not destination.is_file() or destination.read_text() != expected:
                stale.append(name)
        else:
            destination.write_text(expected)
    if stale:
        print("Refresh package docs with python3 tools/package_docs.py: " + ", ".join(stale), file=sys.stderr)
        return 1
    print("Package protocol/query/security/authorization docs match reviewed source.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
