# Paal Kaappi

A self-hosted Scheme compiler and bytecode VM for Kaappi — written in Kaappi Scheme.

*Paal Kaappi* (பால் காப்பி) is the Tamil phrase for milk coffee.

## Status

Self-hosting and R7RS-small conformant to its recorded baseline. Paal bootstraps
under the `kaappi` interpreter, compiles its own nine-stage pipeline to bytecode
(`make pbc-pipeline`), and ships as a standalone binary (`make binary`). The
conformance suite tracks a per-section ratchet (`tests/r7rs/`); the remaining
failures are the syntax-object hygiene cases recorded in `docs/TODO.md`, not
missing features.

## Design

The pipeline forks at the IR — one node tree, two backends, both of which must
handle every node type:

```
reader → expander → compiler ─┬─→ vm                (tree-walking; bootstrap/reference)
                      IR      └─→ emitter → vm-bc   (bytecode; the CLI default path)
```

The tree-walking VM is the reference implementation, not the production one: the
bytecode VM is tested against it for equivalence, so a disagreement isolates a bug
to the emitter.

The expander is environment-aware — an immutable compile-time environment threads
through expansion, so lexical bindings shadow keywords, `syntax-rules` literals
match by denotation, and body-level `define-syntax` scopes to its body. `call/cc`
is full multi-shot on the bytecode VM.

## Usage

```sh
make                                   # build the standalone binary (needs ../kaappi + zig)
make test                              # unit suite + R7RS conformance ratchet
make run                               # REPL (no args → REPL, like kaappi)
make run ARGS="file.scm"               # run a file
make run ARGS="compile f.scm -o f.pbc" # compile to .pbc bytecode
make run ARGS="features --json"        # capability report
make pbc-pipeline                      # build the pipeline bytecode cache
```

Subcommands: `check` (with warnings for unknown top-levels and arity mismatches),
`fmt`, `compile`, `ast`, `expand`, `ir`, `dis`, `features`, `cache`, `eval`,
`repl`, `run`, `debug`. Flags: `--lib-path`, `--cache`, `--profile`,
`--coverage`, `--coverage-xml`. See `CLAUDE.md` § CLI for the bundled-binary
`do` prefix.

Override the bootstrap interpreter:

```sh
make test KAAPPI=/path/to/kaappi
```

## Architecture

| Library | Role |
|---------|------|
| `(kaappi paal reader)` | Text → S-expressions (own reader: complex literals, datum labels, `#u8(…)`, fold-case) |
| `(kaappi paal expander)` | Macro expansion — `syntax-rules`, hygiene, derived forms, library system |
| `(kaappi paal compiler)` | Core forms → IR (8 node types) |
| `(kaappi paal ir)` | IR node constructors/accessors |
| `(kaappi paal vm)` | IR evaluation (tree-walking reference) |
| `(kaappi paal emitter)` | IR → register bytecode |
| `(kaappi paal vm-bc)` | Bytecode dispatch loop, call/cc, profiler, coverage, debugger |
| `(kaappi paal bytecode)` | `<bytecode-function>` record and the ISA |
| `(kaappi paal frame)` | Closures, call frames, continuations |
| `(kaappi paal serializer)` | `.pbc` read/write (versioned header) |
| `(kaappi paal formatter)` | `fmt` — canonical reprinting |
| `(kaappi paal disassembler)` | `dis` and `(disassemble proc)` listings |
| `(kaappi paal lint)` | `check` warnings |
| `(kaappi paal embedded)` | Bundled library sources for the standalone binary |
| `(kaappi paal)` | Public API |

Internal docs live in `docs/` — `architecture.md` for the design,
`bootstrapping.md` for how self-hosting was reached, `ir.md` for the node types.

## License

MIT
