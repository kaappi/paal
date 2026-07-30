# Paal — Self-hosted Scheme Compiler

## What is paal?

Paal (Paal Kaappi, பால் காப்பி — "milk coffee") is a self-hosting Scheme compiler
written in Kaappi Scheme. It bootstraps using the `kaappi` interpreter and will
eventually compile itself, producing the `pkaappi` binary.

## Running

```sh
make test                           # run test suite via kaappi
make coverage                       # test with procedure coverage report
make run ARGS="run file.scm"        # run a file through pkaappi
make run ARGS="eval '(+ 1 2)'"     # evaluate an expression
```

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
