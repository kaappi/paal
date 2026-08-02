# paal Compatibility TODO

Goal: make `paal` a correct R7RS-small Scheme implementation that runs the
same programs as `kaappi`, with the same CLI conventions.

Current: bootstrap stage 6 complete (self-hosting). **671 tests pass** (was 194 before Phase 1–2).

Phases 1–6 are done. Two of their entries rest on host bugs still open upstream —
kaappi/kaappi#2010 and kaappi/kaappi#1920 / kaappi/kaappi#2043 — but paal has no
exposure to either left, so both are recorded as worked around rather than as work
outstanding. What each entry says about *why* is the point of keeping them; several
correct an earlier premise that turned out to be false, and those are worth more
than the checkbox.

**Phase 7 is done too, and is the one worth reading.** Everything above it was written
from the inside: it tracked what paal's authors knew was missing. Running kaappi's R7RS
suite against paal — which had never been done — found a class of defect that kind of
list cannot contain, because nobody suspected it. `(values 1)` returned a tagged pair.
`(procedure? f)` was `#f` for every procedure paal defines. `(map + '(1 2) '(3 4) '(5 6))`
answered `(4 6)`. `(environment …)` destroyed the caller's macro table. None of those
raise; they return a plausible wrong value.

The suite went from **974 passing / 131 failing to 1174 / 24**, and now gates `make test`
as a ratchet, so those numbers cannot move in either direction without someone deciding
they should.

Three R7RS gaps remain, recorded here rather than as checkboxes because each is a
decision rather than an oversight — see the end of Phase 7 for the reasons: §4.3's
keyword-shadowing cases, the `(scheme …)` libraries being one flat table, and §6.2's
one residual failure, `(real? -2.5+0.0i)`, which needs a value the host runtime
cannot represent.

---

## Phase 1 — R7RS Language Core ✅

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

**Known limitations — both since closed:**

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

      Still not R7RS, and deliberately so: an unmatched `raise-continuable`
      is not resumable — the clauses run after the host stack has unwound, so
      there is no raise point to return a value to. `(list 'got
      (raise-continuable 'sym))` under a declining guard yields the outer
      handler's value rather than `(got …)`. kaappi behaves the same way, so
      fixing it unilaterally would break three-way agreement for a corner no
      suite tests. The machinery to close it now exists, though: since the
      bytecode VM gained continuations, the sketch is for `run-guard!` to
      capture a body-loop continuation at the raise point and for its retry
      to resume it — the `%paal-vm-cont-invoke` escape protocol is the base.

---

## Phase 2 — Standard Libraries in User Environment ✅

