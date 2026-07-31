# pkaappi Compatibility TODO

Goal: make `pkaappi` a correct R7RS-small Scheme implementation that runs the
same programs as `kaappi`, with the same CLI conventions.

Current: Stage 6 complete (self-hosting). **260 tests pass** (was 194 before Phase 1–2).

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
- [x] `make-parameter`
- [x] `features`
- [x] `write-shared`, `write-simple`
- [x] `apply` (paal-compiled, up to 8 args — see limitation below)
- [x] `values` / `call-with-values` (paal-compiled MVR-tagged, up to 4 return values)
- [x] `force`, `make-promise`, `promise?` (custom vector-based implementation)

**Known limitations (still open):**

- [ ] `guard` — requires paal VM-level continuation support; HOST `call/cc` and
      `with-exception-handler` cannot call paal closures as callbacks
- [ ] `parameterize` — requires paal-native `dynamic-wind`; same boundary issue as `guard`
- [ ] `define-syntax` hygiene — introduced bindings are not renamed (non-hygienic);
      macros that introduce `let` bindings can capture user variables
- [ ] `define-syntax` nested ellipsis — only single-level `...` is supported
- [ ] `let-syntax` / `letrec-syntax` true mutual recursion — sequential binding only
- [ ] `apply` arity limit — crashes with more than 8 arguments
- [ ] `call-with-values` value count limit — crashes with more than 4 return values
- [ ] `with-exception-handler` restart behavior (raise-continuable path)
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

- [ ] `#u8(...)` bytevector literals (e.g. `#u8(1 2 3)`)
- [ ] `#e` / `#i` exactness prefix on numeric literals (`#e1.5` → exact 3/2)
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

## Not planned

These kaappi features are Zig-native and are intentionally out of scope for paal,
which is a self-hosted Scheme implementation:

- SRFI 18 (OS threads with independent heaps) — requires native threading
- SRFI 170 (POSIX filesystem) — requires Zig syscall layer
- SRFI 192 (port positioning) — requires native port implementation
- LLVM native code generation — kaappi uses this for `compile`; paal has its own VM target
- `kaappi explain <code>` / KP-coded diagnostic system
- `kaappi doctor` — installation self-check; a paal equivalent would differ
