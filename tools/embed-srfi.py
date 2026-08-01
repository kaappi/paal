#!/usr/bin/env python3
"""Regenerate lib/kaappi/paal/embedded.sld from the bundled SRFI sources.

Rewrites only the region between the GENERATED markers, so the surrounding
commentary and the accessor stay hand-maintained.  Run via `make embed-srfi`.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
TARGET = ROOT / "lib/kaappi/paal/embedded.sld"
# Bundled because a standalone binary should resolve these with no filesystem.
SRFIS = [1, 9, 13, 23, 28, 39, 48, 64, 69, 133]


def scheme_string(text):
    """Escape a source file into one Scheme string literal.

    Only \\ and " need escaping; a literal newline inside a Scheme string is
    legal and keeps the generated file readable and diffable.
    """
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    entries = []
    for n in SRFIS:
        src = ROOT / f"lib/srfi/{n}.sld"
        if not src.exists():
            sys.exit(f"embed-srfi: missing {src}")
        entries.append(f"       (cons '(srfi {n})\n             {scheme_string(src.read_text())})")

    body = ("    (define %paal-embedded\n      (list\n"
            + "\n".join(entries) + "))\n")

    # Line-based splicing rather than a regex.  A regex over the whole file
    # has to survive whatever the embedded sources contain, and the first
    # attempt silently stopped matching once the region held 1300 lines of
    # escaped Scheme -- which broke `make binary` rather than this script.
    lines = TARGET.read_text().split("\n")
    begin = next((i for i, l in enumerate(lines)
                  if l.strip().startswith(";; BEGIN GENERATED")), None)
    end = next((i for i, l in enumerate(lines)
                if l.strip().startswith(";; END GENERATED")), None)
    if begin is None or end is None or end <= begin:
        sys.exit("embed-srfi: markers not found or out of order in " + str(TARGET))

    TARGET.write_text("\n".join(
        lines[:begin + 1] + body.split("\n")[:-1] + lines[end:]))

    print(f"embedded {len(entries)} SRFI libraries into {TARGET.relative_to(ROOT)}")


main()