User programs call `(import (scheme inexact))` etc. This phase put the procedures
in `paal-initial-env`, which is a flat unnamespaced blob, so at the time it was
written `import` was still a no-op and the entries below meant "present, but not
reachable by importing them". Phase 5 built real import resolution; the two read
together now.

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
- [x] `(scheme complex)` — kaappi's, bound directly. This was first
      implemented here as the R7RS procedures restricted to the real line, on
      the assumption that paal would need its own complex type. It does not:
      paal runs on kaappi's runtime, which carries the full numeric tower.
      `(make-rectangular 1 2)` is `1+2i`, `(sqrt -1)` is `+i`, `(* 2+3i 2)`
      works, and complex literals read because paal's reader parses them
      itself — see the §6.2 note at the end of Phase 7 for why
      `string->number` could not be deferred to here.
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
      into it after the pipeline is loaded — from all six pipeline-load sites
      now; three of them were missing the replay, which is why `paal compile`
      and the REPL ignored it. Not honoured in a `make binary` build, where
      kaappi's CLI takes the flag before paal starts — see Phase 6.
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
| `paal debug f.scm` | works — `debug` is not a kaappi subcommand |
| `paal check f.scm` | **runs the program** — kaappi/kaappi#2010 |
| `paal fmt --check f.scm` | same |
| `paal compile/expand/ir f.scm` | same |
| `paal --lib-path d f.scm` | **path never reaches paal** — same bug |
| `paal --help` | prints **kaappi's** usage |
| `paal do check f.scm` | works — `do` shields everything after it |
| `paal do fmt --check f.scm` | works |
| `paal do compile f.scm -o o.pbc` | works |
| `paal do --lib-path d f.scm` | works — imports resolve from `d` |
| `paal do --cache f.scm` | works |
| `paal help` | prints paal's usage |

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
- [x] **A bundled binary loses every argument kaappi's own CLI claims** —
      **worked around**; the upstream bug is kaappi/kaappi#2010 and is still
      open, but nothing of paal's is unreachable any more. A `-Dbundle` binary
      consumes
      an argument that collides with one of kaappi's subcommand or option
      names, so `paal check f.scm` delivers `("f.scm")` and paal's dispatcher
      treats it as a positional file and runs it.

      The rule is simply *every name kaappi's CLI recognizes*. Of paal's own
      subcommands that is `check`, `fmt`, `compile`, `expand` and `ir`; of its
      options, `--lib-path`, `--profile` and `--coverage` are consumed,
      `--help`/`-h` and `--version` answer as kaappi, and `--cache` is
      rejected as an unknown kaappi option. `debug`, `eval`, `repl`, `run` and
      `version` survive because kaappi has no such name — which is the check
      to run before naming any future subcommand.

      **`--lib-path` is the consequential one**, not `check`. It takes its
      *value* with it — a minimal bundled program run as `avbin --lib-path
      z.scm` receives `()`, not a shortened list it might notice — so a
      bundled paal cannot add a library search directory at all, and
      `paal --lib-path d prog.scm` reports `library not found ((m util)
      "m/util.sld" ("." "lib"))`. Imports work only from `.`, `lib/`, or the
      embedded SRFI sources.

      And the option namespace is closed outright, not merely contended:
      `--cache` is not a kaappi option and not a collision, yet kaappi refuses
      the run with `unknown option: --cache` before paal starts. A bundled
      program cannot introduce an option of its own at all. Verified with a
      four-line repro carrying no paal in it, and reported upstream.

      Two earlier claims in this entry were wrong and are corrected above.
      `ast` was listed among paal's swallowed subcommands — it is kaappi's,
      and paal has none. And "`eval`, `repl`, `run` … pass through, which is
      what shows it to be unintended" was not evidence of anything: those are
      not kaappi subcommands either, so there was no inconsistency to point
      at. The argument for it being unintended is simpler — with bytecode
      bundled, the binary *is* the bundled program, so the argument vector
      belongs to that program.

      **The workaround: `paal do <anything…>`.** kaappi inspects only the
      *first* argument, so one word it does not recognize, in front, shields
      everything after it. Verified against a bundled binary — `do --lib-path
      d z.scm` arrives whole, as do `do check f.scm`, `do --cache f.scm` and
      `do --help`. `paal do` re-enters paal's own dispatcher with the rest,
      and is a no-op in bootstrap mode, where nothing was being consumed.

      One escape hatch rather than an alias per subcommand: aliases would have
      to be invented for `check`, `fmt`, `compile`, `expand` and `ir`, would
      not help the options at all, and would outlive the bug as names users
      had adopted. `do` covers the options too, and every subcommand paal has
      not written yet, and comes out in one piece when kaappi#2010 is fixed.
      Bare `help` is accepted alongside `--help`/`-h` for the same reason.

      This entry previously said the collision was not workable around from
      paal's side, on the grounds that the argument is gone before paal
      starts. True of the argument kaappi claims — and irrelevant, since paal
      chooses which argument that is. Bootstrap mode was unaffected
      throughout, so `kaappi src/main.scm check f.scm` was always correct.

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
- [x] **Bundle pipeline `.pbc` files** — **not worth doing; the premise is
      backwards.** The entry assumed the self-hosted path is the faster one and
      that a binary without `cache/` is missing something. Measured, on the
      same file (`tests/fixtures/hof.scm`):

      | path | time |
      |---|---|
      | bundled binary, no cache — HOST pipeline fallback | **0.17 s** |
      | cache-backed self-hosted path | **10.06 s** |

      59× slower. Loading nine `.pbc` files through the VM costs far more than
      compiling the program with the HOST pipeline that is already inside the
      binary. Embedding the cache would make `paal` dramatically slower at
      every invocation, not faster.

      The cost of embedding is real too: `cache/*.pbc` is 281 KB against the
      51 KB `embedded.sld` already carries, and `(kaappi paal embedded)` is
      imported by the expander, so it is parsed on *every* run — including the
      0.17 s path this would be slowing down.

      The self-hosted path earns its keep by proving paal compiles itself, not
      by being fast. Nothing about the binary needs it.
