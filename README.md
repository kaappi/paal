# Paal Kaappi

A self-hosted Scheme interpreter, VM, and compiler for Kaappi — written in Kaappi Scheme.

*Paal Kaappi* (பால் காப்பி) is the Tamil phrase for milk coffee.

## Status

Early development — bootstrapping the compilation pipeline.

## Design

Paal is a self-hosting Scheme compiler that bootstraps using the `kaappi` interpreter.
Once complete, `pkaappi` will compile Kaappi Scheme to Paal bytecode and run it on the
Paal VM — including compiling its own source.

**Compilation pipeline:**

```
Source text → Reader → Expander → Analyzer → IR → (Emitter → Bytecode → VM)
```

The bootstrap VM is a tree-walking interpreter over the IR. The bytecode emitter and
register-based VM will be layered on top as the project matures.

**Bootstrapping roadmap:**

1. Tree-walking interpreter over IR (current)
2. IR → bytecode emitter
3. Register-based bytecode VM
4. Self-hosted reader (replacing host `read`)
5. Self-hosted macro expander
6. `pkaappi` compiles itself

## Usage

```sh
make test                          # run the test suite
make run ARGS="run examples/hello.scm"
make run ARGS="eval '(+ 1 2)'"
make coverage                      # test with procedure coverage report
```

Override the bootstrap interpreter:

```sh
make test KAAPPI=/path/to/kaappi
```

## Architecture

| Library | Role |
|---------|------|
| `(kaappi paal reader)` | Text → S-expressions (wraps host reader initially) |
| `(kaappi paal expander)` | S-expressions → core forms (macro expansion) |
| `(kaappi paal compiler)` | Core forms → IR |
| `(kaappi paal vm)` | IR → result (tree-walking bootstrap VM) |
| `(kaappi paal)` | Public API: `pkaappi-run-string`, `pkaappi-run-file` |

## License

MIT
