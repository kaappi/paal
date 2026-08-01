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

    text = TARGET.read_text()
    new = re.sub(
        r"(    ;; BEGIN GENERATED — do not edit by hand\n).*?(    ;; END GENERATED\n)",
        lambda m: m.group(1) + body + m.group(2),
        text, flags=re.S)
    if new == text:
        sys.exit("embed-srfi: markers not found in " + str(TARGET))
    TARGET.write_text(new)
    print(f"embedded {len(entries)} SRFI libraries into {TARGET.relative_to(ROOT)}")


main()