- [x] **Stepping debugger** — `paal debug <file>`. Breakpoints by procedure
      name, `step` / `next` / `finish` / `continue`, a backtrace naming every
      live frame with the arguments it was called with, and `p <name>` to read
      a top-level binding.

      Two halves. The VM raises an event wherever the frame stack changes
      shape and asks a hook what to do next; the hook is handed **data only**
      — kind, name, value, depth, backtrace — so it cannot disturb the run it
      is watching, and the test suite drives the whole thing with a procedure
      returning a scripted list of commands rather than needing a terminal.
      The console half is one such hook.

      Three event sites, not two: a `return` instruction is not the only way
      out of a frame. A procedure whose body ends in a call to a primitive
      leaves through `deliver-result!`, and for a program written entirely in
      tail position that is *every* return it makes — hooking only the opcode
      showed none of them.

      `next` and `finish` measure depth as the frame's register base rather
      than the length of the frame list, because a re-entrant
      `paal-call-value` (a `guard` body) runs on a fresh singleton list, and
      comparing lengths made `next` stop at the first event inside it. Bases
      keep growing across the boundary; list lengths restart.

      Stepping skips the `map`/`filter`/`apply` blob `pkaappi-make-globals`
      installs, by closure identity rather than by name — so an anonymous
      lambda handed to `map` still stops, which keying on names could not have
      given.

      No `up`/`down`: selecting a frame is only useful if something can be
      evaluated in it, and registers carry no variable names by the time the
      emitter is done, so nothing can answer "what is `x` here". Arguments are
      recoverable — they are `regs[base … base+arity]` — and `bt` prints them
      for every frame at once. See `docs/architecture.md` § The stepping
      debugger.
- [x] **C FFI** — bound, not built. `(kaappi ffi)`'s seven primitives
      (`ffi-open`, `ffi-fn`, `ffi-close`, `ffi-callback`,
      `ffi-callback-release`, `ffi-callback?`, `ffi-bytevector-ptr`) are now in
      `paal-initial-env`. The binding is the procedure *object*, not a
      signature, so kaappi keeps enforcing arity — there was nothing here to
      get wrong, which is why the earlier worry about arities was misplaced.
- [x] **Fibers / concurrency** — same: `spawn`, `yield`, `fiber-join`,
      `fiber?`, the six channel procedures, and `processor-count` are bound.
      Channels take values, so they cross the HOST boundary intact and work on
      both pipelines — `(channel-send c 42)` then `(channel-receive c)`
      round-trips.

      **`spawn` and `ffi-callback` do not work from the bytecode path.** They
      take a procedure, and a paal closure there is a tagged vector HOST code
      cannot enter — the same boundary that made `dynamic-wind` and
      `call-with-input-file` fail. Both work on the tree-walking path, where
      closures *are* HOST procedures. Making them work under bytecode needs the
      VM-marker treatment `guard` and `apply` got: recognise the callee in
      `do-call!` and re-enter the dispatch loop for the callback.
- [x] **Native backend** — **resolved as already decided, not built.** This
      entry contradicted the "Not planned" section below, which records LLVM
      native code generation as deliberately out of scope because paal targets
      its own bytecode VM. The same capability cannot be both a TODO and a
      declared non-goal; the non-goal is the considered position and this
      entry was a leftover.

      Worth noting that a bundled `paal` *is* kaappi, so kaappi's own
      `compile <file>` (native, via LLVM) is already in the binary. Exposing
      it would mean paal delegating to kaappi's pipeline rather than its own,
      which is a different thing from paal having a native backend and is not
      obviously wanted. If it ever is, it belongs in the CLI section as a
      delegation, not here as code generation.
- [x] **GC** — nothing to do, for the same reason the self-contained primitive
      environment turned out to be nothing to do: `make binary` bundles paal
      into kaappi's runtime, so paal's binary already has kaappi's
      mark-and-sweep collector. Verified against a bundled binary run outside
      the repo — 300,000 vector allocations complete, which is far past any
      plausible heap if nothing were being collected.

      A collector only becomes paal's problem if paal ever stops building on
      kaappi's runtime. That is not the current design and is not on this
      list; the entry described a future that the `-Dbundle` approach does not
      lead to.
- [x] **Bignum / rationals** — already work, and always did. `paal-initial-env`
      maps `+`, `*`, `/`, `expt`, `quotient` and the rest onto kaappi's numeric
      primitives, which carry the full numeric tower, so paal inherited it
      without anyone writing it down. Verified in a bundled binary:
      `(expt 2 100)` gives the exact 31-digit value, `(* (expt 10 30) (expt 10
      30))` the exact 61-digit one, `(+ 1/3 1/6)` gives `1/2`, and
      `numerator`/`exact`/`exact->inexact` behave across both.

      Complex works too, for the same reason — see the `(scheme complex)`
      entry in Phase 2. The whole numeric tower came free with the runtime.

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
- [x] **The bundled binary's REPL echoed definitions** — `(define q 9)` printed
      `9`. Paal has three REPL routes (cached pipeline, `.sld` pipeline, and a
      HOST fallback for a binary that has neither), and only the fallback was
      wrong: it suppressed the echo when the result was the unspecified value,
      but a paal `define` evaluates to the thing defined. The other two decide
      from the *form*, which is the right test, and the fallback now shares it.
      Only the binary was affected, since the fallback is unreachable inside a
      checkout — which is also why the new test covers whichever of the other
      two routes the checkout has rather than this one.
