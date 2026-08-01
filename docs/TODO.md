# paal Compatibility TODO

Goal: make `paal` a correct R7RS-small Scheme implementation that runs the
same programs as `kaappi`, with the same CLI conventions.

Current: Stage 6 complete (self-hosting). **550 tests pass** (was 194 before Phase 1–2).

---

## Phase 1 — R7RS Language Core ✅ (mostly complete)

Special forms and expander gaps.

- [x] `define-syntax` + `syntax-rules` — nested ellipsis to arbitrary depth,
      `x ... ...` splicing, and the `(... <template>)` escape. Hygienic in both
      directions: template-introduced bindings are renamed per expansion so they
      cannot capture, and a template's *free* identifiers are marked `%gref%` so
      they resolve at the top level rather than being captured by a same-named
      binding at the use site. Exact while macros are defined at top level, which
      is where paal's are — the macro table is global, so a macro has no other
      definition environment to refer to. A macro defined inside a local scope
      and referring to a local of that scope would still resolve to the top
      level; nothing in paal creates one today.
- [x] `let-syntax` / `letrec-syntax` — correct R7RS 4.3.1 regions. `letrec-syntax`
      bindings may refer to each other and to themselves (mutual recursion already
      worked — the old entry claiming otherwise was wrong); `let-syntax` bindings
      may not, so a template naming a sibling keyword resolves to the outer
      binding. The distinction is one wrapper: a let-syntax transformer expands
      its output in the environment captured before any of the bindings were
      installed.
- [x] `case-lambda` — multi-arity dispatch via let-destructuring (no `apply`)
- [x] `define-values` / `let-values` / `let*-values` — multiple-value binding forms
- [x] `delay` / `delay-force` — lazy evaluation using custom vector-based promises
- [x] `include` / `include-ci` — splice forms from files at expansion time
- [x] `cond-expand` — feature-conditional code (`paal`, `r7rs`, `scheme` supported)
- [x] `syntax-error` — compile-time error from macros
- [x] `case-lambda`, `define-values`, `let-values`, `let*-values` bytecode support

Missing primitives added to `paal-initial-env` (`lib/kaappi/paal/vm.sld`):

- [x] `exact-integer?`, `square`, `finite?`, `infinite?`, `nan?`
- [x] `floor/` (paal-native — returns two values), `floor-quotient`, `floor-remainder`
- [x] `truncate/` (paal-native — returns two values), `truncate-quotient`,
      `truncate-remainder`
- [x] `numerator`, `denominator`, `exact-integer-sqrt` (paal-native — returns two values)
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
- [x] `values` / `call-with-values` (paal-compiled, MVR-tagged; no value-count
      limit — the consumer is invoked through `apply`)
- [x] `force`, `make-promise`, `promise?` (custom vector-based implementation)
- [x] `guard` / `raise` / `error` — both pipelines. The bytecode VM handles
      `%paal-guard-run` as a marker in `do-call!` and re-enters itself via
      `paal-call-value` to run the body and handler; the tree-walking VM binds a
      HOST procedure that trampolines both inside the guard. Catches paal `raise`
      *and* primitive errors. See `docs/architecture.md` § Exceptions in the
      bytecode VM.
- [x] `with-exception-handler` / `raise-continuable` — both pipelines. The
      handler's return value becomes the value of the `raise-continuable` call.
      Handlers live on a paal-side stack in the bytecode path, because the
      handler must run *without* unwinding and the HOST condition system always
      unwinds; a handler runs with the outer stack installed, per R7RS. `raise`
      consults the same stack and then escapes, so a handler returning from a
      non-continuable raise triggers a "handler returned" secondary exception,
      matching the host. With no handler installed both fall through to the
      escape `guard` catches, so `guard` is unaffected. See
      `docs/architecture.md` § Exception handlers.
