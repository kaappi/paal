# SRFI shelf conformance suite

The R7RS suite (`tests/r7rs/`) is the outside oracle for the language; this
is the outside oracle for the **shelf** — kaappi's own per-SRFI test files,
run against paal's vendored `lib/srfi/` through paal's own pipeline.  Its
first run found a dozen real defects the import-only sweep could not see,
from a stale vendored SRFI 41 to charset objects that cannot cross into the
host's string primitives.

Like the R7RS suite it is a **ratchet, not a gate**: paal does not pass every
file, and what `make test` enforces is that the per-file verdicts do not move
without someone deciding they should — in either direction.

## Provenance

| | |
|---|---|
| `vendor/*.scm` | `kaappi/tests/scheme/srfi/` |
| upstream commit | `67fc69d0`, kaappi `v0.22.1`+ |

Vendored rather than read from `../kaappi` for the same reason the R7RS suite
is: `make test` has to work in a bare checkout.

### Adaptations

Upstream files are copied verbatim **except** where a `[paal adaptation]`
header comment records a change, of exactly three kinds:

- **Missing imports completed** — several upstream files call `exit`,
  `display` or `caddr` without importing the library that exports them.
  kaappi does not enforce import scope, so its CI never noticed; paal's
  conformance check rejects the file outright.  The completed import is the
  file's own bug fixed in place, reported upstream.
- **SRFI 18 material excised** (`srfi14.scm`) — OS threads are recorded out
  of scope for paal (docs/TODO.md "Not planned").
- **Randomized volume trimmed** (`srfi14.scm`) — a brute-force model check
  tolerable natively is minutes through the in-process pipeline; the trial
  count shrinks, the property stays.

## Verdict model

One verdict per **file** — `pass` or `fail` — because that is the one
contract the ~220 heterogeneous upstream files share: most are SRFI 64
suites or exit-code assertion scripts, and each reports through "completes
quietly, or raises / exits nonzero".  It is the same granularity kaappi's CI
holds them to, one process per file.

The driver (`paal-srfi-driver.sld`) runs the HOST bytecode pipeline in
process (shelling out is the known ~500× loss) and rebinds `exit`/
`emergency-exit` in each file's globals table to raise a sentinel, so an
assertion script's `(exit 1)` fails its file instead of killing the run.

`paal-srfi-skip.sld` is the hand-curated skip list — files the driver must
not run, each with its reason on record.  A skip entry whose file vanishes
fails the coverage check, so the list cannot go stale silently.

## Files

| | |
|---|---|
| `vendor/*.scm` | the upstream test files |
| `paal-srfi-driver.sld` | file → verdict |
| `paal-srfi-expected.sld` | **generated** — the per-file baseline |
| `paal-srfi-skip.sld` | hand-curated skips with reasons |
| `baseline.scm` | prints a replacement baseline |
| `../test-srfi.scm` | asserts verdicts + coverage against the baseline |

## Refreshing the baseline

```bash
make srfi-baseline > tests/srfi/paal-srfi-expected.sld
```

Then **read the diff** — a fail line carries its reason as a trailing
comment, so the diff shows not just which file moved but why.  A refresh
with an unexplained line in it is a bug report.

## Adding files

Copy from `kaappi/tests/scheme/srfi/`, update the commit above, add either a
baseline entry (regenerate) or a skip entry (by hand, with the reason), and
keep any adaptation to the three recorded kinds.