- [x] **The self-hosted path could not resolve any import** — `paal file.scm`
      in a checkout with a built cache failed on every non-builtin import,
      `(srfi 1)` included, with `unbound variable paal-embedded-source`. The
      loaded expander resolves imports through `paal-embedded-source`, which
      lives in `(kaappi paal embedded)` — a library outside the pipeline, so
      it is in neither `cache/*.pbc` nor `%paal-lib-files` and was never
      defined in the table the loaded pipeline runs against. A regression from
      bundling the SRFI sources: before that, `load-library!` went straight to
      the search path.

      Fixed by installing the HOST `paal-embedded-source` into the table after
      the pipeline loads. That is what the boundary allows — it takes a
      library name and returns source text, both plain data, exactly like the
      HOST `command-line` already there — and it avoids pushing 1300 lines of
      embedded SRFI source through the pipeline on every run to reach one
      procedure. The same helper now also replays `--lib-path`, which three of
      the six pipeline-load sites were missing, so `paal compile` and the REPL
      honour it as `paal run` already did.

      Nothing caught this because every module-system test runs the HOST
      pipeline; two tests now run an import through each self-hosted entry
      point.
- [x] **Test suite silently skipped tests and exited nonzero** — an uncaught error
      aborted the rest of its `test-group` without counting the remaining tests, so
      `make test` reported "all passed" while exiting 1 and running 10 fewer tests
      than it appeared to. Both underlying causes (`#u8`, `call-with-values`) are
      fixed, and so is the reporting weakness itself: `(kaappi test)`'s assertions
      are now syntax that thunk the expression, so a raise fails that one test and
      the run continues (kaappi-test `d67855a`). The pass count is a trustworthy
      signal again — a green run no longer hides skipped tests.

**Closed since, and left here for the reasoning:**

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

