# R7RS conformance suite

paal's own `tests/test-paal.scm` was written from the inside — it tests what paal's authors knew
to test. This suite is an outside oracle, and the first thing it did was find four defects nobody
had thought to look for, including `(values 1)` returning a tagged pair and `(environment …)`
destroying the running program's macro table.

It is a **ratchet, not a gate**. paal does not pass the whole suite. What `make test` enforces is
that the numbers do not move without someone deciding they should.

## Provenance

| | |
|---|---|
| `r7rs-tests.scm` | `kaappi/tests/scheme/r7rs/r7rs-tests.scm` |
| `libs/chibi/test.sld` | `kaappi/lib/chibi/test.sld` |
| upstream commit | `b2ff6238606093d29f92fdec1cc1ef817d2504d8` (2026-07-08), kaappi `v0.22.1` |

**`r7rs-tests.scm` is byte-identical to upstream and must stay that way.** The manifest keys on
exact per-section counts, so editing the suite silently invalidates every one of them.

Vendored rather than read from `../kaappi`: `make test` has to work in a bare checkout, and CI
clones kaappi to a temp directory without telling `make` where it went.

### The one adaptation

`libs/chibi/test.sld` adds a `%sections` accumulator, `test-sections` / `test-totals` /
`test-reset!`, and the `%section-open?` guard that stops an unmatched `test-end` re-recording the
previous section. Nothing else changed — in particular `test-approx=?`'s 1e-6 relative tolerance
must stay exactly as upstream has it, because the suite hard-codes constants like
`3.14159265358979` that compare equal only under it.

## Files

| | |
|---|---|
| `r7rs-tests.scm` | the suite, verbatim |
| `libs/chibi/test.sld` | the test framework the suite imports, plus section reporting |
| `paal-r7rs-driver.sld` | runs the suite one top-level form at a time |
| `paal-r7rs-expected.sld` | **generated** — the per-section baseline |
| `baseline.scm` | prints a replacement for the above |
| `../test-r7rs.scm` | asserts driver output against the baseline |

## Why form-by-form

Two constraints, and the driver is the answer to both.

paal is a **whole-program compiler** — `pkaappi-compile-forms` expands every form before emitting
any of them — so one unsupported form anywhere means *zero* tests run. `paal check` on this suite
dies outright. Driving one form at a time in its own `guard` costs a bad form and nothing else.

And the **self-hosted path is ~500× slower** than the HOST one (163 s against 0.30 s on a 59-line
excerpt), so shelling out to `paal file.scm` is not viable. The driver runs the HOST bytecode
pipeline in process; the whole suite takes about 1.5 seconds.

The driver runs the **bytecode pipeline only**. The tree-walking VM has no incremental entry point
— `paal-eval-program` resets its top-level environment on every call — so form-by-form accumulation
there would need new API for a VM that is documented as the bootstrap path. Per-fix coverage in
`tests/test-paal.scm` keeps the two pipelines pinned to the same answers.

## Refreshing the baseline

After any change that moves the numbers:

```bash
make r7rs-baseline > tests/r7rs/paal-r7rs-expected.sld
```

Then **read the diff.** That diff is the proof a fix did what it claimed, and the only place a
regression somewhere else in the suite shows up. A refresh with an unexplained line in it is a bug
report.

If a section's counts moved, `make test-r7rs` replays the suite transcript so you can see which
assertions changed.

## Refreshing the suite itself

```bash
cp ../kaappi/tests/scheme/r7rs/r7rs-tests.scm tests/r7rs/r7rs-tests.scm
cp ../kaappi/lib/chibi/test.sld tests/r7rs/libs/chibi/test.sld   # then re-apply the adaptation
```

Update the commit above, then regenerate the baseline and review the whole diff — every count is
suspect after a suite change, and `expected-errors` holds *form indices*, which shift if the file
gains or loses a top-level form.
