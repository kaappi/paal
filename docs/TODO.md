# pkaappi Compatibility TODO

Goal: make `pkaappi` a correct R7RS-small Scheme implementation that runs the
same programs as `kaappi`, with the same CLI conventions.

Current: Stage 6 complete (self-hosting). 194 tests pass.

---

## Phase 1 — R7RS Language Core

Special forms and expander gaps (blocking real programs).

- [ ] `define-syntax` + `syntax-rules` — full hygienic macro system (any library
      using macros fails to load without this; #1 blocker)
- [ ] `let-syntax` / `letrec-syntax` — local macro binding scopes
- [ ] `case-lambda` — multi-arity dispatch (explicitly deferred; common in portable libraries)
- [ ] `guard` — standard exception-handling form (`guard` exists in HOST but is not
      exposed in user programs via the paal pipeline)
- [ ] `parameterize` — dynamic binding (needs `make-parameter` in initial-env first)
- [ ] `define-values` / `let-values` / `let*-values` — multiple-value binding forms
      (`values` and `call-with-values` are present but the binding syntax is not)
- [ ] `delay` / `delay-force` — lazy evaluation primitives (prerequisite for `(scheme lazy)`)
- [ ] `include` / `include-ci` — source file inclusion forms
- [ ] `cond-expand` — feature-conditional code (needed for portable library compatibility)
- [ ] `syntax-error` — compile-time error reporting from within macros

Missing primitives in `paal-initial-env` (`lib/kaappi/paal/vm.sld`):

- [ ] `exact-integer?`, `square`, `finite?`, `infinite?`, `nan?`
- [ ] `floor/`, `floor-quotient`, `floor-remainder`
- [ ] `truncate/`, `truncate-quotient`, `truncate-remainder`
- [ ] `numerator`, `denominator`, `exact-integer-sqrt`
- [ ] `make-list`, `list-set!`
- [ ] `vector-map`, `vector-for-each`
- [ ] `string-map`, `string-for-each`, `string-set!`, `string-copy!`, `string-fill!`
- [ ] `string->utf8`, `utf8->string`, `string->vector`, `vector->string`
- [ ] `bytevector-copy!`
- [ ] `close-port`, `textual-port?`, `binary-port?`, `input-port-open?`, `output-port-open?`
- [ ] `read-u8`, `peek-u8`, `u8-ready?`, `write-u8`
- [ ] `read-error?`, `file-error?`
- [ ] `make-parameter`
- [ ] `features`
- [ ] `write-shared`, `write-simple`
- [ ] `with-exception-handler` restart behavior (raise-continuable path)

---

## Phase 2 — Standard Libraries in User Environment

User programs call `(import (scheme inexact))` etc. Currently `import` is a no-op and
`paal-initial-env` is a flat unnamespaced blob. These libraries must resolve to real definitions.

- [ ] `(scheme inexact)` — `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `exp`, `log`
      and the multi-argument `atan`; entirely absent from initial-env
- [ ] `(scheme char)` — `char-ci=?` and all case-insensitive char/string comparisons,
      `char-foldcase`, `string-foldcase`, `digit-value`
- [ ] `(scheme lazy)` — `delay`, `force`, `delay-force`, `make-promise`, `promise?`
- [ ] `(scheme time)` — `current-second`, `current-jiffy`, `jiffies-per-second`
- [ ] `(scheme process-context)` — `command-line`, `exit`, `emergency-exit`,
      `get-environment-variable`, `get-environment-variables`
      (exist in HOST `src/main.scm` but not visible inside user programs)
- [ ] `(scheme file)` — `call-with-input-file`, `call-with-output-file`,
      `with-input-from-file`, `with-output-to-file`,
      `open-binary-input-file`, `open-binary-output-file`,
      `file-exists?`, `delete-file`
- [ ] `(scheme write)` completeness — `write-shared`, `write-simple`
- [ ] `(scheme complex)` — complex number arithmetic operations
- [ ] `(scheme r5rs)` — R5RS compatibility subset
- [ ] `(scheme eval)` — `eval`, `environment` (hard: re-entering pipeline from user code)
- [ ] `(scheme load)` — `load`
- [ ] `(scheme repl)` — `interaction-environment`

---

## Phase 3 — Reader Completeness

Gaps in `lib/kaappi/paal/reader.sld`:

- [ ] `#u8(...)` bytevector literals (e.g. `#u8(1 2 3)`)
- [ ] `#e` / `#i` exactness prefix on numeric literals (`#e1.5` → exact 3/2)
- [ ] Datum labels `#N=` / `#N#` — shared/circular structure notation

---

## Phase 4 — CLI Parity with kaappi

Documented exceptions in `CLAUDE.md` that should eventually be resolved:

- [ ] **Script args forwarding** — `pkaappi file.scm arg1 arg2` should set
      `(command-line)` to `("file.scm" "arg1" "arg2")` inside user programs;
      currently args after the filename are silently dropped
- [ ] **`--lib-path <dir>`** — allow user programs to `(import (foo bar))` from
      an external directory (requires Phase 5 module system first)
- [ ] **`check` subcommand** — compile-only static analysis: reads, expands, compiles,
      executes nothing; reports errors; used in CI
- [ ] **`fmt` subcommand** — canonical 2-space formatter with `--check` mode for CI
- [ ] **Bytecode cache for user programs** — cache compiled `.scm` keyed by source
      hash; currently every run recompiles from source

---

## Phase 5 — Module System

`import` and `export` both expand to `(quote #f)` — they are no-ops. Real library
resolution is needed before `--lib-path` or SRFI imports can work.

- [ ] **Real `import` resolution** — search `--lib-path` + standard paths for
      `(foo bar)` → `foo/bar.sld`; compile and load it into the current globals
- [ ] **Real `export` filtering** — when a `define-library` body runs, only exported
      names are visible to importers (not all definitions)
- [ ] **Selective import forms** — `(import (only (scheme base) car cdr))`,
      `(import (rename ...))`, `(import (except ...))`, `(import (prefix ...))`
- [ ] **`cond-expand` feature list** — `(pkaappi)`, `(r7rs)`, `(kaappi)` feature
      identifiers for portability
- [ ] **Circular import detection** — guard against infinite load loops

---

## Phase 6 — Standalone Binary

Remove the `kaappi` host dependency.

- [ ] **Bundle pipeline `.pbc` files** — embed `cache/*.pbc` in the binary so it
      needs no external files at runtime (the `binary` Makefile target uses
      `zig build -Dbundle-src=`; adapt for `.pbc` format)
- [ ] **Self-contained primitive env** — currently `paal-initial-env` maps to HOST
      kaappi procedures; the standalone binary needs its own primitive implementations
- [ ] **Standalone REPL** — readline or plain line input without kaappi's REPL
- [ ] **Distribution strategy** — single static binary vs binary + lib directory

---

## Phase 7 — SRFI Ecosystem

No SRFI support exists. Priority order (most-needed first):

- [ ] SRFI 1 — list library (`fold`, `filter`, `any`, `every`, `iota`, etc.)
- [ ] SRFI 13 — string library (`string-contains`, `string-trim`, `string-split`, etc.)
- [ ] SRFI 9 — `define-record-type` (already a core form; just needs the import wrapper)
- [ ] SRFI 23 — `error` (already present; just needs the import path)
- [ ] SRFI 64 — test framework (needed to eventually replace `(kaappi test)` dependency)
- [ ] SRFI 39 — parameter objects (depends on `parameterize` from Phase 1)
- [ ] SRFI 28 / SRFI 48 — basic / intermediate `format`
- [ ] SRFI 69 — hash tables
- [ ] SRFI 133 — vector library

---

## Phase 8 — Advanced Features (Long-Term)

Requires significant new infrastructure; no fixed timeline.

- [ ] **`(scheme eval)` / `eval`** — expose the paal pipeline as callable from within user code
- [ ] **Profiling** — `--profile` flag with call-count report (matches kaappi `--profile`)
- [ ] **Coverage** — `--coverage` / `--coverage-xml` flags for procedure-level coverage
      (paal currently uses kaappi's `--coverage` for its own test suite)
- [ ] **Stepping debugger** — breakpoints, step/next, frame navigation
- [ ] **C FFI** — `(kaappi ffi)` equivalent for paal programs
- [ ] **Fibers / concurrency** — cooperative green threads + channels
- [ ] **Native backend** — LLVM or alternative native code generation
- [ ] **GC** — standalone binary needs its own garbage collector
- [ ] **Bignum / rationals / complex** — arbitrary-precision arithmetic

---

## Not planned

These kaappi features are Zig-native and are intentionally out of scope for paal,
which is a self-hosted Scheme implementation:

- SRFI 18 (OS threads with independent heaps) — requires native threading
- SRFI 170 (POSIX filesystem) — requires Zig syscall layer
- SRFI 192 (port positioning) — requires native port implementation
- LLVM native code generation — kaappi uses this for `compile`; paal has its own VM target
- `kaappi explain <code>` / KP-coded diagnostic system
- `kaappi doctor` — installation self-check; a paal equivalent would differ