- [x] `make-parameter` / `parameterize` — both pipelines. A parameter is a closure
      over a 2-slot cell `#(value converter)`; passing it `%paal-param-key` returns
      the cell, so `%paal-parameterize` can rebind it without a registry. No VM
      marker was needed: cells are ordinary vectors and the wind stack is an
      ordinary list, so nothing here needs the VM. Restoring on a raise belongs
      to the enclosing `guard` — see the dynamic-environment entry below — and
      since paal has no continuations for paal closures, a raise is the only
      non-local exit from the extent. HOST `make-parameter` could not be reused —
      a HOST parameter is only rebindable through HOST `parameterize`, which is
      syntax, so nothing can install a value procedurally. See
      `docs/architecture.md` § Parameter objects.
- [x] `dynamic-wind` — both pipelines, paal-native. HOST `dynamic-wind` could not
      be reused: on the bytecode path it cannot enter a paal closure and raised
      a type error on the `before` thunk, and on either path its winders would
      be invisible to the stack a `guard` walks, so a raise would unwind past
      them in the host while paal's own frames stayed put. It is now a second
      frame kind on the same wind stack `parameterize` uses — winding out calls
      `after`, winding in calls `before` — so one `%paal-wind-out!` closes every
      extent between a guard and the raise, in innermost-first order. A guard
      *inside* an extent is not leaving it, so declining there does not run
      `after`. See `docs/architecture.md` § The wind stack.

**Known limitations (still open):**

- [x] `guard` nesting depth — **fixed upstream** by kaappi/kaappi#1919, closing
      kaappi/kaappi#1886. Both `MAX_HANDLERS` and `MAX_WINDS` were fixed 64-entry
      arrays and now grow on demand (`-Dmax-handlers`/`-Dmax-winds`, hard cap
      32768), and exceeding the limit is no longer a *catchable* condition — the
      thing that made it dangerous, since a user's own `guard` swallowed it and
      returned a plausible wrong value. Verified against a local build of kaappi
      `main`: paal's `guard` is now correct at depths 63, 64, 100, 200 and 400
      (it was wrong from ~61 up), a VM overflow surfaces as an uncatchable
      `KP3008` with exit 1 rather than being swallowed, and all of paal's tests
      pass against the fixed kaappi.

      Not yet in a release — the fix is 15 commits past the `v0.22.1` tag, and
      `kaappi` on `PATH` here is v0.22.0. Paal running against an older kaappi
      still has the old ceiling, so this is a note about *which* kaappi you run
      paal with, not about paal.
- [x] `guard` re-raise **dynamic environment** — done, and without the re-entrant
      continuations this entry used to say it was blocked behind. R7RS 4.2.7
      evaluates a guard's clauses in the dynamic environment of the `guard` but
      re-raises an unmatched condition in that of the original `raise`; the
      sample implementation jumps between the two with `call/cc` twice. Paal
      moves between them by save and restore instead, which works because
      parameterizations are its entire dynamic environment and each one is a
      mutable cell rather than a stack frame — so a dynamic environment is data.
      `%paal-parameterize` pushes a `#(cells news olds)` frame onto a shared-tail
      wind stack, and the guard winds out to its own state for the clauses and
      back in to the raise point's to re-raise. Two knock-on changes:
      `parameterize` no longer has a cleanup handler (leaving the frames up is
      what keeps the raise point reconstructable — the enclosing guard restores
      them in one pass), and the expander emits an implicit
      `(else %paal-guard-no-match)` rather than the re-raise itself, since the
      re-raise now belongs to the machinery. See `docs/architecture.md` §
      The wind stack.

      This exposed a host bug, now **fixed upstream** by kaappi/kaappi#1991,
      closing kaappi/kaappi#1988. kaappi v0.22.0 answered `2` where R7RS
      requires `1`:

      ```scheme
      (define p (make-parameter 1))
      (guard (e (#t (p)))
        (parameterize ((p 2))
          (guard (e ((number? e) 'no-match)) (raise 'boom))))
      ```
      A guard that *declines* left its own dynamic environment in place, so the
      next guard out evaluated its clauses in the wrong one — also visible
      through `dynamic-wind`, whose `after` thunk ran after the outer clauses
      instead of before them. Both symptoms come from `compileGuard`
      evaluating the `cond` and escaping with its *value*, where R7RS escapes
      first and evaluates the clauses in the guard's continuation. Verified
      against a build of kaappi `main` @ 321da93a: all nine cases in the repro
      now agree with paal.

      Still not R7RS, and unchanged by this work: an unmatched `raise-continuable`
      is not resumable — the clauses run after the host stack has unwound, so
      there is no raise point to return a value to. `(list 'got
      (raise-continuable 'sym))` under a declining guard yields the outer
      handler's value rather than `(got …)`. kaappi behaves the same way, and
      closing it does need re-entrant continuations.

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
- [x] `(scheme complex)` — the R7RS procedures restricted to the real line:
      every number is its own real part with a zero imaginary part.
      `make-rectangular`/`make-polar` error on a non-zero imaginary component
      rather than silently dropping it. Paal has no complex type — that is
      Phase 8's bignum/rational/complex item — but portable code calls these
      unconditionally, so having them is what matters.