- [x] **Source and `.pbc` files misread depending on byte offsets**
      (kaappi/kaappi#1920, kaappi/kaappi#2043) — kaappi's `read` on a *file
      port* mis-handles a dotted
      pair that straddles a 4096-byte chunk boundary: a truncated prefix reports
      `UnexpectedChar`/`DotNotInList` instead of `UnexpectedEof`, and the
      incremental read loop treats that as fatal rather than reading the next
      chunk. `.pbc` files are full of `(#t . N)` upvalue specs, so a large enough
      one eventually lands on a boundary. It hit `cache/paal-vm-bc.pbc` when the
      guard logic was inlined into `do-call!`, breaking `make pbc-pipeline`.
      **Worked around in paal, everywhere it can bite.** `paal-read-bc-file`
      slurps the file and parses from a string port, where no chunk boundary
      exists. Splitting `run-guard!` back out was never a real defence — it
      only shifted byte offsets. NB the earlier "large and deeply nested"
      diagnosis in this entry was wrong: `paal-expander.pbc` is both bigger
      and deeper and reads back fine.

      Re-checked against v0.22.1, and the boundary drops more than dotted
      pairs. Two further constructs, now **kaappi/kaappi#2043**: a `;` line
      comment straddling the boundary has its tail returned *as data* — no
      error, just datums the file does not contain — and a string literal
      straddling it raises `read error`. Both reproduce on v0.22.0 and
      v0.22.1 with a Scheme-only repro and no paal in it, and both read
      correctly from a string port.

      Which turned out to be live in paal, not merely upstream: the expander
      read `include`d files and every `.sld` the module system resolves
      straight off a file port. A file whose comment straddled byte 4096 was
      *silently corrupted* — `(include "data.scm")` failed with
      `unbound variable that`, the words after the boundary having been
      spliced in as code. The same slurp now covers that path, and the
      regression test generates the file rather than committing one, because
      the property is about byte offsets and a committed fixture would stop
      testing anything the moment someone reflowed it.

      Paal has no HOST `read` on a file port left. Its own reader was never
      exposed: it works in `read-char`/`peek-char` over the port rather than
      calling kaappi's `read`, and returns the correct datums for a file where
      kaappi's `read` returns two extra. Closed here because paal's exposure
      is closed; the host bug is tracked in its own two issues rather than as
      a paal TODO.

---

## Phase 7 — R7RS correctness and conformance

Everything above was found by looking. This phase is what an outside oracle found.

- [x] **A conformance harness** — `make test-r7rs`, gating in `make test`.
      kaappi's 2516-line R7RS suite, vendored under `tests/r7rs/` and driven
      **one top-level form at a time**. Form-by-form is not a nicety: paal is a
      whole-program compiler, so one unsupported form anywhere means *zero*
      tests run — `paal check` on the suite dies outright. And the harness runs
      the HOST bytecode pipeline in process because shelling out to
      `paal file.scm` is ~500× slower (163 s against 0.30 s on a 59-line
      excerpt). The whole suite takes about 1.5 s.

      It is a **ratchet, not a gate**: paal does not pass the suite, and what CI
      enforces is that the per-section counts do not move — in either direction,
      so a new failure cannot hide behind a new pass in the same section.
      `make r7rs-baseline` prints a replacement baseline; the diff of that
      refresh is the evidence a fix did what it claimed. Baseline when it landed:
      974 passing, 131 failing across 19 sections, plus 12 top-level forms that
      raise before any test inside them runs. One line of Phase 7 moved that to
      **1078/30** with 11 raising, which is the harness paying for itself.

      See `tests/r7rs/README.md`.
- [x] **`environment` destroyed the caller's macro table** — there is one macro
      table for the whole expander, and `environment` built its nested table
      through `pkaappi-make-globals`, which resets it. Every `define-syntax`
      before an `(environment ...)` call became an unbound variable after it.

      Invisible under whole-program compilation, where expansion finishes
      before anything runs, and invisible in the cached REPL, where the reset
      lands on the HOST expander while the REPL expands through the loaded one.
      Plain wherever forms are expanded and run one at a time — the first thing
      the harness hit. §6.12's `(environment '(scheme base))` took out
      `(chibi test)`'s `test` macro and darkened the remaining **292 forms** of
      the suite, a quarter of it.

      `environment` now uses `%make-globals-table`, the same builder without the
      reset. `pkaappi-make-globals` keeps the reset: a fresh table there really
      does start a fresh program.

Open, and ordered. Each is a leaf edit — one function or one blob entry, changing
no value representation and no cross-copy protocol — so they can land in any order.

- [x] **`(values x)` must be `x`** — a single value leaks the MVR tag as
      `((paal-mvr) 1)`, so `(+ (values 1) 2)` was a type error and
      `(list (values 'a))` returned the tag. R7RS 6.10 says a call to `values`
      with one argument is equivalent to the argument itself.

      One line, and the largest single win available. The suite went from
      **974/131 to 1078/30**: Numeric syntax alone from 121/99 to 220/0,
      because the reader's numeric round trip runs through it. `(values)` still
      tags — `(pair? '())` is `#f` — so zero values stays an MVR and
      `call-with-values` still applies the consumer to nothing.
- [x] **`procedure?` was `#f` for every paal-defined procedure** — and
      `(vector? f)` is `#t`. First-order wrong answer: every predicate dispatch
      on procedures was broken on the bytecode path. Fixed in the blob, keyed on
      the interned `%paal-closure` tag, which is `eq?` across both live copies.
      Safe because `do-call!` and `paal-call-value` both test `closure?` before
      `procedure?`, so a closure never reaches the `procedure?` arm.

      **`vector?` deliberately still says `#t` for a closure.** It is
      load-bearing for `closure?`, `bytecode-function?`, `promise?`,
      `paal-vm-escape?` and the wind-frame dispatch, and under self-hosting the
      paal-compiled `frame.sld` resolves it out of the *user program's* table —
      so overriding it there makes `closure?` return `#f` for every closure and
      every call report its callee is not callable. The leak is asserted in the
      suite so the trade-off is recorded rather than rediscovered.
- [x] **`map`/`for-each` capped at 2 lists, `vector-map`/`vector-for-each`/
      `string-map`/`string-for-each` at 1 sequence** — extras silently dropped,
      so `(map + '(1 2) '(3 4) '(5 6))` answered `(4 6)` and
      `(vector-map + #(1 2 3) #(4 5 6))` answered `#(1 2 3)`. All six are n-ary
      now and stop at the shortest sequence, per R7RS.

      The one-sequence arm of each stays inlined rather than delegating to the
      n-ary path: `map` is on paal's own hot path when self-hosting — the
      expander and emitter call it constantly — and that case must not pay an
      `apply`. Together with `procedure?`, §6.10 went from 26/8 to 29/5.

      Worth knowing for anyone editing the blob: it is a Scheme **string
      literal**, so a double quote anywhere inside it, comments included, ends
      the string and silently wrecks the rest of the library. That is what a
      `"not callable"` in a comment did while writing this.
- [x] **`case` with `=>` passed the `memv` result, not the key** — R7RS 4.2.1
      says the receiver gets the key. `expand-case` spliced the clause into a
      `cond`, and `cond`'s own `=>` passes the value its *test* produced, which
      here is `(memv k '(3))`. So `(case 3 ((3) => (lambda (x) (* x 2))))`
      multiplied the list `(3)`. The `=>` clauses are rewritten in
      `expand-case` now rather than routed through `cond`'s.
- [x] **`expand-body` did not splice a leading `begin`** — R7RS 5.3.2 puts
      definitions inside one at the head of a body. `cond-expand`, `include`
      and `include-ci` all expand to a `begin`, so all three failed with
      `ir:define in expression position`. They are expanded one step and
      spliced now, because `expand-body` walks *unexpanded* forms — at that
      point a `cond-expand` is still a `cond-expand`. §4.2 went 71/2 → 73/0.
      (Empty-binding `let*`/`let-values`/`let*-values` are fine; an earlier
      draft of this entry said otherwise.)

      **A macro producing a definition in a body is still not supported**,
      though R7RS 5.3.2 allows it. Expanding a macro use one step here was
      tried and reverted: it made `(let () (def x 2) x)` work, scored
      identically on the suite, and made the neighbouring shape *worse* — a
      template that introduces the name gets it marked `%gref%`, since paal
      treats a template's free identifiers as top-level references and does not
      recognize `define` in a template as a binding position, so the name
      became a `letrec*` binding the emitter still resolved as a global and the
      compile error became a runtime `set! on unbound variable`. Making both
      shapes work needs the hygiene model changed, not `expand-body`. Recorded
      as an expected error in the suite so it is not mistaken for working.
- [x] **`syntax-rules` mixed-depth ellipsis** — `find-ellipsis-vars` returned
      only the sub-template's variables and discarded the tail, so a variable
      appearing *after* the ellipsis in the same list was never bound per
      iteration: `((b ... a) ...)` reported "ellipsis variable used outside
      ellipsis template a". The tail belongs to the same iteration, so its
      variables are collected too, with the run of ellipses dropped first since
      that is depth rather than content. Checked against kaappi's answers on
      seven template shapes, and a variable used below its depth is still
      rejected — widening the search must not turn a depth mistake into a
      silent wrong answer.
- [x] **Six bytevector-port procedures were unbound**, and
      `scheme-report-environment` / `null-environment` with them. The first six
      take and return plain data, so they went into `paal-initial-env` and both
      pipelines have them; the two environment constructors need
      `%make-globals-table` itself, so they live in the
      `pkaappi-make-globals` alist and check their version argument, 5 being
      the only one R7RS defines.

      This is what unblocked §6.13 — which turned out to be running all along
      and reporting nothing, see below.
- [x] **`(features)` answered with kaappi's list**, which does not contain
      `paal`, while `cond-expand` answered from the expander's — two answers to
      the same question. One list now, owned by the expander and exported as
      `paal-feature-list`. It claims only what holds: `exact-closed`,
      `exact-complex`, `ieee-float` and `posix` are inherited from kaappi's
      runtime, which advertises exactly those; `full-unicode` and `ratios` are
      not in kaappi's list so paal does not claim them either.

      `cond-expand`'s `(library <name>)` requirement was also hard-wired to
      `#f`, so `(cond-expand ((library (srfi 1)) ...) (else ...))` always took
      the fallback with `(srfi 1)` right there. It consults the embedded
      sources and the search path now.
- [x] **`write` of a procedure dumped the whole closure vector** — pages of
      nested vectors, since a paal closure on the bytecode path carries its
      entire bytecode function. `write` and `display` recognize the two
      internal tags now and print `#<procedure name>` / `#<code name>`.

      Deliberately shallow: `(write (list f))` still shows the vector. Going
      deeper means a full R7RS writer in paal source — cycle detection, datum
      labels, string and character escaping — a second implementation to keep
      in step with kaappi's. Same call the debugger's `%debug-write` already
      makes.
- [x] **`call/cc` works on the bytecode path** — full re-entrant, multi-shot,
      as a VM marker in `do-call!` like `guard` and `apply` before it.
      Capture copies the live register prefix, the frame list as plain data,
      and the wind and handler stacks; invoke winds the dynamic extent across
      with the same `%paal-wind-out!`/`%paal-wind-in!` walk a declining guard
      uses, restores the handler stack by assignment, and rebuilds fresh
      frames per entry, so one continuation can be re-entered any number of
      times and a tail-position re-invoke grows nothing. §6.10 went 29/5 →
      34/0 and §6.11 21/3 → 30/0, with suite forms 878–880 no longer
      aborting. See `docs/architecture.md` § Continuations in the bytecode VM.

      The path here had three states, each honest in its day. First bound to
      the HOST `call/cc`, which type-errored on every paal closure — worse
      than absent, since `(procedure? call/cc)` said `#t` while calling it
      failed. Then **unbound**, so feature detection took the fallback branch
      correctly. An escape-only paal-source replacement was written between
      the two and reverted: its escapes had to pass `%paal-guard-catch`,
      which could not tell them from its own, and fixing that meant teaching
      the VM about continuations. That is exactly what the final design does
      — capture and invoke live in the dispatch loop, where no guard's
      clauses ever run, and the one escape it still uses
      (`%paal-vm-cont-invoke`, for an invoke crossing dispatch loops) is
      recognized and passed through by `run-guard!` itself.

      One documented limit, kaappi-parity in kind: a continuation belongs to
      the dispatch-loop episode that captured it. Invoked after its episode
      finished — a guard body that returned, a previous `eval` — it dies with
      `continuation invoked outside its dispatch extent`, deliberately past
      the program's own guards, the way kaappi's `KP3008` is uncatchable.
- [x] **`#!fold-case` / `#!no-fold-case`** — supported, and checked against
      kaappi's reader on every case. Folding applies to the symbol branch only:
      numbers are unaffected, a single-character literal is not folded (`#\A`
      stays `#\A`) but a character *name* is (`#\NEWLINE` reads). R7RS 2.1
      scopes the directive to the rest of the file, so `paal-read-all` resets it
      and `paal-read` deliberately does not — resetting per datum would make the
      directive apply to nothing but itself.

      Only program files go through paal's reader; `.sld` and `include`d files
      are read by HOST kaappi's `read`, which already honours both.
- [x] **`spawn` and `ffi-callback` cross the boundary** — the two primitives
      whose procedure argument is called *later*, from HOST code (the fiber
      scheduler, or C).  On the bytecode path each is a do-call! marker now:
      the arm wraps the paal closure in a HOST trampoline over
      `paal-call-value` and hands that to the raw primitive, kept in the
      table under a `%paal-host-` name.  Every trampoline entry allocates a
      fresh register file — a fiber body interleaves with its spawner, and
      sharing one file would let either side overwrite the other's live
      registers at the first yield — and gets its own dispatch-loop episode,
      so a continuation captured inside a fiber cannot be replayed outside
      it.  The markers answer `procedure?`, and that fix covered `apply` and
      `call/cc` too, which had quietly answered `#f` since becoming markers.

      Two documented limits.  The paal-compiled copy of the VM builds its
      trampoline as a paal closure again, so the *self-hosted* path keeps the
      boundary type error — same class of HOST-only limit as the debugger
      hooks.  And fiber switches interleave separate paal episodes over the
      one shared `'%paal-vm-loop` cell: `call/cc` captured in one fiber and
      chased across an interleaving is untested territory — the episode
      identity a fiber restores on exit is the one from its entry, which
      another fiber may have replaced since.
- [x] **The portable-SRFI shelf is vendored** — twenty-one libraries copied
      from kaappi's lib/srfi (2, 8, 11, 14, 26, 31, 35, 41, 42, 60, 64, 78,
      95, 111, 113, 117, 125, 128, 132, 141, 151, 158), each verified
      behaviourally against host kaappi, all embedded for standalone
      binaries.  The reference (srfi 64) replaced paal's subset — the count
      readers take the runner now, and the final test-end retires it.  Three
      files carry adaptations, recorded in their headers: 158's include is
      inlined (an embedded library cannot reach a filesystem), 125 unpacks
      its comparator (kaappi's native 69 absorbs one; paal's portable 69
      must be handed procedures), and 26 is rebuilt on a runtime parts list.

      Running real library code flushed out four paal bugs, each fixed and
      pinned in tests/test-paal.scm ("fixes flushed out by vendoring"):
      the emitter dropped the rest parameter from must-box-vars, so a
      captured and mutated one silently lost its set! (SRFI 158's
      generators); `force` stopped after one promise, where R7RS 7.3's
      reference chases chains (SRFI 41's stream-lambda); define-record-type
      rejected fields absent from the constructor, which R7RS 5.5 permits
      (Bothner's test-runner record); and rename-core did not follow a
      %gref% mark through a library rename, so a macro naming a library
      value broke when used inside its own library (SRFI 35's
      define-condition-type).

      One expander limitation surfaced with no in-scope fix: an identifier a
      template *introduces* in one expansion step and *binds* only in a
      later step — the reference cut threads its slot variable that way —
      needs per-identifier provenance.  Same boundary as the deferred §4.3
      torture cases below; the adapted (srfi 26) sidesteps it.

Deferred with reasons: R7RS §4.3's keyword-shadowing torture cases (variables
named `let`, `if`) need an environment threaded through every `expand-*`; and
§6.2 keeps exactly one failure, `(real? -2.5+0.0i)`, which R7RS says is `#f`
because the imaginary part is *inexact* zero. The host's `make-rectangular`
normalizes an inexact-zero imaginary part away — `(make-rectangular -2.5 0.0)`
*is* `-2.5` — so the value the test needs cannot exist in the runtime paal
delegates its numbers to. Same family as kaappi/kaappi#1911; two siblings —
eqv? conflating exact with inexact complex, and `(- z)` dropping exactness —
are fixed on kaappi main by kaappi/kaappi#2170, with the representation work
that would close this one tracked as kaappi/kaappi#2166. The main effect of
#1911 is closed here: the reader now parses complex literals itself, splitting the token
into real and imaginary parts — each a plain real, where `string->number` is
reliable and exactness survives — and reassembling with `make-rectangular`.
That is what `string->number` could not be trusted to do: it rejects `-3/2-i`,
`1/2+1/2i` and `3.0+inf.0i` outright and reads `1+2i` inexactly, where R7RS
6.2.5 requires the exact value.

---

## Phase 8 — Import scope

- [x] **`(import (scheme base))` was a no-op** — every `(scheme …)` name
      resolved to an empty export list against one flat globals table, so it
      also handed a program `sin`, `spawn` and `ffi-open`. A program could
      under-import and still run here while failing on a conforming
      implementation, which is the worst way to be wrong: silently portable-
      looking.

      **Emitting aliases cannot fix it**, which is where the original sketch
      for this went. The table already holds every primitive under its public
      name, so `(define sin sin)` restricts nothing and `get-global sin` finds
      it regardless. Making aliases bite would mean a mangled-only table, which
      breaks the globals blob and every `.pbc` the pipeline loads, since both
      resolve public names. The restriction has to be a **check**: after
      expansion, every free global reference must be one the program is
      entitled to.

      Only programs with a top-level `import` are checked. That escape hatch is
      load-bearing rather than a convenience — every test in `tests/test-paal.scm`
      is a bare script, as are `paal eval`, the REPL, the globals blob and each
      cached pipeline library. R7RS requires an import; a program that supplies
      one is asking to be held to it.

      The libraries are partitioned by naming the **small** ones exhaustively
      and letting `(scheme base)` be everything else. That inversion is the
      point: base has some 200 names, and a typo while enumerating it would sit
      between a correct program and compiling, whereas a name missing from a
      small library is only over-permissive. `(scheme r5rs)` counts as base —
      it exports the whole R5RS language, and paal's entry lists only the two
      names R7RS renamed.

      Three leaks turned up while wiring it, all the same shape — expander
      state escaping the thing it belongs to:

      - a spliced **library body** was checked against its *importer's* imports,
        so `(chibi test)` was rejected for using `reverse`;
      - a library's **own imports** granted to its importer, so `(import (srfi 1))`
        alone silently granted base — `sin` correctly rejected while `car`
        sailed through, which is exactly what an unearned base grant looks like;
      - the emitted **alias forms** were checked, and `(define m:sin sin)` names
        the internal binding that `prefix` exists to hide.

      `(scheme cxr)` is partitioned too — the 24 compositions of depth three
      and four, with depth two (`caar`, `cadr`, `cdar`, `cddr`) left in base.
      R7RS 6.4 counts twenty-eight in all; the split is 4 + 24. paal's own
      libraries use `caddr` and `cadddr` freely while importing only
      `(scheme base)`, which is fine: a `define-library` is never checked, and
      its body is skipped when spliced into an importer.

      Two limits remain, both over-permissive rather than wrongly rejecting: a
      modifier over base does not narrow it, so `(only (scheme base) car)`
      still grants base; and because base is "everything else", a name
      belonging to no library at all reaches the runtime rather than the
      check.
- [x] **A library's import prologue leaked into its importer** — imports were
      effectively transitive. `install-library!` renamed the library's *body*
      and spliced its prologue in untouched, so `(import (m greet))` handed you
      `cube`: `(m greet)` imports `(m math)`, and `(m math)`'s aliases arrived
      under their own names. The prologue is flattened and renamed with the
      body now, so a library's imports are private to it.

      This changes observable behaviour, and the fixtures relied on it: the
      module-system and SRFI tests were programs importing a library and *not*
      `(scheme base)`, which is not conforming R7RS. Their two helpers now
      prepend it.

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
