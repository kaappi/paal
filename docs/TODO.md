# Paal: close the remaining gaps vs Zig kaappi (campaign 2)

This file is the plan for the active campaign. The previous TODO — the
campaign-1 record of Phases 1–9, each closed with its reasoning on record —
was retired when this replaced it; read it in git history (last version at
commit `aa54e1f`). Its "Not planned" list carries forward in **Out of
scope** below, so no recorded decision was lost in the swap.

## Status (as of 2026-08-02)

- **Phase 0 — done.** The four sweep-found expander bugs became nine
  distinct fixes; SRFI 67, 70, 101, 135, 140, 148 and 171 all import and
  run. Unit suite 904 → 935.
- **Phase 1 — in progress.** The SRFI shelf harness (`make test-srfi`,
  `tests/srfi/`) is live and ratcheting over 156 vendored kaappi test files
  (123 pass, 33 fail, 6 skipped). Batch 1's burn-down is **complete**, and
  vendor tranches 2a–2d have landed (115 more libraries: the seven the
  Phase 0 fixes unlocked, then the dependency-free layer, then the two
  dependent layers and `(kaappi parallel)`). Fixes each
  tranche flushed out: SRFI 69's
  kaappi-compatible failure default, the full SRFI 13 completion, SRFI
  1/133 n-ary and range arms, the SRFI 128 record-ordering adaptation,
  primitive-error routing through `%paal-handlers` (architecture.md
  § Exception handlers), and then eight more — imported macros named for
  core keywords winning at the use site while machinery keeps its own
  (architecture.md § Stage 2), SRFI 17 generalized `set!`, bounded-space
  `delay-force`, paal-side `call-with-{input,output}-file` and the
  three-argument `member`/`assoc`, template hygiene reaching into a
  binding's init expression, a macro named for a definition keyword
  getting first refusal in a body, and a template's `let-syntax` keywords
  counting as template-bound. Next: burn down the recorded fails that are
  neither Phase 2 nor Phase 4 work. Exact counts live in
  `tests/srfi/paal-srfi-expected.sld`, which is where a number stays true.