- [x] `(scheme r5rs)` — `exact->inexact` and `inexact->exact`, the only two
      names R7RS renamed. Everything else R5RS specifies is already present
      under an unchanged name.
- [x] `(scheme eval)` — `eval` and `environment`. `eval` compiles the datum it
      is handed and runs it in the given table; the bindings read that table
      out of a cell rather than closing over it, since it does not exist when
      the alist holding them is built. They use the HOST pipeline even under
      self-hosting: reaching the loaded one means passing source *text*, and
      eval's argument is a datum — writing it back out to re-read would lose
      every object in it that has no read syntax. `environment` ignores its
      import specs and yields a full fresh table; honouring them needs the
      module system to build a table rather than splice.
- [x] `(scheme load)` — `load`, into the current table or a given one.
- [x] `(scheme repl)` — `interaction-environment`, the running program's own table.

---

## Phase 3 — Reader Completeness

Gaps in `lib/kaappi/paal/reader.sld`:

- [x] `#u8(...)` bytevector literals (e.g. `#u8(1 2 3)`)
- [x] `#e` / `#i` exactness prefix on numeric literals (`#e1.5` → exact 3/2)
      — already present; this entry was stale
- [x] Datum labels `#N=` / `#N#` — shared *and* circular structure. A reference
      inside the datum that defines it cannot be resolved when it is read, so
      `#N=` registers a placeholder, reads the datum, then walks it replacing
      the placeholder with the finished datum — which is what makes
      `'#0=(a b . #0#)` a real circular list rather than one holding a marker.
      The walk carries a `seen` list, since the structure is circular by then.
      References *after* a definition resolve on the spot, so only pairs and
      vectors are walked; an unresolved reference is necessarily an element of
      one. Labels are scoped to the outermost datum, which is exactly one
      `paal-read` call. Redefining a label inside one datum lets the later
      definition win, matching kaappi — R7RS leaves it undefined, and rejecting
      it would refuse programs kaappi accepts.

      A circular constant survives the `.pbc` round trip for free: kaappi's
      `write` already emits `#0=` for cycles, and the reader now understands
      what it wrote.

---

## Phase 4 — CLI Parity with kaappi

- [x] **Script args forwarding** — `paal file.scm arg1 arg2` sets `(command-line)`
      to `("file.scm" "arg1" "arg2")` inside user programs via HOST lambda in globals
- [x] **`--lib-path <dir>`** — repeatable, consumed before the subcommand.
      Directories are searched in the order given, after the default `.`.
      Works on both pipelines. The self-hosted path loads a second copy of
      the expander with its own `%paal-lib-paths`, so the paths are replayed
      into it after the pipeline is loaded.
- [x] **`check` subcommand** — `paal check <file>...` reads, expands, analyzes and
      *emits*, then throws the bytecode away. Emitting rather than stopping at
      the IR is the point: register allocation and upvalue resolution happen
      there, so stopping earlier would miss the errors a user is least likely to
      have anticipated. Nothing runs, so a file with side effects is safe to
      check. Every file is checked rather than stopping at the first failure, so
      one run reports every broken file in a tree; diagnostics go to stderr and
      the exit status is 1 if any file failed. Each file gets a fresh macro
      table, so a `define-syntax` in one cannot silently satisfy a reference in
      the next.
