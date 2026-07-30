# Paal — Self-hosted Scheme Compiler

## What is paal?

Paal (Paal Kaappi, பால் காப்பி — "milk coffee") is a self-hosting Scheme compiler
written in Kaappi Scheme. It bootstraps using the `kaappi` interpreter and will
eventually compile itself, producing the `pkaappi` binary.

## Running

```sh
make test                              # run test suite via kaappi
make coverage                          # test with procedure coverage report
make run                               # start REPL (no args → REPL, like kaappi)
make run ARGS="file.scm"               # run a file
make run ARGS="compile f.scm -o f.pbc" # compile to .pbc bytecode
make run ARGS="eval '(+ 1 2)'"         # evaluate an expression
make run ARGS="expand file.scm"        # print expanded forms (diagnostic)
make run ARGS="ir file.scm"            # print IR nodes (diagnostic)
make pbc-pipeline                      # build pipeline cache (speeds up self-hosted path)
```

## CLI — pkaappi vs kaappi

`pkaappi` intentionally mirrors `kaappi`'s interpreter-style CLI:

| Invocation | kaappi | pkaappi |
|------------|--------|---------|
| No args | REPL | REPL ✓ |
| `<tool> file.scm` | run file | run file ✓ |
| `<tool> -h` / `--help` | usage | usage ✓ |
| `<tool> --version` | print version | print version ✓ |
| `<tool> expand file.scm` | print expanded forms | print expanded forms ✓ |
| `<tool> ir file.scm` | print IR nodes | print IR nodes ✓ |
| `<tool> eval '<expr>'` | evaluate expression | evaluate expression ✓ |
| `<tool> repl` | — | explicit REPL subcommand |
| Unknown flag | `error: unknown option:` (exit 2) | `error: unknown option:` (exit 2) ✓ |

### Exceptions and differences

- **`compile` output differs**: `kaappi compile file.scm` produces a native binary via
  LLVM; `pkaappi compile file.scm -o out.pbc` produces a text S-expression bytecode
  file (`.pbc`). The `-o` flag is required for pkaappi; kaappi defaults the output name.

- **No `--lib-path` flag**: pkaappi doesn't accept `--lib-path`. In bootstrap mode the
  library path is provided to kaappi; in standalone binary mode libraries are bundled.

- **Script args not forwarded**: `pkaappi file.scm arg1 arg2` runs `file.scm` but
  `(command-line)` inside the user's program does not see `arg1 arg2`. kaappi passes
  everything after the filename as script args.

- **`.pbc` auto-detection**: `pkaappi file.pbc` runs a pre-compiled paal bytecode file.
  kaappi has no `.pbc` equivalent (it uses `.sbc`).

- **`run` subcommand kept**: `pkaappi run file.scm` still works for compatibility;
  kaappi has no `run` subcommand.

- **`version` subcommand kept**: `pkaappi version` still works; kaappi only has
  `--version`.

- **kaappi-only subcommands not yet in pkaappi**: `check`, `fmt`, `test`, `doctor`,
  `cache`, `features`, `ast`. Runtime flags (`--sandbox`, `--gc-stats`, `--profile`,
  `--coverage`, `--timeout`, etc.) are also absent.

## Architecture

Each compilation stage is a separate `define-library` under `lib/kaappi/paal/`:

| Library | File | Role |
|---------|------|------|
| `(kaappi paal reader)` | `lib/kaappi/paal/reader.sld` | Text → list of S-expressions |
| `(kaappi paal expander)` | `lib/kaappi/paal/expander.sld` | Macro expansion (stub → full) |
| `(kaappi paal compiler)` | `lib/kaappi/paal/compiler.sld` | S-expr → IR |
| `(kaappi paal vm)` | `lib/kaappi/paal/vm.sld` | IR eval (tree-walking bootstrap) |
| `(kaappi paal)` | `lib/kaappi/paal.sld` | Public API |

Entry point for the CLI: `src/main.scm` (produces `pkaappi` binary eventually).

## Binary naming

Paal binaries use the `p` prefix to avoid collision with kaappi tools:
- `pkaappi` — the main compiler/interpreter
- `pthottam` — paal's package manager (future)

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