- **Phase 2 — in progress.** `(kaappi sysinfo)` is bound (7 zero-argument
  primitives answering strings), which lands SRFI 59, 112 and 193 — shelf
  126 pass / 33 fail / 7 skipped. SRFI 112's suite asserts that a
  zero-argument procedure rejects a surplus one, which is how it came out
  that **neither pipeline checked argument counts**: the bytecode VM
  dropped surplus arguments and read missing ones out of stale registers.
  Both check now (architecture.md § Lambda binding), and that check in
  turn surfaced `(srfi 133)`'s `vector-unfold` family needing its seeds
  variadic, as kaappi's native one has them. Remaining: `(srfi 160
  primitives)`, `(srfi 237 primitives)`, `(srfi 254)`, `(kaappi
  primitives)`.
- **Phases 3–6 — pending.** (Phase 3's REPL `,help` sectioning landed
  early, outside the phase; the rest of item 8 is planned below.)

## Context

The 2026-08 feature-parity campaign (campaign 1, Phase 9) closed paal's
small and medium gaps against the Zig kaappi: baseline 1187/24/11 →
**1221/4/0**, unit suite 685 → 904. What remains was measured fresh
(2026-08-02) with a full tooling + runtime inventory of the Zig core, a
`features --json` diff of both binaries, and a live sweep of every kaappi
SRFI paal lacks:

- **SRFI shelf**: kaappi answers 174 importable SRFIs; paal 31 embedded + 3
  host-native. Sweeping the 140 others through
  `paal do --lib-path ../kaappi/lib eval '(import (scheme base) (srfi N)) …'`:
  **111 import cleanly**, 6 fail on real paal bugs, 13 on kaappi-native
  sub-libraries, 3 inherit recorded exclusions (SRFI 18/170 dependents).
  (Sweep artifacts were session-local scratch, not committed.)
- **CLI/tooling**: paal lacks `test` (SRFI-64 runner), `--diagnostics=json`,
  `--deny-warnings`, `--timings`, `--profile-json`, `--completions`, stdin
  piping, a runtime fmt round-trip guard, and ~13 REPL comma commands.
- **Correctness residue**: the 4 baseline failures — §4.3 tests 117/149/153
  (need per-identifier provenance = syntax objects; recorded design boundary,
  architecture.md § Stage 2) and §6.2 `(real? -2.5+0.0i)` (blocked on upstream
  kaappi#2166).
- **Self-hosted path**: `spawn`/`ffi-callback` trampolines exist only on the
  HOST-pipeline path; the self-hosted path is ~59× slower (10.06 s vs 0.17 s);
  bootstrapping.md records bytevector instruction encoding as intended future
  perf work; paal has 0 IR optimization passes where kaappi has 5.

Goal: a second campaign of roughly the last one's size (~25–30 commits) that
takes paal from "conformant with a small recorded residue" to "answers
(import (srfi N)) for everything kaappi can that doesn't require new VM
machinery, with the tooling tail closed and the one remaining expander design
boundary addressed."

Scope confirmed 2026-08-02: **full reachable SRFI parity** (vendor +
host-bind, ≈168/174), **syntax objects design + implementation**, and perf
as **bytevector encoding + measurement** (IR passes only if the encoding
pays).

## Out of scope (unchanged recorded decisions + 3 additions)

Unchanged, carried from campaign 1's "Not planned": SRFI 18 (OS threads),
SRFI 170 (POSIX), SRFI 192 (port positioning), LLVM native codegen,
`explain`/KP registry, `doctor`, any package manager. Their dependents stay
excluded: SRFI 120, 216 (need 18), SRFI 29 (needs 170).

New exclusions, recorded with reasons here when the campaign lands:
- **SRFI 181** (custom ports): constructors take Scheme procedures the HOST
  port layer calls later — needs the callback-crossing treatment *plus* paal
  ports flowing through host I/O; not worth the machinery.
- **SRFI 248 primitives** (`%call-with-unwind-handler`): winds/handlers are
  paal-owned stacks; binding the host's would be semantically wrong. A
  paal-side implementation is possible but is its own project.
- **SRFI 211 / er-macros** (blocks SRFI 150): expander-level; can only follow
  the syntax-objects design (Phase 4), not precede it. Revisit after P4.
- REPL tab completion / live highlighting: needs raw-terminal control the host
  doesn't expose to Scheme. Optional upstream ask: a `(kaappi readline)`
  primitive set over vendored linenoise.

## Phase 0 — Fix the six bugs the sweep found (S, ~4 commits) ✅

Plain correctness bugs, all in `lib/kaappi/paal/expander.sld`; each unlocks
SRFIs and is a standalone ratchet-neutral fix with unit tests:

1. **`include` paths resolve relative to CWD, not the including file**
   (breaks SRFI 135, 171). Thread the including file's directory through the
   include slurp path (same helper that fixed the 4096-byte-boundary slurp).
   Applies to `include`, `include-ci`, `include-library-declarations`.
2. **`else` inside a syntax-rules template reaches `expand-case`/`expand-cond`
   as `%core%else` and is rejected** (breaks SRFI 67). Clause-position
   dispatch must strip/honor the `%core%` mark the way head dispatch already
   does.
3. **Locally redefining an excepted base name fails renaming** (breaks
   SRFI 70, 101, 140 with unbound `%srfi%NN%name`). Their shared shape:
   `(import (except (scheme base) quotient …) (rename (only (scheme base)
   quotient …) (quotient %quotient) …))` + a body `(define (quotient …) …)`.
   The importer's alias references `%srfi%70%quotient`, but the local define
   never lands under that name. Fix in `install-library!`'s rename-map
   construction for body defines that shadow base names under
   `except`/`rename` modifiers.
4. **Macro-produced `define-syntax` transformer specs rejected** (breaks
   SRFI 148; this is SRFI 147 semantics, which kaappi supports): when the
   transformer position is a macro use, expand it until `(syntax-rules …)`
   emerges, then proceed.

Gate: the four named SRFIs import and pass smoke tests on both pipelines;
`make test` green; baseline unchanged.

**Outcome:** the four planned bugs became nine distinct fixes — the extra
five were latent and flushed out by the fixtures (rename-over-full-base
producing no aliases; machinery emissions stealable by name-shadowing
libraries, now `%paal-base-*` spellings; record desugar's internal `v`
capturing a field named `v`; `rename-template` not following `%gref%`
marks; pattern-vars counting the clause head as a pattern variable).

## Phase 1 — SRFI shelf: vendor + verify the 111 clean importers (L, ~6–8 commits)

Pattern already proven by campaign 1's 21-library vendoring: copy from
`../kaappi/lib/srfi/`, verify behaviorally, embed, record adaptations in file
headers.

1. **Build the verification harness first** — done: `tests/srfi/` mirrors the
   `tests/r7rs/` pattern; kaappi's per-SRFI suites run under paal via the
   in-process HOST bytecode pipeline (shelling out is ~500× slower), with
   file-level verdicts ratcheted both directions by `make test-srfi` inside
   `make test`. Adaptation policy in `tests/srfi/README.md`.
2. Vendor in dependency order, batched by family (containers, strings/format,
   comprehensions, misc). Sub-libraries come along (`(srfi 146 hash)`,
   `(srfi 166 pretty|columnar|unicode|color)`, `(srfi 171 meta)`, etc.).
3. Also vendor `(kaappi parallel)` (pure-Scheme worker pools over the fiber
   bindings paal already has).
4. **Embedding strategy — decided: do NOT embed the new SRFIs.**
   `embedded.sld` is 280 KB and parsed on every bootstrap-mode run; kaappi's
   full shelf is 2.1 MB. Embedded stays the curated set; the bundled-binary
   boundary gets documented. Binary determinism rule stays: embedded wins
   over disk.
5. Advertise `srfi-<n>` cond-expand feature ids for shelf members (kaappi
   routes both spellings through one registry; paal's feature list is owned by
   the expander — extend `paal-feature-list` derivation, keep one owner).
   Done for the vendored set: `srfi-<n>` ids resolve via the
   `(library (srfi n))` check.
6. Fix paal bugs the harness flushes out (campaign 1 precedent says expect a
   few; each lands with its own pinned test).

Gate: per-SRFI harness table committed as a ratchet; `features --json`
embedded_libraries count reflects the decision in 4; R7RS baseline unchanged.

## Phase 2 — Host-native sub-library bindings (M, ~3 commits)

Extend the proven boundary pattern (how ffi/fibers/SRFI 27/258/260 were bound:
procedure objects installed in `paal-initial-env` / the globals blob in
`lib/kaappi/paal/vm.sld`) to the native backing sets whose values cross the
boundary as opaque objects or plain data:

- `(kaappi sysinfo)` (7 prims, plain data) → unlocks SRFI 59, 112, 193
- `(srfi 160 primitives)` (6 prims, opaque NumericVector) → unlocks 4, 63, 66,
  74, 231
- `(srfi 237 primitives)` (19 prims, opaque RTDs/records) → unlocks 57, 131,
  136, 137, 237, 240
- `(srfi 254)` (16 prims, opaque ephemerons/guardians) → SRFI 254
- `(kaappi primitives)` %-helpers table → unlocks SRFI 271 (+ anything else
  that imports it)

Each binding = expose the host procedures under the sub-library name in paal's
module system + vendor the portable wrapper + harness verification. Watch for
procedure-valued arguments (none expected in these sets — that's why 181/248
are excluded).

Gate: 16 more SRFIs green in the harness; total importable ≈ 168 of kaappi's
174, the 6 shortfalls recorded here with reasons.

## Phase 3 — Tooling & CLI tail (M, ~6 commits)

All in `src/main.scm` + small support libs; every new subcommand name must
avoid kaappi's CLI names or be documented as `do`-only (kaappi#2010: a bundled
binary loses any argv kaappi recognizes, and new flags are unreachable without
`do`).

1. **`paal test [paths…]`** — SRFI-64 runner over the vendored reference
   SRFI 64; `--json`, `--seed`, `--lib-path`. (Name collides with kaappi's
   `test` subcommand → document `paal do test`; skip `--changed` impact
   analysis for now.)
2. **`--diagnostics=json`** — LSP Diagnostic JSON-lines on stderr for `check`
   + read/expand errors, matching kaappi's field shape (`(kaappi paal lint)`
   already produces findings as data).
3. **`--deny-warnings`** for `check` (exit-code promotion).
4. **`--timings[=json]`** — per-stage self-time (read/expand/analyze/emit/run)
   + cache HIT/MISS line; paal knows its stage boundaries.
5. **`--profile-json <file>`** — JSON rendering of the existing profiler
   table.
6. **stdin piping** — non-tty stdin runs as a program instead of entering the
   REPL (kaappi behavior).
7. **fmt runtime round-trip guard** — verify reader-equality before writing
   (today only the test suite asserts it; kaappi refuses to write on
   mismatch).
8. **REPL comma tail** — detailed 2026-08-02 after measuring kaappi's
   sectioned `,help` (repl.zig:964) against paal's surface. The `,help`
   *structure* itself (Evaluation/Inspection/Debugging/System sections, `_`
   footnote) was adopted immediately, outside this phase. What remains is the
   14-command diff, planned as 5 gated commits:

   Grounding (verified in-source): the hooks table in `paal.sld`
   (`%repl-loaded-hooks` / `%repl-host-hooks`) is the single extension
   point — every command must land on BOTH routes, loaded via fixed program
   strings, HOST directly. Debug + profile machinery already lives in
   `vm-bc.sld` (`paal-debug-start!/stop!/break!/unbreak!/breaks`,
   `paal-profile-start!/report/masked`) — *inside* the loaded pipeline, so
   both routes reach it. The CLI's `debug`/`--profile` run HOST-only today;
   the REPL's loaded route is the first to drive the loaded world's own
   instrumentation — if it fights back, ship those commands HOST-route with
   a one-line "runs on the HOST pipeline" notice rather than block.

   - **8a — System tail** `,version ,import ,load` + startup banner.
     `,version` prints the CLI's `paal <version>` line; `,import <lib>`
     takes the next datum L and evals `(import L)` (already a working form —
     pure sugar); `,load <file>` takes the rest of the line as a path
     (paths aren't datums), `paal-read-file` + per-form eval through the
     session hooks so definitions accumulate; not recorded in history
     (comma-command rule). Banner prints from `src/main.scm`'s REPL entry
     ONLY — `%host-repl-transcript` tests call `pkaappi-host-repl` directly
     and their pins must not churn. Driver-only; no cache risk.
   - **8b — Typing + search** `,type <form>`, `,env [prefix]`,
     `,apropos <str>`. Factor `%value-type-name` out of `%debug-write`'s
     recognizers (it already classifies loaded-world closures crossing as
     tagged vectors); `,type` = eval (sets `_`), echo value + type. `,env`
     gains kaappi's optional prefix filter (rest-of-line, like
     `,history`). `,apropos` needs a new `all-names` hook — session +
     baseline globals — on both routes; print sorted + `; N matches`.
   - **8c — `,describe <sym>`**: new `describe` hook returning a data
     alist (`type/arity/variadic/name`) built where the value lives:
     loaded route describes inside the world via fixed string (bytecode
     records aren't pokeable from the driver), HOST route uses
     `(kaappi paal bytecode)` accessors. HOST-native procedures describe
     honestly as opaque (R7RS has no arity introspection).
   - **8d — Debug family** `,step <form>`, `,break <name>`,
     `,breakpoints`, `,delete all`. `,step` = one-shot
     `paal-debug-start!` in `'step` mode + `%debug-console-hook` (console
     reads the same stdin — kaappi does the same); `,break` keeps a
     session set, and while non-empty every eval runs under `'run`-mode
     instrumentation, stopped after each form. HOST hooks first, loaded
     hooks second. Tests drive the console through scripted
     `%host-repl-transcript` stdin, the existing pattern.
   - **8e — `,profile <form>`** + docs truth. Needs a
     `paal-profile-stop!`/reset export that vm-bc doesn't have (only
     start!/report/masked exist) — a vm-bc.sld edit, so batch it into the
     same commit-window as any 8d vm-bc changes: **vm-bc edits invalidate
     the pipeline cache, and fixed strings referencing a NEW pipeline
     export need `make clean-cache && make pbc-pipeline`** (the recorded
     rule). Close by growing `,help`'s Debugging/System sections and
     updating architecture.md § CLI tooling + CLAUDE.md's comma list.

   Recorded exclusions (with reasons, at Phase 6): `,gc` (GC is
   host-owned; revisit only if kaappi grows a diagnostics primitive set);
   `,condition <id> <expr>` (needs numbered+conditional breakpoints —
   vm-bc's break set is name-keyed; real machinery for a niche command,
   stretch only if 8d lands clean); tab completion + arrow history
   (terminal control; the linenoise upstream ask).