- [x] **`fmt` subcommand** — `paal fmt <file>...` reprints with canonical
      2-space indentation; `paal fmt --check` reports files that are not
      already formatted and exits 1, for CI. It cannot use `paal-read` —
      the reader discards comments, and a formatter that drops them is worse
      than none — so it has its own scanner producing a tree that keeps
      comments and blank lines as nodes beside the code. Strings and
      characters are scanned whole and never reflowed.

      A form that fits goes on one line. One that does not indents 2 from the
      open paren for special forms and aligns under the first argument for
      calls, which is the usual Scheme convention. A comment with code before
      it on the same line stays there; runs of blank lines collapse to one.

      The property that matters is that formatting never changes what the
      reader sees. That is asserted per case in the suite, and verified across
      all 18 of paal's own source files — reader-equal and idempotent for
      every one, including the ~1500-line expander.
- [x] **Bytecode cache for user programs** — `paal --cache file.scm` writes
      `file.scm.<hash>.pbc` beside the source and reuses it while the source is
      unchanged. Opt-in, because R7RS has no way to create a directory, so the
      cache file has nowhere to go but the user's tree — and a run of their
      program should not put it there unasked. The hash is in the *name*, so a
      hit is an existence check and an edit simply misses rather than needing
      the stale entry detected; the cost is that old entries accumulate, and
      paal never removes them because it cannot tell its own leavings from a
      `.pbc` compiled on purpose. `pkaappi-cache-path` names the current entry
      so a caller can clean up.

---

## Phase 5 — Module System

`import` and `export` both expand to `(quote #f)` — they are no-ops. Real library
resolution is needed before `--lib-path` or SRFI imports can work.

- [x] **Real `import` resolution** — `(foo bar)` → `foo/bar.sld`, searched along
      `--lib-path` after `.`. Paal links libraries **statically**: the library
      is expanded, its top-level definitions renamed to names unique to it, and
      the result spliced in front of the importing program, which then gets the
      imported names as aliases of the renamed ones. That matches paal's flat
      globals, and matches where the binary is going anyway — a bundled `paal`
      carries its libraries with it.
- [x] **Real `export` filtering** — a consequence of the renaming rather than a
      separate mechanism: an unexported name exists only under its mangled
      name, which nothing outside ever aliases. `(export (rename internal
      external))` works too.
- [x] **Selective import forms** — `only`, `except`, `rename`, `prefix`. Each
      wraps a nested spec and transforms the alias list, so they compose in any
      order: `(prefix (only (m math) square) x:)` is fine. `only`/`except`
      naming a binding the library does not export is an error.
- [x] **`cond-expand` feature list** — `paal`, `kaappi`, `r7rs`, `scheme`.
      `kaappi` is included because paal targets the same language: a library
      guarded by `(cond-expand (kaappi ...))` is written against primitives paal
      also provides, and excluding ourselves would take such code down a
      portable-fallback path for no reason.
- [x] **Circular import detection** — a load-in-progress list; a cycle reports
      the chain rather than looping.

---

## Phase 6 — Standalone Binary

`make binary` compiles `src/main.scm` to `.sbc` and bundles it into **kaappi's
own runtime** with `zig build -Dbundle=`. The product is kaappi with paal
embedded, which changes what this phase is: the primitives are already in the
binary, so there is nothing to reimplement.

Verified against a freshly built binary run from an unrelated directory, with
no `cache/` and no `lib/` present — all of the following are observed, not
inferred:

| | |
|---|---|
| `paal p.scm` | works — the HOST pipeline is compiled in, so no cache is needed |
| `paal eval '(* 6 7)'` | works |
| `paal version` | works |
| `paal` (no args) | works — REPL over the HOST pipeline, definitions accumulate |
| `(import (srfi 1))` | works — the SRFI sources are embedded |
| `paal check f.scm` | **runs the program** — kaappi/kaappi#2010 |
| `paal fmt --check f.scm` | same |

- [x] **Self-contained primitive env** — nothing to do. The entry assumed the
      binary would need its own implementations of what `paal-initial-env`
      borrows from the host; it does not, because the host *is* the binary.
      That assumption was the stated gate on the rest of this phase.
