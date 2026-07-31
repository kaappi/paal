# pkaappi Compatibility TODO

Goal: make `pkaappi` a correct R7RS-small Scheme implementation that runs the
same programs as `kaappi`, with the same CLI conventions.

Current: Stage 6 complete (self-hosting). **324 tests pass** (was 194 before Phase 1–2).

---

## Phase 1 — R7RS Language Core ✅ (mostly complete)

Special forms and expander gaps.

- [x] `define-syntax` + `syntax-rules` — basic hygienic macro system (single-level
      ellipsis; no nested ellipsis or hygiene renaming yet)
- [x] `let-syntax` / `letrec-syntax` — local macro binding (save/restore global macro env)
- [x] `case-lambda` — multi-arity dispatch via let-destructuring (no `apply`)
- [x] `define-values` / `let-values` / `let*-values` — multiple-value binding forms
- [x] `delay` / `delay-force` — lazy evaluation using custom vector-based promises
- [x] `include` / `include-ci` — splice forms from files at expansion time
- [x] `cond-expand` — feature-conditional code (`pkaappi`, `r7rs`, `scheme` supported)
- [x] `syntax-error` — compile-time error from macros
- [x] `case-lambda`, `define-values`, `let-values`, `let*-values` bytecode support

Missing primitives added to `paal-initial-env` (`lib/kaappi/paal/vm.sld`):

- [x] `exact-integer?`, `square`, `finite?`, `infinite?`, `nan?`
- [x] `floor/`, `floor-quotient`, `floor-remainder`
- [x] `truncate/`, `truncate-quotient`, `truncate-remainder`
- [x] `numerator`, `denominator`, `exact-integer-sqrt`
- [x] `make-list`, `list-set!`
- [x] `vector-map`, `vector-for-each` (paal-compiled in `pkaappi-make-globals`)
- [x] `string-map`, `string-for-each` (paal-compiled in `pkaappi-make-globals`)
- [x] `string-set!`, `string-copy!`, `string-fill!`
- [x] `string->utf8`, `utf8->string`, `string->vector`, `vector->string`
- [x] `bytevector-copy!`
- [x] `close-port`, `textual-port?`, `binary-port?`, `input-port-open?`, `output-port-open?`
- [x] `read-u8`, `peek-u8`, `u8-ready?`, `write-u8`
- [x] `read-error?`, `file-error?`
- [x] `make-parameter` (paal-native cell-based objects — see `parameterize` below)
- [x] `features`
- [x] `write-shared`, `write-simple`
- [x] `apply` (VM marker in `do-call!`; no arity ceiling, keeps tail position)
- [x] `values` / `call-with-values` (paal-compiled MVR-tagged, up to 4 return values)
- [x] `force`, `make-promise`, `promise?` (custom vector-based implementation)
- [x] `guard` / `raise` / `error` — both pipelines. The bytecode VM handles
      `%paal-guard-run` as a marker in `do-call!` and re-enters itself via
      `paal-call-value` to run the body and handler; the tree-walking VM binds a
      HOST procedure that trampolines both inside the guard. Catches paal `raise`
      *and* primitive errors. See `docs/architecture.md` § Exceptions in the
      bytecode VM.
- [x] `make-parameter` / `parameterize` — both pipelines. A parameter is a closure
      over a 2-slot cell `#(value converter)`; passing it `%paal-param-key` returns
      the cell, so `%paal-parameterize` can rebind it without a registry. No VM
      marker was needed in the end: `guard` already provides the unwind protection
      (restore, then re-raise), and since paal has no continuations for paal
      closures, a raise is the only non-local exit from the extent. HOST
      `make-parameter` could not be reused — a HOST parameter is only rebindable
      through HOST `parameterize`, which is syntax, so nothing can install a value
      procedurally. See `docs/architecture.md` § Parameter objects.

**Known limitations (still open):**

