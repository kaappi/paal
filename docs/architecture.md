# Paal Kaappi — Architecture

## Overview

Paal is a self-hosting Scheme compiler written in Kaappi Scheme. It bootstraps using
the `kaappi` interpreter and will eventually compile its own source, producing the
`pkaappi` binary.

## Compilation Pipeline

```
Source text
    │
    ▼
┌─────────────────────┐
│  Reader             │  (kaappi paal reader)
│  paal-read-string   │
│  paal-read-file     │
└─────────┬───────────┘
          │  list of S-expressions
          ▼
┌─────────────────────┐
│  Expander           │  (kaappi paal expander)
│  paal-expand-all    │
└─────────┬───────────┘
          │  core-form S-expressions
          │  (quote if begin lambda set! define + calls)
          ▼
┌─────────────────────┐
│  Compiler/Analyzer  │  (kaappi paal compiler)
│  paal-analyze-all   │
└─────────┬───────────┘
          │  IR node tree
          ▼
┌─────────────────────┐
│  VM                 │  (kaappi paal vm)
│  paal-eval-program  │
└─────────┬───────────┘
          │
          ▼
       result value
```

Each stage is a separate `define-library` importable independently:

| Library | File | Stage |
|---------|------|-------|
| `(kaappi paal reader)` | `lib/kaappi/paal/reader.sld` | 1 |
| `(kaappi paal expander)` | `lib/kaappi/paal/expander.sld` | 2 |
| `(kaappi paal compiler)` | `lib/kaappi/paal/compiler.sld` | 3 |
| `(kaappi paal vm)` | `lib/kaappi/paal/vm.sld` | 4 |
| `(kaappi paal ir)` | `lib/kaappi/paal/ir.sld` | (shared) |
| `(kaappi paal)` | `lib/kaappi/paal.sld` | public API |

---

## Stage 1 — Reader

**Input:** source text (string or port)  
**Output:** list of S-expressions

A self-hosted character-level recursive descent reader. Handles all token types
needed for paal's own source and most R7RS programs.

**Supported:** `( )` lists, dotted pairs, `#( )` vectors, `' ` \` , ,@` abbreviations,
booleans (`#t` `#f` `#true` `#false`), characters (`#\space` `#\newline` `#\xHH` etc.),
strings with `\n \t \r \a \b \" \\ \xHH;` escapes, numbers (via `string->number`),
symbols, line comments (`;`), block comments (`#| … |#` nested), datum comments (`#;`),
radix prefixes (`#b` `#o` `#x` `#d`), exactness prefixes (`#e` `#i`),
bytevectors (`#u8( … )`), `|…|` bar-quoted symbols.

**Not yet supported:** datum labels (`#N=` `#N#`).

Key exports: `paal-read-string`, `paal-read-file`, `paal-read-all`, `paal-read`

---

## Stage 2 — Expander

**Input:** list of S-expressions (possibly containing derived forms)  
**Output:** list of S-expressions in core form only

Rewrites every derived form to a combination of core forms. The expander is purely
structural — it transforms S-expressions to S-expressions with no semantic analysis.

**Core forms** (passed through, with sub-form recursion):

| Form | How handled |
|------|-------------|
| `(quote datum)` | passed through unchanged |
| `(lambda params body…)` | body expanded via `expand-body` (see below) |
| `(define name val)` | val recursively expanded |
| `(define (name params…) body…)` | body expanded via `expand-body` |
| `(set! name val)` | val recursively expanded |
| `(if test then)` / `(if test then else)` | all sub-forms recursively expanded |
| `(begin e…)` | all sub-forms recursively expanded |
| `(f a…)` | all elements recursively expanded |

**Derived forms** (desugared, then re-expanded):