- [x] **`prog-args` discarded the user's program** — `prog-args` stripped the
      first argument whenever it ended in `.scm`. Right in bootstrap mode,
      where argv is `("src/main.scm" "p.scm")`, but a bundled binary gets just
      `("p.scm")` and lost it, then started the REPL. The symptom was
      `repl requires cache`, which reads like a missing cache and is not. Now
      matched against `main.scm` specifically.
- [ ] **`check` and `fmt` are unreachable in a bundled binary** — **blocked
      upstream** by kaappi/kaappi#2010. A `-Dbundle` binary silently consumes
      an argument that collides with one of kaappi's own subcommand names, so
      `paal check f.scm` delivers `("f.scm")` and paal's dispatcher treats it
      as a positional file and runs it. `check`, `fmt`, `ast` and `compile` are
      swallowed; `eval`, `repl`, `run` and any non-subcommand word pass through
      intact, which is what shows it to be unintended.

      Not workable around from paal's side: the argument is gone before paal
      starts, and a swallowed `check` is indistinguishable from never having
      been typed. Flag spellings do not help — kaappi's CLI intercepts those
      too. Bootstrap mode is unaffected, so `kaappi src/main.scm check f.scm`
      is correct today.

- [x] **Bundle the SRFI libraries** — all ten are embedded as source in
      `(kaappi paal embedded)`, which the expander consults *before* the
      search path, so a file on disk cannot shadow a bundled library — that
      would make a binary's behaviour depend on its working directory, which
      is the thing bundling exists to avoid. Verified with `lib/srfi/` removed
      entirely: `(import (srfi 1))` still resolves.

      Confirmed in a bundled binary, not only by removing `lib/srfi/`:
      `paal emb.scm` from an unrelated directory resolves `(srfi 1)` and
      `(srfi 13)` and runs.

      `make embed-srfi` regenerates it, and `make binary` runs the generator
      first so a binary can never ship libraries that differ from
      `lib/srfi/`. The file is committed rather than built on demand, so a
      fresh checkout works without the generator having run and so the diff
      shows when a bundled library changes.
- [ ] **Bundle pipeline `.pbc` files** — not needed for correctness now that
      the HOST fallback is compiled in, but the self-hosted path is the faster
      one and is unavailable without `cache/`.
- [x] **Standalone REPL** — a bundled binary run outside the repo has neither
      the cache nor paal's sources, and `pkaappi-self-repl` errored out with
      `repl requires cache`, leaving the standalone binary with no REPL at
      all. It now falls back to a REPL over the HOST pipeline, which is
      compiled into the binary regardless — not the self-hosted one, but a
      working REPL. Definitions accumulate in one globals table, and each
      input is guarded so a raise ends that expression rather than the
      session.
- [x] **Distribution strategy** — **a single binary, no lib directory.** The
      choice is settled by what a bundled `paal` now does rather than by
      preference: run from an unrelated directory with no `cache/` and no
      `lib/`, it runs programs, evaluates expressions, resolves the bundled
      SRFIs, and gives a REPL. Nothing it needs is on disk.

      The binary is 3.3 MB, against 388 KB for `lib/` and 300 KB for
      `cache/`. Shipping those alongside would trade a 20% size saving for a
      binary whose behaviour depends on its working directory — which is
      exactly the failure the embedded-library lookup was written to avoid,
      and the failure mode is silent (a stale `lib/` on the path shadowing
      what the binary was built with).

      What remains for a release is packaging, not design: the binary is the
      artifact. Bundling `cache/*.pbc` (below) would make it faster, not more
      self-contained.

---

## Phase 7 — SRFI Ecosystem

Bundled under `lib/srfi/`, reachable because `lib` is on the default search
path. Each is portable R7RS, so the same file runs on kaappi unchanged. None
redefines a name `(scheme base)` already binds compatibly — importing both
would otherwise bind one identifier two ways, which R7RS 5.2 makes an error.

- [x] SRFI 1 — list library. Folds (incl. multi-list), filter/remove/partition,
      find/any/every returning the predicate's value, take/drop and the
      right-hand variants, delete-duplicates, lset operations, and the
      proper/circular/dotted predicates via a two-pointer walk.
- [x] SRFI 13 — string library. take/drop, pad, trim, prefix/suffix, index
      (char *or* predicate), contains, join/split/tokenize, fold, filter.
