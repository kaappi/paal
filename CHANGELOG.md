# Changelog

Paal has not cut a release yet; everything below is the road to the first one.
Entries are grouped by area rather than by date — the git history carries the
order and the why.

## Unreleased

### Pipeline and self-hosting

- Full compilation pipeline, forked at the IR: reader → expander → compiler →
  tree-walking VM (reference) and → emitter → bytecode VM (default path).
- Self-hosting complete: paal compiles its own nine pipeline stages
  (`make pbc-pipeline`, incremental) and runs user programs through the
  loaded copy; `make binary` bundles the whole thing into a standalone
  `paal` executable with the SRFI shelf embedded.
- Own reader end to end: complex literals, rationals, datum labels
  (`#N=`/`#N#`, circular structure included), `#u8(…)`, `#!fold-case`,
  block/datum comments.
- `.pbc` text bytecode with a versioned `(paal-pbc 1)` header — headerless
  files still read; files from a newer paal refuse with a diagnosis.
- Opt-in bytecode cache for user programs (`--cache`), keyed by source hash
  in the file name.

### Language and conformance

- R7RS-small conformance held by a per-section ratchet
  (`tests/r7rs/paal-r7rs-expected.sld`); the remaining failures are the
  syntax-object hygiene cases recorded in `docs/TODO.md`.
- Environment-aware expander: an immutable compile-time environment threads
  through expansion — lexical bindings shadow keywords, `else`/`=>` are
  positional only when unbound, `syntax-rules` literals match by denotation,
  custom ellipsis and vector patterns work, body-level `define-syntax`
  scopes to its body, and macro-produced definitions bind (R7RS 5.3.2).
- Hygiene by symbol marking: per-expansion renames for template binders,
  quote-aware instantiation, `%gref%` referential transparency, `%core%`
  keyword protection.
- Full multi-shot `call/cc` on the bytecode VM (capture and invoke live in
  the dispatch loop; dynamic-wind and parameterize re-entry per R7RS).
- `guard` re-raises in the raise point's dynamic environment (more
  R7RS-correct than the host; kept deliberately).
- Library system: full declaration vocabulary (`cond-expand`,
  `include-library-declarations`, `include-ci`), per-library renaming,
  import narrowing over `(scheme base)`, `environment` honouring its specs,
  and an import-scope check that holds a program to the imports it declares.
- Runtime surface: paal-native parameter objects (ports included),
  exception system with `raise-continuable`, promises with chained `force`,
  n-ary `map`/`for-each`/`vector-map`/`string-map`, `spawn`/`ffi-callback`
  across the HOST boundary, host-native SRFI 27/258/260, `rationalize`.
- Embedded SRFI shelf: 31 libraries bundled for the standalone binary,
  including kaappi's vendored portable SRFIs and the reference SRFI 64.

### Tooling and CLI

- Interpreter-style CLI matching kaappi: positional file, `check`, `fmt`,
  `compile`, `ast`, `expand`, `ir`, `features [--json]`,
  `cache status|clear`, `eval`, `repl`, `run`; `do` prefix for bundled
  binaries.
- `check` warns — never rejects — on unknown top-level variables and
  direct-call arity mismatches.
- `dis` subcommand and runtime `(disassemble proc)`.
- Stepping debugger (`paal debug`): breakpoints, backtraces with arguments,
  step/next/finish/continue, top-level binding inspection.
- Profiler (`--profile`) and procedure coverage (`--coverage`,
  `--coverage-xml` writing Cobertura for Codecov).
- REPL: whole-datum (multi-line) input, `_`, comma commands
  (`,help ,quit ,env ,history ,time ,expand ,ir ,dis`), history in
  `~/.paal_history`.
- `fmt` canonical formatter with `--check` mode; the suite round-trips
  paal's own sources through it.