- [ ] `guard` nesting depth — kaappi v0.22.0 mishandles more than 63 dynamically
      nested `guard` forms (at depth 64 the innermost handler is skipped and an
      outer one catches instead). Reproduces in plain kaappi with no paal
      involved, so this is a core-repo bug; paal inherits it by delegating to
      HOST `guard`, with a ceiling a few levels lower still. Repro:
      `(define (f n) (guard (e (#t n)) (if (= n 0) (raise 'b) (f (- n 1))))) (f 64)`
      → returns `1`, should return `0`. Filed as kaappi/kaappi#1886 — the cap is
      `MAX_HANDLERS = 64`, and exceeding it yields a *catchable* error, so an
      enclosing `guard` swallows it. Revisit this entry when that lands.
- [ ] `define-syntax` hygiene — introduced bindings are not renamed (non-hygienic);
      macros that introduce `let` bindings can capture user variables
- [ ] `define-syntax` nested ellipsis — only single-level `...` is supported
- [ ] `let-syntax` / `letrec-syntax` true mutual recursion — sequential binding only
- [ ] `call-with-values` value count limit — crashes with more than 4 return values
- [ ] `with-exception-handler` restart behavior (raise-continuable path) —
      `raise-continuable` currently behaves exactly like `raise`
- [ ] `guard` re-raise environment — an unmatched clause re-raises from the
      handler's dynamic environment, not the original one (R7RS requires the latter)
- [ ] `floor/` and `truncate/` — return two values; currently HOST procs that return
      actual multiple-values (incompatible with paal MVR encoding in bytecode path)

---

## Phase 2 — Standard Libraries in User Environment ✅ (procedures added; import resolution pending)

User programs call `(import (scheme inexact))` etc. Currently `import` is a no-op and
`paal-initial-env` is a flat unnamespaced blob. The procedures are now available, but
`(import (scheme inexact))` won't actually load them on demand until Phase 5.

- [x] `(scheme inexact)` — `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `exp`, `log`
      all added to `paal-initial-env`
- [x] `(scheme char)` — `char-ci=?`, `char-ci<?`, `char-ci>?`, `char-ci<=?`, `char-ci>=?`,
      `char-foldcase`, `string-ci=?`, `string-ci<?`, `string-ci>?`, `string-ci<=?`,
      `string-ci>=?`, `string-foldcase`, `digit-value` — all added
- [x] `(scheme lazy)` — paal has custom vector-based implementations for `delay`, `force`,
      `make-promise`, `promise?`; `delay-force` via expander
- [x] `(scheme time)` — `current-second`, `current-jiffy`, `jiffies-per-second` added
- [x] `(scheme process-context)` — `command-line` (HOST lambda, user args forwarded),
      `exit`, `emergency-exit`, `get-environment-variable`, `get-environment-variables` added
- [x] `(scheme file)` — `call-with-input-file`, `call-with-output-file`,
      `with-input-from-file`, `with-output-to-file`,
      `open-binary-input-file`, `open-binary-output-file`,
      `file-exists?`, `delete-file` added
- [x] `(scheme write)` completeness — `write-shared`, `write-simple` added
- [ ] `(scheme complex)` — complex number arithmetic operations
- [ ] `(scheme r5rs)` — R5RS compatibility subset
- [ ] `(scheme eval)` — `eval`, `environment` (hard: re-entering pipeline from user code)
- [ ] `(scheme load)` — `load`
- [ ] `(scheme repl)` — `interaction-environment`

---

## Phase 3 — Reader Completeness

Gaps in `lib/kaappi/paal/reader.sld`:

- [x] `#u8(...)` bytevector literals (e.g. `#u8(1 2 3)`)
- [x] `#e` / `#i` exactness prefix on numeric literals (`#e1.5` → exact 3/2)
      — already present; this entry was stale
- [ ] Datum labels `#N=` / `#N#` — shared/circular structure notation

---

## Phase 4 — CLI Parity with kaappi

- [x] **Script args forwarding** — `pkaappi file.scm arg1 arg2` sets `(command-line)`
      to `("file.scm" "arg1" "arg2")` inside user programs via HOST lambda in globals
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

