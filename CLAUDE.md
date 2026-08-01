# Paal — Self-hosted Scheme Compiler

## What is paal?

Paal (Paal Kaappi, பால் காப்பி — "milk coffee") is a self-hosting Scheme compiler
written in Kaappi Scheme. It bootstraps using the `kaappi` interpreter and will
eventually compile itself, producing the `paal` binary.

## Running

```sh
make                                   # build the paal binary (needs ../kaappi + zig)
make test                              # run test suite via kaappi
make coverage                          # test with procedure coverage report
make run                               # start REPL (no args → REPL, like kaappi)
make run ARGS="file.scm"               # run a file
make run ARGS="compile f.scm -o f.pbc" # compile to .pbc bytecode
make run ARGS="eval '(+ 1 2)'"         # evaluate an expression
make run ARGS="expand file.scm"        # print expanded forms (diagnostic)
make run ARGS="ir file.scm"            # print IR nodes (diagnostic)
make run ARGS="debug file.scm"         # run under the stepping debugger
make pbc-pipeline                      # build pipeline cache (speeds up self-hosted path)
```

## CLI

`paal` follows the same interpreter-style conventions as `kaappi`: no args starts
the REPL, a positional file runs it, and subcommands (`check`, `fmt`, `compile`,
`expand`, `ir`, `eval`, `repl`, `run`) and flags (`--lib-path`, `--help`,
`--version`) work the same way. Paal-only: `debug`, `--cache`, `--profile`,
`--coverage`.

**Exceptions:** `compile` outputs `.pbc` text bytecode (not a native binary).

In a `make binary` build, kaappi's own CLI claims the first argument whenever it
recognizes it — `check`, `fmt`, `compile`, `expand`, `ir`, `--lib-path`, `--help`
(kaappi/kaappi#2010). It only inspects the first, so **prefix the command with
`do`** and the rest arrives intact: `paal do check f.scm`, `paal do --lib-path lib
f.scm`. Bare `help` works too, since `--help` answers as kaappi. `do` is a no-op in
bootstrap mode.

`paal debug <file>` stops at each call and return: `s`/`n`/`f`/`c` to step, step
over, finish the frame and continue; `b <name>` to break on a procedure, `bt` for
a backtrace with arguments, `p <name>` to print a top-level binding, `h` for the
list. See `docs/architecture.md` § The stepping debugger.

## Architecture

Each compilation stage is a separate `define-library` under `lib/kaappi/paal/`:

| Library | File | Role |
|---------|------|------|
| `(kaappi paal reader)` | `lib/kaappi/paal/reader.sld` | Text → list of S-expressions |
| `(kaappi paal expander)` | `lib/kaappi/paal/expander.sld` | Macro expansion (stub → full) |
| `(kaappi paal compiler)` | `lib/kaappi/paal/compiler.sld` | S-expr → IR |
| `(kaappi paal vm)` | `lib/kaappi/paal/vm.sld` | IR eval (tree-walking bootstrap) |
| `(kaappi paal)` | `lib/kaappi/paal.sld` | Public API |

Entry point for the CLI: `src/main.scm` (produces `paal` binary eventually).

## Binary naming

Paal ships one binary, `paal` — the compiler/interpreter. No `p`-prefixed variants:
the old scheme existed to keep `pkaappi`/`pthottam` clear of the kaappi tools of the
same name, and `paal` has no such collision.

There is no paal package manager and none is planned. Paal packages use `thottam`,
the existing Zig one from the kaappi repo; a second implementation would have to
track the same manifest format and registry for no gain.

## Conventions

- 2-space indentation, R7RS idioms throughout
- Each pipeline stage is independently importable
- Tests live in `tests/test-paal.scm` and use the `(kaappi test)` API
- Commit messages: short imperative subject, body explains why

## Documentation

Internal docs live in `docs/` (see `docs/README.md` for the index).

**After every major code change, update the relevant doc(s):**

| Changed | Update |
|---------|--------|
| Pipeline stage design, env model, public API | `docs/architecture.md` |
| IR node types (add/remove/rename) | `docs/ir.md` |
| Bootstrapping roadmap, ISA, stage status | `docs/bootstrapping.md` |

"Major" means: new pipeline stage, new IR node type, changed calling convention,
new public export, or any architectural decision that would surprise a reader of
the existing docs. Bug fixes and test additions don't require a doc update.