- [x] SRFI 9 — import path for the core `define-record-type`.
- [x] SRFI 23 — import path for `error`.
- [x] SRFI 64 — test framework. Test forms, grouping, `test-skip` /
      `test-expect-fail`, and the result counters. The assertions are *syntax*,
      not procedures: a procedural `(test-equal expected actual)` evaluates
      `actual` at the call site, so a raise escapes before the framework sees
      it and takes the rest of the group with it — the failure mode
      `(kaappi test)` had. Not implemented: `test-apply`,
      `test-with-runner`, custom runners.
- [x] SRFI 39 — import path for `make-parameter`/`parameterize`. SRFI 39 also
      permits `(p v)` to set a parameter, which R7RS dropped and paal does not
      support.
- [x] SRFI 28 / SRFI 48 — `format`. 48 adds radix, character and recursive
      directives, and accepts a leading port or `#f`/`#t`.
- [x] SRFI 69 — hash tables. Separate chaining, doubling past a 0.75 load
      factor. The table is an interned-symbol-tagged vector, not a record, so
      it survives the HOST/self-hosted boundary.
- [x] SRFI 133 — vector library. fold/reduce, index/skip/any/every, binary
      search, reverse, concatenate, tabulate, partition.

---

## Phase 8 — Advanced Features (Long-Term)

Requires significant new infrastructure; no fixed timeline.

- [x] **`(scheme eval)` / `eval`** — done in Phase 2.
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
      `paal file.scm` takes. The globals are populated by the HOST
      `pkaappi-make-globals` but consumed by the paal-compiled VM, and
      `define-record-type` cannot express a value both copies recognize: HOST
      kaappi makes an opaque native record, while paal's expander makes a vector
      tagged with a freshly allocated `(list '<name>)` pair. `<closure>` and
      `<bytecode-function>` are now vectors tagged with interned symbols, so both
      copies agree. No measurable cost on the call hot path. See
      `docs/architecture.md` § Values that cross the HOST boundary.
- [x] **`.pbc` files could not use paal-compiled globals** — `pkaappi-run-pbc-file`
      built its globals from a bare `paal-initial-env` blob, so `paal file.pbc`
      failed with `type error in 'map': expected procedure`. Now uses
      `pkaappi-make-globals` like the other entry points. Pre-existing and separate
      from #1; surfaced by the new `hof.scm` fixture.
- [x] **Macros leaked between independent programs** — `%paal-macros` is module
      state in the expander and was never reset, so a `define-syntax` in one
      program stayed installed for the next and silently shadowed a procedure of
      the same name there. Reset now happens wherever a fresh globals table is
      created, giving macros the same lifetime as the definitions they sit
      alongside. `pkaappi-load-file` and `pkaappi-run-string-in` add to an
      existing table and deliberately do not reset, so a loaded file's macros
      stay visible and the REPL still accumulates them across inputs.
- [x] **Test suite silently skipped tests and exited nonzero** — an uncaught error
      aborted the rest of its `test-group` without counting the remaining tests, so
      `make test` reported "all passed" while exiting 1 and running 10 fewer tests
      than it appeared to. Both underlying causes (`#u8`, `call-with-values`) are
      fixed, and so is the reporting weakness itself: `(kaappi test)`'s assertions
      are now syntax that thunk the expression, so a raise fails that one test and
      the run continues (kaappi-test `d67855a`). The pass count is a trustworthy
      signal again — a green run no longer hides skipped tests.

**Open:**

- [x] **A macro template can name a library's private binding** — both
      directions of one problem, now closed. A template names things by their
      original name, so renaming a library's bindings means rewriting the
      templates that reach them. The `syntax-rules` spec is kept beside the
      transformer, which is otherwise a closure over its rules, and
      `install-library!` rebuilds each of the library's macros with the rename
      map applied — pattern variables and clause literals excluded, since
      those names come from the use site.

      So an exported macro whose template calls a private helper works, and an
      unexported macro is renamed along with the private values and is no
      longer reachable from the importer. SRFI 64 was the motivating case: its
      assertions expand to `%compare`, and it had to export the helpers to
      work. It no longer does, and that export list is back to what SRFI 64
      specifies.

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