## Cross-cutting correctness

Issues that span stages rather than belonging to one phase.

**Fixed:**

- [x] **Closure mutation was silently dropped** (`emitter.sld`) — `collect-set-targets`
      stopped at lambda boundaries, so a variable assigned only from inside a closure
      was never boxed. Each closure captured a private copy and the write vanished:
      `(let ((x 0)) (let ((f (lambda () (set! x 42)))) (f) x))` returned `0`.
      Now a `set!` target anywhere inside a nested lambda forces boxing, and a `set!`
      target counts as a use when deciding whether a variable is captured.
- [x] **`call-with-values` dropped multiple values** (`vm.sld`) — a paal producer whose
      body is a tail call returns a trampoline thunk, and HOST `call-with-values`
      applied the consumer to that thunk as a single argument. `define-values`,
      `let-values` and `let*-values` all failed on the tree-walking path with a `car`
      type error. Now forced with `trampoline-values`, which preserves value count.
- [x] **HOFs failed in the self-hosted path** (kaappi/paal#1) — `map`, `for-each`,
      `apply`, `filter`, `vector-map`, `vector-for-each`, `string-map`,
      `string-for-each`, `values`/`call-with-values` and the promise system all
      raised `not a callable` under `pkaappi-self-run-file` — the path
      `pkaappi file.scm` takes. The globals are populated by the HOST
      `pkaappi-make-globals` but consumed by the paal-compiled VM, and
      `define-record-type` cannot express a value both copies recognize: HOST
      kaappi makes an opaque native record, while paal's expander makes a vector
      tagged with a freshly allocated `(list '<name>)` pair. `<closure>` and
      `<bytecode-function>` are now vectors tagged with interned symbols, so both
      copies agree. No measurable cost on the call hot path. See
      `docs/architecture.md` § Values that cross the HOST boundary.
- [x] **`.pbc` files could not use paal-compiled globals** — `pkaappi-run-pbc-file`
      built its globals from a bare `paal-initial-env` blob, so `pkaappi file.pbc`
      failed with `type error in 'map': expected procedure`. Now uses
      `pkaappi-make-globals` like the other entry points. Pre-existing and separate
      from #1; surfaced by the new `hof.scm` fixture.
- [x] **Test suite silently skipped tests and exited nonzero** — an uncaught error
      aborted the rest of its `test-group` without counting the remaining tests, so
      `make test` reported "all passed" while exiting 1 and running 10 fewer tests
      than it appeared to. Both underlying causes (`#u8`, `call-with-values`) are
      fixed, and so is the reporting weakness itself: `(kaappi test)`'s assertions
      are now syntax that thunk the expression, so a raise fails that one test and
      the run continues (kaappi-test `d67855a`). The pass count is a trustworthy
      signal again — a green run no longer hides skipped tests.

**Open:**

- [ ] **`.pbc` files can become unreadable depending on byte offsets**
      (kaappi/kaappi#1920) — kaappi's `read` on a *file port* mis-handles a dotted
      pair that straddles a 4096-byte chunk boundary: a truncated prefix reports
      `UnexpectedChar`/`DotNotInList` instead of `UnexpectedEof`, and the
      incremental read loop treats that as fatal rather than reading the next
      chunk. `.pbc` files are full of `(#t . N)` upvalue specs, so a large enough
      one eventually lands on a boundary. It hit `cache/paal-vm-bc.pbc` when the
      guard logic was inlined into `do-call!`, breaking `make pbc-pipeline`.
      **Worked around in paal:** `paal-read-bc-file` now slurps the file and
      parses from a string port, where no chunk boundary exists, so every `.pbc`
      read is immune. Left open because the upstream bug is unfixed and still
      affects any other `read` from a file port. Splitting `run-guard!` back out
      was never a real defence — it only shifted byte offsets.
      NB the earlier "large and deeply nested" diagnosis in this entry was wrong:
      `paal-expander.pbc` is both bigger and deeper and reads back fine.

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