| Form | Desugars to |
|------|-------------|
| `(let ((v e)…) body…)` | `((lambda (v…) body…) e…)` |
| `(let name ((v e)…) body…)` | `(letrec ((name (lambda (v…) body…))) (name e…))` |
| `(let* () body…)` | `(begin body…)` |
| `(let* ((v e) rest…) body…)` | `(let ((v e)) (let* rest… body…))` |
| `(letrec ((v e)…) body…)` | `(let ((v #f)…) (set! v e)… body…)` |
| `(and)` | `#t` |
| `(and e)` | `e` |
| `(and e rest…)` | `(if e (and rest…) #f)` |
| `(or)` | `#f` |
| `(or e)` | `e` |
| `(or e rest…)` | `(let ((_t e)) (if _t _t (or rest…)))` |
| `(when t body…)` | `(if t (begin body…))` |
| `(unless t body…)` | `(if (not t) (begin body…))` |
| `(cond …)` | nested `if`s (see expander.sld) |
| `(case key …)` | `(let ((_k key)) (cond …))` with `memv` |
| `` `form `` | `cons`/`append`/`list` construction |
| `(do …)` | named-let loop |
| `(define-record-type name (ctor f…) pred (f acc [mut])…)` | `begin` of `define`s using vector storage |
| `(define-library name decl…)` | `begin` of the library's `(begin …)` bodies |
| `(import …)` / `(export …)` | `(quote #f)` — no-op during bootstrap |
| `(guard (v clause…) body…)` | `(%paal-guard-run (lambda () body…) (lambda (v) (cond clause… [else (raise v)])))` |

**Internal defines:** `expand-body` processes a lambda/let body and hoists any leading
`(define …)` forms to `letrec*` (R7RS §5.3.2). Both the `lambda` and shorthand
`(define (name …) body…)` handlers call `expand-body`.

**Top-level begin splicing:** `paal-expand-all` splices top-level `(begin …)` results.
This is necessary for `define-record-type` and `define-library` desugaring, which both
produce a `(begin (define …) …)` form that must be seen as multiple top-level forms by
`paal-eval-program`, not as a single begin expression.

**Record type encoding:** vectors with layout `[type-tag, field0, field1, …]`.
The type-tag is `(list '<name>)` — a fresh pair allocated once, so `eq?` identity
serves as the type test in the predicate. Accessor: `(vector-ref obj i)`. Mutator:
`(vector-set! obj i val)`. Mutable fields declared as `(field acc mut)` in the spec.

**Hygiene:** fresh temporaries introduced by `or`, `cond =>`, and `case` use
`fresh-name` (a module-level counter) to avoid variable capture.

**Quasiquote note:** `expand-qq` uses explicit `list`/`cons` calls rather than
quasiquote templates. Kaappi's own expander misinterprets `unquote-splicing` as a
special form when it appears as a literal symbol inside a template, even inside
`(quote …)`. The explicit construction avoids this.

---

## Stage 3 — Compiler (Analyzer)

**Input:** list of core S-expressions  
**Output:** list of IR nodes (see `docs/ir.md`)

A recursive descent analyzer that converts each core form to a typed IR node. No
optimization passes at this stage; analysis is purely structural.

Special cases in the analyzer:

- **`(lambda params body…)`** — `params` may be a proper list (fixed arity), the empty
  list (nullary), a symbol (pure variadic), or an improper list `(x . rest)` (mixed).
  `rest?` is set to `#t` for symbol and improper-list forms.
- **`(define (name params…) body…)`** shorthand — desugared to
  `ir:define name (ir:lambda params body rest?)`. The `rest?` flag is derived from
  `(not (list? params))`, matching the improper-list handling above.
- **`(if test then)`** — missing `else` arm defaults to `ir:const #f`.

---

## Stage 4 — VM (Bootstrap)

**Input:** list of IR nodes  
**Output:** result value of the last expression

A tree-walking interpreter with proper tail calls via a tagged-thunk trampoline.
See `docs/ir.md` for the node types it handles.

### Tail call optimization

`paal-eval` takes a `tail?` flag. In tail position with `tail? = #t`, an `ir:call`
node returns a tagged thunk `(cons %thunk-tag (lambda () (apply proc args)))` instead
of applying immediately. The trampoline in `paal-eval-program` (and at every non-tail
call site) forces thunks in a loop until a plain value emerges — bounding stack depth
to O(1) per tail call regardless of iteration count.

**Tail positions** (inherit parent's `tail?`):
- Both arms of `ir:if`
- Last expression of `ir:begin`
- Lambda body (always `tail? = #t`)
- Top-level expressions in `paal-eval-program`

**Non-tail positions** (always `tail? = #f`): `ir:if` test, all `ir:call` arguments,
`ir:set!` value, `ir:define` value.

The tag `%thunk-tag` is a unique pair `(list 'paal-thunk)` allocated once; `thunk?`
is a single `eq?` check on the `car`. This distinguishes paal thunks from user-returned
pairs without wrapping every value.

### Environment model

Environments are association lists of `(name . #(val))` pairs. The `#(val)` vector
box is the mutable cell — `vector-ref`/`vector-set!` are used for reads and writes.
This lets `set!` work correctly and ensures recursive top-level defines see themselves.

```
env = ((name1 . #(val1)) (name2 . #(val2)) …)
```

`env-lookup` uses `assq` and dereferences the box.  
`env-extend` prepends a new boxed entry (shadowing).  
`env-set!` finds the entry with `assq` and mutates the box.

### Top-level define semantics

`paal-eval-program` processes a sequence of IR nodes. For `ir:define`:

1. Allocate a placeholder box `#(#f)`.
2. Extend the environment with `(name . placeholder)` **before** evaluating the value.
3. Evaluate the value expression in the extended env.
4. Fill the placeholder: `(vector-set! box 0 val)`.

Step 2 makes the binding forward-visible so recursive and mutually-recursive top-level
defines work without needing `letrec` semantics.

### Lambda binding and rest params

`env-bind` handles all parameter forms:

| `params` | `rest?` | Behavior |
|----------|---------|----------|
| symbol | `#t` | bind symbol to entire args list |
| `'()` | `#f` | no bindings |
| proper list | `#f` | pair-wise binding |
| improper list `(x . rest)` | `#t` | pair-wise until tail; tail symbol gets remaining args |

### Initial environment

`paal-initial-env` seeds ~70 procedures from the host runtime: arithmetic, boolean,
list operations, vectors, strings, characters, I/O, exceptions, `call/cc`,
`dynamic-wind`, `call-with-values`. Also provides `gensym` as a Scheme-implemented
counter (kaappi has no built-in `gensym`).

### The trampoline boundary

A paal lambda whose body is a tail call returns a *thunk*, not a value; the caller
forces it. That contract holds for paal-to-paal calls, where `ir:call` does the
forcing — but a HOST higher-order procedure invoking a paal closure knows nothing
about it and receives the raw thunk.

Any HOST binding in `paal-initial-env` that calls a paal closure must therefore
trampoline the result itself, and must do so *inside* whatever dynamic context it is
establishing. Two bindings need this:

- `call-with-values` — forces the producer with `trampoline-values`, which forces in a
  multiple-value context so `(values …)` in tail position survives. Plain `trampoline`
  would collapse it to one value, and the unforced thunk would reach the consumer as a
  single argument, so `(lambda (x y) …)` would be applied to one argument.
- `%paal-guard-run` — forces body and handler with `trampoline` *within* the `guard`.
  Returning an unforced thunk would defer the body's real work until after the guard's
  extent had exited, letting any exception escape uncaught.

The same limitation is why `map`, `for-each`, `apply` and friends are paal-compiled in
`pkaappi-make-globals` for the bytecode path rather than inherited from the host.

---

## Exceptions in the bytecode VM

`guard` cannot be an ordinary binding in the bytecode path. A HOST procedure cannot
invoke a paal closure — paal closures are `<closure>` records that only the dispatch
loop knows how to enter — and `guard` must run a body thunk and then, on an exception,
a handler. So the expander compiles `(guard …)` into a call to `%paal-guard-run`, whose
value in globals is a *marker*, and `do-call!` performs the whole operation itself.

**Re-entrant calls.** `paal-call-value` enters a paal closure from HOST code by running
a nested dispatch loop whose frame list is a singleton, so `return` hands the value
straight back rather than falling through into the interrupted program. Its register
base must sit at or above the caller's high-water mark; since the emitter allocates a
call's base as the next free register, everything at or above `base + 1 + nargs` is
unused by every live frame. Closure upvalues and boxes are heap objects, so values
shared across the boundary stay intact.

**raise.** paal's `raise` is a HOST procedure that raises a HOST exception carrying the
paal value in a tagged wrapper. The wrapper keeps arbitrary raised values (strings,
numbers, records) distinguishable from HOST conditions, so a handler receives exactly
what was raised. Unwrapping leaves HOST conditions untouched, so `guard` also catches
errors from primitives such as `car`, as R7RS requires. An escape that reaches the top
of `paal-run-bc` is unwrapped and re-raised, so callers see the value the program
actually raised rather than VM plumbing.

**Why interned symbols.** Both markers — the guard marker and the raise wrapper's tag —
are interned symbols rather than record types or freshly allocated `(list 'tag)` pairs.
Self-hosting keeps two copies of `(kaappi paal vm-bc)` live at once: the HOST one and
the paal-compiled one in `cache/paal-vm-bc.pbc`. A record type defined in one copy is
unrelated to the record type defined in the other, so the paal-compiled VM would fail
to recognize a marker installed by the HOST library. Symbols intern to a single object
in both. For the same reason the *logic* stays in `do-call!`: whichever copy is running
the VM must supply both the exception catch and the closure callbacks, since each can
only enter closures its own copy created.

**Known limits.** Nesting is bounded by the host: kaappi v0.22.0 mishandles more than
63 dynamically nested `guard` forms — at depth 64 the innermost handler is skipped and
an outer one catches instead. It reproduces in plain kaappi with no paal involved, and
paal inherits it by delegating to HOST `guard`; paal's effective ceiling is a few
levels lower still, since `paal-run-bc` and `run-guard!` consume host levels of their
own. `raise-continuable` cannot resume, so it behaves as `raise`, and an unmatched
clause re-raises from the handler's dynamic environment rather than the original one.

---

## Public API (`lib/kaappi/paal.sld`)

High-level entry points that run the full pipeline:

```scheme
(pkaappi-run-string src)  ; string → result
(pkaappi-run-file path)   ; file path → result
```

Individual stage exports are also re-exported for embedding or incremental use.