9. Optional (only if cheap): `--completions bash|zsh|fish` static scripts.

Gate: each item has unit coverage in `tests/test-paal.scm`; pinned REPL
transcript updated once; `make test` green throughout.

## Phase 4 — Syntax objects: the recorded expander boundary (L, high-risk, ~6–8 commits)

The one remaining *design* gap (architecture.md § Stage 2, deferred at the
end of campaign 1 with the reason on record): a template-introduced
identifier bound only by a **later** expansion step needs per-identifier
provenance that symbol marking cannot carry. Covers §4.3 tests 117/149/153
and un-adapts the vendored SRFI 26; the shelf burn-down added two more
payoff targets of the same class (SRFI 41 `stream-of`, SRFI 42 `do-ec`).

1. **Design doc first** (`docs/syntax-objects.md`): representation (wrapped
   identifiers vs side-table keyed by rename), how it composes with the cenv,
   `%gref%`/`%core%`/`%mac-` marks, quote-aware instantiation, and the
   serializer (`.pbc` must not carry wrapped identifiers — provenance is
   expansion-time only). Include the migration story: marks stay as the
   compatibility surface; provenance is added, not substituted, so the 1221
   baseline never regresses mid-migration.
2. Implement incrementally behind the ratchet: land the representation +
   plumbing with zero behavior change, then switch the specific decisions
   (template-binder resolution, literal matching) one at a time.
