# Paal — Intermediate Representation

The IR is defined in `lib/kaappi/paal/ir.sld` as the `(kaappi paal ir)` library.
It is the narrow waist of the pipeline: the analyzer is the only thing that builds
IR nodes, and every backend consumes them.

**See also:** [KEP-0008](https://github.com/kaappi/keps/blob/main/keps/0008-shared-ir-contract.md)
documents the core-form set, optimization set, and shadowing-safety
invariant this IR shares with kaappi's and chaaya's independent IRs
(paal deliberately implements none of the optimization contract — see
the KEP for why).

## Where the IR sits

```
core-form S-expressions          (kaappi paal expander)
    │
    ▼
┌─────────────────────┐
│  Analyzer           │  (kaappi paal compiler)
│  paal-analyze-all   │
└─────────┬───────────┘
          │  IR node tree
          ├──────────────────────────────┐
          ▼                              ▼
┌─────────────────────┐    ┌─────────────────────┐
│  Tree-walking VM    │    │  Emitter            │  (kaappi paal emitter)
│  paal-eval-program  │    │  paal-emit-program  │
└─────────────────────┘    └─────────┬───────────┘
   (kaappi paal vm)                  │  bytecode-function
   bootstrap / reference             ▼
                           ┌─────────────────────┐
                           │  Bytecode VM        │  (kaappi paal vm-bc)
                           │  paal-run-bc        │
                           └─────────────────────┘
```

**Two consumers, one IR.** Both are live and both must handle every node type:

| Consumer | Entry point | Used by |
|----------|-------------|---------|
| `(kaappi paal vm)` | `paal-eval-program` | `pkaappi-run-string`, `pkaappi-run-file` — the bootstrap path |
| `(kaappi paal emitter)` | `paal-emit-program` | `pkaappi-run-bc-*`, `pkaappi-self-run-file`, `.pbc` compilation |

The CLI's default file path (`paal file.scm`) goes through the emitter. The
tree-walking VM stays as the reference implementation: it is the simpler of the
two, and the bytecode VM is tested against it for equivalence, so a disagreement
between them isolates the bug to the emitter. See `docs/bootstrapping.md` §
Design Principles.

The serializer (`.pbc` read/write) operates on bytecode, not IR — the IR is never
written to disk.

## Representation

Each IR node is a tagged list `(tag field…)` built with:

```scheme
(define (make-node tag . fields) (cons tag fields))
(define (node-tag n) (car n))
(define (node-ref n i) (list-ref (cdr n) i))
```

This is intentionally simple — no record types, no GC overhead beyond ordinary pairs.
The tag is an eq?-comparable symbol. Accessors use `node-ref` with a fixed index.

Nodes are **read-only after analysis**. Neither the VM nor the emitter mutates a
node in place, so a tree can be analyzed once and handed to both backends.

### Printed form

Because nodes are plain lists, `write` prints them directly — that is all the `ir`
subcommand does. One shape surprises readers: `begin`'s single field is a *list* of
nodes, so it prints with doubled parens.

```
(write (begin 1 2))  →  (call (ref write) ((begin ((const 1) (const 2)))))
```

The inner `(begin ((const 1) (const 2)))` is a one-field node whose field happens to
be a two-element list — not a three-field node. `call`'s second field is a list too,
giving the same doubling for arguments.

Note that the example puts the `begin` in expression position deliberately: a
*top-level* `(begin 1 2)` is spliced by the expander into two separate top-level
forms, and no `begin` node is built at all.

## Seeing the IR

```bash
make run ARGS="ir file.scm"
```

For a file containing `(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))` and
`(display (fact 5))`:

```
(define fact (lambda (n) (begin ((if (call (ref =) ((ref n) (const 0))) (const 1) (call (ref *) ((ref n) (call (ref fact) ((call (ref -) ((ref n) (const 1)))))))))) #f))
(call (ref display) ((call (ref fact) ((const 5)))))
```

The subcommand runs reader → expander → analyzer and stops, so it shows exactly
what a backend receives.

---

## Node Types

### `(const val)`

A self-evaluating constant.

```scheme
(ir:const 42)        ; → (const 42)
(ir:const "hello")   ; → (const "hello")
(ir:const '(a b c))  ; → (const (a b c))   ; produced by (quote (a b c))
```

**Constructor:** `(ir:const val)`
**Predicate:** `(ir:const? node)`
**Accessor:** `(ir:const-val node)`

Produced by the analyzer for: boolean, number, string, char, null, vector,
bytevector literals; also `(quote datum)`.

`val` is the datum itself, not a constant-pool index — the emitter embeds it
directly in a `load-const` instruction. `#t`, `#f` and `()` are special-cased to
the shorter `load-true` / `load-false` / `load-nil`.

---

### `(ref name)`

A variable reference.

```scheme
(ir:ref 'x)    ; → (ref x)
```

**Constructor:** `(ir:ref name)`
**Predicate:** `(ir:ref? node)`
**Accessor:** `(ir:ref-name node)`

Produced by the analyzer for any unquoted symbol in expression position.

The IR does **not** distinguish local, captured, and global references — `name` is
just a symbol, and each backend resolves it its own way (see
[Reference resolution is not in the IR](#reference-resolution-is-not-in-the-ir)).
`name` may carry a `%gref%` marker; see [Marked names](#marked-names).

---

### `(if test then else)`

A conditional expression.

```scheme
(ir:if test-node then-node else-node)
```

**Constructor:** `(ir:if test then else)`
**Predicate:** `(ir:if? node)`
**Accessors:** `(ir:if-test node)`, `(ir:if-then node)`, `(ir:if-else node)`

The `else` field is always present. A one-armed `(if test then)` in source becomes
`(ir:if test then (ir:const #f))`:

```
(if #t 1)  →  (if (const #t) (const 1) (const #f))
```

Both arms are tail positions; the test never is.

---

### `(begin exprs)`

A sequence of expressions; evaluates to the last value.

```scheme
(ir:begin (list e1 e2 e3))
```

**Constructor:** `(ir:begin exprs)` — `exprs` is a list of IR nodes
**Predicate:** `(ir:begin? node)`
**Accessor:** `(ir:begin-exprs node)`

Produced by the analyzer for `(begin e…)`. Also used internally to wrap multi-form
lambda bodies — every `ir:lambda` body is an `ir:begin`, even a single-expression one.

An empty `exprs` list evaluates to `#f` in both backends. A top-level `(begin)` never
reaches the analyzer (the expander splices it away), but one in expression position
does: `(write (begin))` analyzes to `(call (ref write) ((begin ())))` and prints `#f`.

Only the last expression is a tail position.

---

### `(lambda params body rest?)`

A procedure value (closure).

```scheme
(ir:lambda '(x y) body-node #f)   ; fixed arity: (lambda (x y) body)
(ir:lambda 'args  body-node #t)   ; variadic:    (lambda args body)
(ir:lambda '(x . rest) body-node #t)  ; mixed:   (lambda (x . rest) body)
(ir:lambda '() body-node #f)          ; nullary:  (lambda () body)
```

**Constructor:** `(ir:lambda params body rest?)`
**Predicate:** `(ir:lambda? node)`
**Accessors:** `(ir:lambda-params node)`, `(ir:lambda-body node)`, `(ir:lambda-rest? node)`

`params` is the raw parameter spec (symbol, proper list, or improper list) — the
analyzer does not normalize it. `rest?` is `#t` when the last binding collects
remaining arguments, derived from `(not (list? params))` for pair specs.

```
(lambda args args)      →  (lambda args (begin ((ref args))) #t)
(lambda (x . rest) x)   →  (lambda (x . rest) (begin ((ref x))) #t)
```

`rest?` is redundant with `params` — either backend could re-derive it — but keeping
it means neither has to. The VM's `env-bind` dispatches on `(symbol? params)` and
`rest?`; the emitter's `make-emitter` splits `params` into a proper-list prefix and a
rest symbol, and stores `rest?` as the function's `variadic?` flag.

The body is always in tail position relative to a call of the lambda.

---

### `(call proc args)`

A procedure application.

```scheme
(ir:call proc-node (list arg1-node arg2-node))
```

**Constructor:** `(ir:call proc args)` — `args` is a list of IR nodes
**Predicate:** `(ir:call? node)`
**Accessors:** `(ir:call-proc node)`, `(ir:call-args node)`

Produced for any pair form the analyzer does not recognize as a special form — which,
after expansion, means every application. `proc` is an arbitrary node, not just a
`ref`, so an immediately-applied lambda is an ordinary `call`:

```
(let ((x 1) (y 2)) (+ x y))
  →  (call (lambda (x y) (begin ((call (ref +) ((ref x) (ref y))))) #f) ((const 1) (const 2)))
```

All arguments are evaluated eagerly left-to-right before the call. No argument is in
tail position.

There is no separate tail-call node — see
[Tail position is not in the IR](#tail-position-is-not-in-the-ir).

---

### `(set! name val)`

A mutation of an existing binding.

```scheme
(ir:set! 'x val-node)    ; (set! q 9) → (set! q (const 9))
```

**Constructor:** `(ir:set! name val)`
**Predicate:** `(ir:set!? node)`
**Accessors:** `(ir:set!-name node)`, `(ir:set!-val node)`

`name` is a bare symbol, not a `ref` node, and may carry a `%gref%` marker.
`val` is never in tail position.

The result is unspecified; both backends produce `#f`. The VM uses `env-set!`, which
walks the environment alist by `assq` and mutates the vector box in place. The emitter
resolves the target the same way it resolves a `ref` and picks one of `move`,
`box-set!`, `set-upvalue` or `set-global`.

Assigning an unbound variable is an error in the VM (`set! on unbound variable`); the
emitter treats an unresolvable name as a global and defers the error to run time.

---

### `(define name val)`

A top-level binding. **Only valid at the top level** — both backends error if
`ir:define` appears in expression position:

- VM: `paal: define used as expression — use paal-eval-program`
- Emitter: `paal-emitter: ir:define in expression position`

```scheme
(ir:define 'fact lambda-node)
```

**Constructor:** `(ir:define name val)`
**Predicate:** `(ir:define? node)`
**Accessors:** `(ir:define-name node)`, `(ir:define-val node)`

A valueless `(define z)` gets `(ir:const #f)`:

```
(define z)  →  (define z (const #f))
```

`analyze-define` accepts both spellings — it turns `(define (name params…) body…)`
into `ir:define` of an `ir:lambda` itself — but in the normal pipeline it never sees
the shorthand, because the expander has already rewritten it:

```
(define (f x) x)   expands to  (define f (lambda (x) x))
                   analyzes to (define f (lambda (x) (begin ((ref x))) #f))
```

Internal defines never reach this node at all. The expander rewrites a body's defines
into `letrec*`, which becomes a lambda plus `set!`s:

```
(define (outer) (define a 1) (define (b y) y) (+ a (b 2)))
  expands to (define outer (lambda () ((lambda (a b) (set! a 1) (set! b (lambda (y) y)) (+ a (b 2))) #f #f)))
```

Each backend handles the recursive-visibility problem its own way:

- `paal-eval-program` publishes a mutable placeholder box under `name` *before*
  evaluating `val`, so a closure built by `val` can see the binding it is being
  bound to (see `docs/architecture.md` § Top-level define semantics).
- `paal-emit-program` emits `define-global`, and globals are looked up by name at
  call time, so the ordering problem does not arise.

`paal-emit-program` also passes `name` down when `val` is an `ir:lambda`, purely so a
profile report can say `fact` rather than `#f`. Nothing in the call path reads it.

---

## Node Summary Table

| Tag | Fields | Produced by |
|-----|--------|-------------|
| `const` | `val` | literal, `quote` |
| `ref` | `name` | symbol in expression position |
| `if` | `test then else` | `if` (else defaults to `#f`) |
| `begin` | `exprs` | `begin`, lambda body wrapper |
| `lambda` | `params body rest?` | `lambda` |
| `call` | `proc args` | any other pair form |
| `set!` | `name val` | `set!` |
| `define` | `name val` | `define` (top-level only) |

Eight node types, and the analyzer is 62 lines. That ratio is the point: everything
else in the language is either desugared before the IR or decided after it.

## Marked names

The `name` field of `ref`, `set!` and `define` is not always a source identifier. A
free identifier in a macro template is rewritten by the expander to `%gref%<name>`,
marking it as "resolve where the macro was *defined* — the top level — not through
whatever bindings exist at the use site". This is paal's hygiene mechanism, and it
leaks into the IR as an ordinary symbol:

```scheme
(define (helper x) (* x 2))
(define-syntax twice (syntax-rules () ((_ e) (helper e))))
(twice 21)
```

```
(define helper (lambda (x) (begin ((call (ref *) ((ref x) (const 2))))) #f))
(const #f)
(call (ref %gref%helper) ((const 21)))
```

Both backends strip the marker with `gref-name` (exported by the expander) and
resolve the stripped name in the top-level environment:

- The VM checks it only on an `assq` miss in `env-lookup` / `env-set!`, so ordinary
  lookups pay nothing — a marked name is synthetic and never appears in a local frame.
- The emitter checks it *first*, in `emit-ref!` and in the `set!` case, before
  consulting locals — a use-site local of the same name must not shadow it.

The `(const #f)` line above is the `define-syntax` form: the expander consumes the
definition and leaves `(quote #f)` behind.

Any new backend must handle marked names, or macros that reference top-level
procedures will break in ways that look like scoping bugs.

## What the IR deliberately leaves out

The IR is a *core-forms* representation, not an analysis product. Four things a
reader might expect to find are absent by design.

### Derived syntax is not in the IR

`let`, `let*`, `letrec`, named `let`, `cond`, `case`, `do`, `when`, `unless`, `and`,
`or`, quasiquote, `define-record-type`, `guard`, `parameterize` — none have nodes.
The expander reduces all of them to the seven core forms plus applications, so the
analyzer's `case` needs only `quote`, `if`, `begin`, `lambda`, `set!` and `define`,
with everything else falling through to `call`.

```
(cond ((> 1 2) 'a) (else 'b))
  →  (if (call (ref >) ((const 1) (const 2))) (begin ((const a))) (begin ((const b))))
```

A named `let` shows how far the reduction goes — it becomes the letrec pattern of a
lambda whose parameter is `set!` to a lambda:

```
(let loop ((i 0)) (if (< i 3) (loop (+ i 1)) i))
  →  (call (lambda (loop)
             (begin ((set! loop (lambda (i) (begin ((if (call (ref <) ((ref i) (const 3)))
                                                        (call (ref loop) ((call (ref +) ((ref i) (const 1)))))
                                                        (ref i)))) #f))
                     (call (ref loop) ((const 0)))))
             #f)
           ((const #f)))
```

This is the shape that motivates the emitter's boxing analysis, below.

### Tail position is not in the IR

There is no `tailcall` node. Tail position is a *property of context*, not of a node,
so each backend threads it down as a parameter rather than baking it into the tree:

- `paal-eval` takes a `tail?` flag; when `tail?` is true an `ir:call` returns a
  tagged thunk for the trampoline instead of applying immediately.
- `emit-node!` takes a `tail?` parameter and emits `tail-call` instead of `call`.

Both propagate it identically: into both arms of `if`, into the last expression of
`begin`, into a lambda body (always true), and into the last top-level form. Never
into an `if` test, a `call` argument, a `set!` value, or a `define` value.

Annotating the IR instead would mean the analyzer computing tail position for a
backend that might not want it, and two places to keep in step rather than one.

### Reference resolution is not in the IR

There are no `local-ref`, `upvalue-ref` or `global-ref` nodes. A `ref` carries a
symbol, and resolution belongs to whoever is generating code:

- The VM resolves every name at run time by `assq` down an environment alist.
- The emitter resolves at compile time, in `resolve`, innermost-first: local register,
  then upvalue (captured through the parent-emitter chain), then global.

The emitter also decides which parameters need **boxing**, in `must-box-vars`: a
parameter must live in a mutable box if it is both `set!` somewhere in the body *and*
referenced inside a nested `ir:lambda`. In the named-`let` expansion above, `loop` is
exactly that, so it is boxed and the closure and the frame share one cell. Capturing
by value instead would give each closure a private copy and silently drop the write.

That analysis walks the IR — `collect-set-targets`, `collect-captured` and
`collect-free-refs-in-body` each have a case per node type — but it produces emitter
state, not IR. Nothing is written back into the tree.

### Source locations, types, and optimization are not in the IR

Nodes carry no line/column information, so error messages name values rather than
source positions. Nodes carry no type information. And there are no optimization
passes at all: the analyzer is purely structural, and `paal-emit-program` emits from
the tree as written — no constant folding, no inlining, no dead-code elimination.

This is a deliberate contrast with kaappi's Zig IR (`kaappi/src/ir.zig`), which runs
three analysis and five optimization passes. Paal's IR is sized for a self-hosting
bootstrap: small enough that a paal-compiled copy of the analyzer and emitter can
compile paal itself.

## Why the bytecode backend added no new node types

An earlier revision of this document predicted that the bytecode work would add
`tailcall`, `upvalue-ref`/`upvalue-set!` and `local-ref`/`local-set!` nodes. The
bytecode compiler and VM are both complete (`docs/bootstrapping.md` bootstrap stages
3 and 4) and **none of them were added**. Each turned out to belong on one side of
the waist or the other:

| Predicted node | Where it actually lives |
|----------------|-------------------------|
| `tailcall` | `tail?` parameter threaded through `emit-node!` |
| `upvalue-ref` / `upvalue-set!` | `resolve` + `capture-upvalue!` in the emitter |
| `local-ref` / `local-set!` | `resolve` against the emitter's `locals` alist |

The reason is the same in all three cases: they are facts about *how a particular
backend allocates storage*, and the tree-walking VM allocates storage differently.
Putting them in the IR would have forced the analyzer to model registers and capture
chains that only one of the two consumers has, and would have made the tree-walking
VM the odd one out in the very place it earns its keep as a cross-check.

The IR has been stable at eight node types since it was introduced. `docs/TODO.md`
records no planned additions.

## Adding a node type

If a future stage does need one, every one of these has to change together — the IR
is small enough that there is no dispatch table to forget, and correspondingly nothing
that will remind you:

1. `lib/kaappi/paal/ir.sld` — constructor, predicate, accessors, and the export list
   (four separate places in the `export` form).
2. `lib/kaappi/paal/compiler.sld` — the `case` in `paal-analyze` that produces it.
3. `lib/kaappi/paal/vm.sld` — a clause in `paal-eval`, before the `else` that raises
   `unknown IR node`.
4. `lib/kaappi/paal/emitter.sld` — a clause in `emit-node!`, **plus a case in each of
   the three boxing-analysis walkers** (`collect-set-targets`, `collect-captured`,
   `collect-free-refs-in-body`). These fall through to `'()` on an unknown node rather
   than erroring, so a missed case here is silent: a variable that should be boxed
   quietly is not, and a closure drops a write.
5. Decide whether the node is a tail position, and thread `tail?` accordingly in both
   backends.
6. This document. If the analyzer's contract changes, also
   `docs/architecture.md` § Pipeline Stage 3 — Compiler (Analyzer).

Both self-hosting copies of a library must agree on representation, so a node type
added here also needs the pipeline cache rebuilt (`make pbc-pipeline`).
