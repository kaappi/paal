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
| `(parameterize ((p v)…) body…)` | `(%paal-parameterize (list p…) (list v…) (lambda () body…))` |

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

Because the tag is allocated per compiled copy, a record built by one copy of a
library is unrecognizable to another copy of the same library — which matters
during self-hosting. See "Values that cross the HOST boundary" below; `<closure>`
and `<bytecode-function>` avoid `define-record-type` for exactly this reason.

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

The same limitation is why `map`, `for-each` and friends are paal-compiled in
`pkaappi-make-globals` for the bytecode path rather than inherited from the host.
`apply` cannot even be written that way — see below.

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

**Why interned symbols.** The markers — guard, apply, and the raise wrapper's tag —
are interned symbols rather than record types or freshly allocated `(list 'tag)` pairs,
so that both copies of the library agree on them. See "Values that cross the HOST
boundary" below. The *logic* stays in `do-call!` for a related reason: whichever copy
is running the VM should supply the exception catch and the closure callbacks, rather
than depending on a HOST procedure captured in globals to do it.

**Known limits.** Nesting is bounded by the host: kaappi v0.22.0 mishandles more than
63 dynamically nested `guard` forms — at depth 64 the innermost handler is skipped and
an outer one catches instead. It reproduces in plain kaappi with no paal involved —
kaappi/kaappi#1886, where the `MAX_HANDLERS = 64` overflow surfaces as a *catchable*
error, so an enclosing `guard` swallows it. Paal inherits the ceiling by delegating to
HOST `guard`, and its own is a few levels lower still, since `paal-run-bc` and
`run-guard!` consume host levels. Recheck this paragraph once that issue is fixed —
no test covers the ceiling, since the threshold is host behavior rather than paal's.
`raise-continuable` cannot resume, so it behaves as `raise`, and an unmatched clause
re-raises from the handler's dynamic environment rather than the original one.

---

## apply

`apply` is a marker too, for a different reason: the `call` instruction carries a fixed
`nargs` operand, so no procedure written in paal can issue a call whose argument count
is only known at run time. Written in paal it has to dispatch on `(length args)` through
a hand-unrolled `cond`, one arm per arity — which is where its old 16-argument ceiling
came from.

`do-call!` instead rewrites the call in place: the callee slot gets the real procedure,
the spread arguments follow it, and `do-call!` runs again on the real callee. Writing
above `abs-base + nargs` is safe for the same reason `paal-call-value`'s window is —
the emitter allocates a call's base as the next free register — and `abs-base + 1` is
exactly where the callee's frame expects its arguments.

Re-dispatching rather than calling `paal-call-value` is deliberate: it keeps `tail?`
meaningful, so `(apply f args)` in tail position stays a tail call. Entering a nested
dispatch loop would have grown the host stack once per iteration.

---

## Parameter objects

A parameter is a closure over a two-slot cell `#(value converter)`. Calling it with
no arguments reads the value; calling it with `%paal-param-key` — a unique value only
`make-parameter` and `%paal-parameterize` hold — returns the cell. That key is what
lets `parameterize` rebind a parameter without a registry mapping parameters to cells,
which would keep every parameter ever created alive.

HOST `make-parameter` cannot be reused. A HOST parameter is only rebindable through
HOST `parameterize`, which is syntax rather than a procedure, so no paal-side code can
install a value into one.

`%paal-parameterize` reads the old values, installs the new ones through each
parameter's converter, runs the thunk, and restores. Restoration happens on a raise
as well, via `guard`:

```scheme
(let ((result (guard (e (#t (restore!) (raise e)))
                (thunk))))
  (restore!)
  result)
```

This needs no VM marker of its own — unlike `guard`, which had to be one. `guard`
already supplies the unwind protection, and a raise is the only non-local exit from a
dynamic extent that paal has, since there are no continuations for paal closures. If
paal ever gains `call/cc` over paal closures, this is one of the places that has to be
revisited, along with `dynamic-wind`.

Both pipelines provide it: the tree-walking VM as HOST procedures in
`paal-initial-env` (forcing the trampoline on the converter and on the thunk, the
latter *inside* the guard), the bytecode VM as paal source compiled into globals by
`pkaappi-make-globals`, which overrides the HOST bindings.

---

## Values that cross the HOST boundary

Self-hosting runs **two copies of every pipeline library at once**: the HOST copy that
kaappi loaded from `.sld` source, and the paal-compiled copy loaded from `cache/*.pbc`.
`pkaappi-self-run-file` mixes them deliberately — the dispatch string resolves
`paal-run-bc` to the paal-compiled copy while `pkaappi-make-globals` is still the HOST
procedure, since `paal.sld` is not in `%paal-lib-files`.

So the globals table a self-hosted program runs against is populated by one copy and
consumed by another. Any value that lands in it must be recognizable to both.

**`define-record-type` cannot express such a value.** Under HOST kaappi it produces an
opaque native record; paal's own expander desugars it to a vector tagged with a freshly
allocated `(list '<name>)` pair. Two copies therefore disagree on representation *and*
on tag identity. A record made by one is simply not the same type to the other.

The rule: **anything that crosses is a vector tagged with an interned symbol.** Symbols
intern to one object in both copies, and the vector layout is identical because both
copies compile the same explicit `vector` / `vector-ref` code.

| Value | Tag | Defined in |
|-------|-----|------------|
| closure | `%paal-closure` | `frame.sld` |
| bytecode function | `%paal-bytecode-function` | `bytecode.sld` |
| guard marker | `%paal-vm-guard-run` | `vm-bc.sld` |
| apply marker | `%paal-vm-apply` | `vm-bc.sld` |
| raise wrapper | `%paal-vm-escape` | `vm-bc.sld` |

`<frame>` stays a `define-record-type`: frames are created and consumed inside a single
VM invocation and never enter globals.

The cost is that a user vector of the right length whose first slot is one of those
symbols would be mistaken for the internal type. The gain is that closures built by
either copy are callable by either — without it, every procedure `pkaappi-make-globals`
installs by paal-compiling it (`map`, `for-each`, `apply`, `filter`, `vector-map`,
`string-map`, `values`/`call-with-values`, and the promise system) failed under
`pkaappi-self-run-file` with `not a callable`. That was kaappi/paal#1.

---

## Public API (`lib/kaappi/paal.sld`)

High-level entry points that run the full pipeline:

```scheme
(pkaappi-run-string src)  ; string → result
(pkaappi-run-file path)   ; file path → result
```

Individual stage exports are also re-exported for embedding or incremental use.