3. Un-adapt SRFI 26 (restore kaappi's file verbatim); regenerate baseline:
   §4.3 22/3 → 25/0. Ratchet moves only in the same commit as behavior +
   tests.
4. Record what this unlocks later (er-macros/SRFI 211/150) without doing it.

Risk control: every step lands on both pipelines; any step that can't hold the
baseline gets reverted, and the boundary re-recorded with what was learned.

## Phase 5 — Self-hosted path completeness + performance (M/L, ~5 commits)

1. **`spawn`/`ffi-callback` on the self-hosted path**: the paal-compiled VM
   builds its trampoline as a paal closure the HOST can't enter. Give the
   loaded pipeline the same HOST-trampoline installation the HOST pipeline
   got (install via the boundary-safe table injection used for
   `paal-embedded-source`).
2. **Bytevector instruction encoding** (bootstrapping.md's recorded next perf
   step): migrate tagged-list instructions to a packed encoding in
   `bytecode.sld` + `emitter.sld` + `vm-bc.sld` + `serializer.sld`;
   tree-walker untouched (it never sees instructions). `.pbc` header bumps to
   `(paal-pbc 2)`; the tolerant reader keeps 1 readable. Batch with any other
   serializer edits — these invalidate all 9 pipeline cache files (~15 min
   rebuild).
3. Measure before/after on `tests/fixtures/hof.scm` (the 59× datum) and a
   pipeline self-compile; record in docs.
4. Optional stretch, only if 2 pays: constant folding + dead-register elision
   as a first IR pass pair (paal currently has 0 passes vs kaappi's 5); `ir`
   subcommand gains `--no-opt` for parity.
5. Optional stretch: fiber × call/cc episode identity — write the test that
   pins current behavior, document semantics either way.

Gate: self-hosted `hof.scm` wall-time improvement recorded; equivalence suite
(tree-walker vs bytecode) stays green; `make pbc-pipeline` and `make binary`
still work. Revisit the srfi14 shelf skip (runtime-cost) after this phase.

## Phase 6 — Upstream-coupled residuals (S, ongoing bookkeeping)

- **kaappi#2166** (exact-complex representation): when it lands upstream,
  regenerate baseline — §6.2 210/1 → 211/0. Until then nothing to do in paal.
- **kaappi#2010** (bundled CLI claims argv): when fixed, `do` becomes
  optional; keep it working as compat. Re-verify the binary behavior table
  (campaign 1, Phase 6 — git history).
- **Upstream report, pending**: 8 vendored kaappi SRFI test files call
  `exit`/`display`/`caddr` without importing them — tolerated by kaappi's
  unenforced import scope, caught by paal's checker; adaptations recorded
  in-file. File as one kaappi issue at a natural break.
- **Handler timing divergence**: kaappi runs exception handlers after
  unwinding; paal matches R7RS 4.2.7 more closely and stays as-is.
  `raise-continuable` resumption through a *declining* guard is the shared
  corner — fix only in lockstep with kaappi (three-way agreement rule),
  tracked, not scheduled.
- **`write` of structures containing procedures** still leaks closure
  vectors — needs paal's own writer (cycle detection + labels). Optional; do
  only if a real program hits it.

## Verification (whole campaign)

- Every commit: `make test` (~5–10 min; gate on the command's own exit code,
  never on failure-text grep). Ratchet counts move only with behavior + tests
  + regenerated baseline in the same commit.
- The per-SRFI harness table (Phase 1) is a second ratchet: `make test-srfi`
  gates inside `make test`.
- Feature landings touch **both pipelines**; never "fix" a divergence by
  changing the tree-walker first.
- End state: `paal do features --json` shows ≈168 importable SRFIs; R7RS
  baseline 1224/1/0 (§4.3 closed; §6.2 waiting on upstream); README/
  CHANGELOG/architecture.md/bootstrapping.md and this file updated per the
  docs rule.

## Execution notes (house rules from campaign 1)

- Commits straight to `main`, short imperative subjects, push per commit.
- No lib/*.sld edits while `make test`'s r7rs half or `pbc-pipeline` runs.
- serializer.sld / src/main.scm edits invalidate all 9 cache files — batch,
  rebuild once; first rebuild after a serializer change writes old-format
  caches (loaded-copy effect), second normalizes.
- An injected-string change in paal.sld that references a NEW pipeline
  export cannot rebuild incrementally — the compile subcommand loads the
  *old* cached pipeline, which lacks the name. `make clean-cache &&
  make pbc-pipeline` forces the .sld source route.
- kaappi on PATH is v0.22.0; guard-depth correctness needs a kaappi built
  past #1919 — CI builds kaappi from main, local testing should too.
