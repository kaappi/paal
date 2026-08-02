# Paal Kaappi — Architecture

## Overview

Paal is a self-hosting Scheme compiler written in Kaappi Scheme. It bootstraps using
the `kaappi` interpreter and will eventually compile its own source, producing the
`paal` binary.

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
│  paal-expand-all    │  ← (kaappi paal embedded) supplies the source of
└─────────┬───────────┘    bundled libraries, ahead of the library path
          │  core-form S-expressions
          │  (quote if begin lambda set! define + calls)
          ▼
┌─────────────────────┐
│  Compiler/Analyzer  │  (kaappi paal compiler)
│  paal-analyze-all   │
└─────────┬───────────┘
          │  IR node tree — node types from (kaappi paal ir)
          ├─────────────────────────────┐
          ▼                             ▼
┌─────────────────────┐       ┌─────────────────────┐
│  Tree-walking VM    │       │  Emitter            │  (kaappi paal emitter)
│  paal-eval-program  │       │  paal-emit-program  │
└─────────┬───────────┘       └─────────┬───────────┘
          │  (kaappi paal vm)           │  bytecode-function
          │  bootstrap / reference      │  (kaappi paal bytecode)
          │                             │◄───────► .pbc file
          │                             │          (kaappi paal serializer)
          │                             ▼
          │                   ┌─────────────────────┐
          │                   │  Bytecode VM        │  (kaappi paal vm-bc)
          │                   │  paal-run-bc        │  (kaappi paal frame)
          │                   └─────────┬───────────┘
          │                             │
          └──────────────┬──────────────┘
                         ▼
                   result value
```

The pipeline forks at the IR: both backends consume the same node tree, and both must
handle every node type. The CLI's default file path takes the right-hand branch — the
tree-walking VM is kept as the simpler reference implementation, not as the production
one. For the same fork described from the IR's side, see `docs/ir.md` § Where the IR
sits.

Each stage is a separate `define-library` importable independently:

| Library | File | Role |
|---------|------|------|
| `(kaappi paal reader)` | `lib/kaappi/paal/reader.sld` | Pipeline stage 1 — text → S-expressions |
| `(kaappi paal expander)` | `lib/kaappi/paal/expander.sld` | Pipeline stage 2 — macro expansion → core forms |
| `(kaappi paal compiler)` | `lib/kaappi/paal/compiler.sld` | Pipeline stage 3 — core forms → IR |
| `(kaappi paal vm)` | `lib/kaappi/paal/vm.sld` | Pipeline stage 4 — tree-walking IR interpreter |
| `(kaappi paal emitter)` | `lib/kaappi/paal/emitter.sld` | IR → bytecode (bytecode path) |
| `(kaappi paal vm-bc)` | `lib/kaappi/paal/vm-bc.sld` | bytecode dispatch loop (bytecode path) |
| `(kaappi paal ir)` | `lib/kaappi/paal/ir.sld` | shared — IR node constructors and accessors |
| `(kaappi paal bytecode)` | `lib/kaappi/paal/bytecode.sld` | shared — `<bytecode-function>` and the ISA |
| `(kaappi paal frame)` | `lib/kaappi/paal/frame.sld` | shared — closures and call frames for the bytecode VM |
| `(kaappi paal serializer)` | `lib/kaappi/paal/serializer.sld` | `.pbc` read/write — a `(paal-pbc <version>)` header datum ahead of the function; the reader accepts headerless files and refuses versions from the future |
| `(kaappi paal formatter)` | `lib/kaappi/paal/formatter.sld` | `fmt` subcommand |
| `(kaappi paal embedded)` | `lib/kaappi/paal/embedded.sld` | bundled library source (outside the pipeline) |
| `(kaappi paal)` | `lib/kaappi/paal.sld` | public API |

Only the numbered pipeline stages have a walkthrough section below; the emitter and bytecode
VM are documented by topic instead (call convention, exceptions, the wind stack, the
debugger), since most of what is interesting about them cuts across the whole path.

**Numbering.** A *pipeline stage* is a position in the diagram above; the term is used
only in this document and in the header comment of the matching `.sld`. Three other
schemes number other things and none of them line up: `docs/bootstrapping.md` has
*bootstrap stages* (roadmap milestones — "bootstrap stage 6 complete") and *tiers*
(rungs of the bootstrap chain), and `docs/TODO.md` has *phases* (batches of feature
work). These used to be spelled "Stage *N*" indiscriminately, so a bare "Stage 3" in
git history or an old issue may mean any of them — check which document it came from.

---

## Pipeline Stage 1 — Reader

**Input:** source text (string or port)  
**Output:** list of S-expressions

A self-hosted character-level recursive descent reader. Handles all token types
needed for paal's own source and most R7RS programs.

**Supported:** `( )` lists, dotted pairs, `#( )` vectors, `' ` \` , ,@` abbreviations,
booleans (`#t` `#f` `#true` `#false`), characters (`#\space` `#\newline` `#\xHH` etc.),
strings with `\n \t \r \a \b \" \\ \xHH;` escapes, numbers (via `string->number`,
except complex literals, which the reader splits into real and imaginary parts
itself — the host's `string->number` mishandles them, kaappi/kaappi#1911),
symbols, line comments (`;`), block comments (`#| … |#` nested), datum comments (`#;`),
radix prefixes (`#b` `#o` `#x` `#d`), exactness prefixes (`#e` `#i`),
bytevectors (`#u8( … )`), `|…|` bar-quoted symbols.

**Datum labels** (`#N=` `#N#`) cover shared and circular structure. A reference
inside the datum that defines it cannot be resolved when read, so `#N=` registers a
placeholder, reads the datum, then walks it replacing the placeholder with the
finished datum — carrying a `seen` list, since the structure is circular by then.
References after a definition resolve on the spot, so only pairs and vectors are
walked. Labels are scoped to one `paal-read` call, which is the outermost datum.

Key exports: `paal-read-string`, `paal-read-file`, `paal-read-all`, `paal-read`

---

## Pipeline Stage 2 — Expander

**Input:** list of S-expressions (possibly containing derived forms)  
**Output:** list of S-expressions in core form only

Rewrites every derived form to a combination of core forms. The expander is *not*
purely structural any more: expansion threads an immutable **compile-time
environment** (cenv) recording what each identifier in scope denotes, and dispatch
consults it before the keyword table — so a lexical binding shadows a keyword the
way R7RS requires, and `(let ((if list)) (if 1 2 3))` is a call. The exported
`paal-expand` keeps its arity; the cenv threads through the internal `expand-form`.

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
| `(let name ((v e)…) body…)` | `(letrec* ((name (lambda (v…) body…))) (name e…))` |
| `(let* () body…)` | `(begin body…)` |
| `(let* ((v e) rest…) body…)` | `(let ((v e)) (let* rest… body…))` |
| `(letrec* ((v e)…) body…)` | `(let ((v #f)…) (set! v e)… body…)` |
| `(letrec ((v e)…) body…)` | `(let ((v #f)…) (let ((t e)…) (set! v t)… body…))` — inits before any assignment, R7RS 4.2.2 |
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
| `(define-library name decl…)` | `begin` of the library's body forms, after `normalize-decls` flattens `cond-expand` and `include-library-declarations` (see § Library declarations) |
| `(import spec…)` | the named libraries' definitions, renamed per library, spliced in front — and the program's import grants recorded for the scope check (see § Import scope) |
| `(export …)` at top level | `(quote #f)` — outside a `define-library` there is nothing to act on; inside one, `install-library!` reads the declaration directly |
| `(guard (v clause…) body…)` | `(%paal-guard-run (lambda () body…) (lambda (v) (cond clause… [else %paal-guard-no-match])))` |
| `(parameterize ((p v)…) body…)` | `(%paal-parameterize (list p…) (list v…) (lambda () body…))` |

**The compile-time environment.** A cenv is an alist from names to denotations:

| Denotation | Meaning |
|------|---------|
| `(variable . rename?)` | a lexical variable — a lambda formal, or a hygiene rename of one |
| `(macro . alias)` | a local macro; `alias` names its `%mac-<name>-<n>` slot in the global macro table |
| `(global)` | explicitly the top level |

Every derived binder desugars to `lambda`, so formals extension is the single binding
point and threading stays cheap; the top level fast-paths on the empty cenv. Dispatch
looks the head up first: a head denoting a variable is a call whatever it spells;
`else` and `=>` lose their special role inside `cond`/`case` when lexically bound
(`(let ((=> #f)) (cond (#t => 'ok)))` answers `ok`); and a lambda formal spelling one
of the six analyzer head symbols (`quote lambda define set! if begin`) is α-renamed to
`%kw-…` on the spot, so the analyzer downstream never mistakes a variable for syntax.

**Body definition contexts.** `expand-body` processes a lambda/let body: leading
`(define …)` and `(define-values …)` forms hoist to `letrec*` (R7RS §5.3.2), and a
leading `(define-syntax …)` installs a *body-scoped* macro — a fresh `%mac-` alias in
the global macro table for the extent of the body, with the cenv carrying source name
→ alias, so it cannot leak into the program (the pollution that once darkened a whole
conformance section). A phase-1 pre-scan collects definition names first, so
definitions may be mutually recursive and a body-level macro may be used before its
textual position. A macro use at the head of a body is expanded one step in case it
*produces* a definition (R7RS 5.3.2 requires macro-produced defines to bind).
`let-syntax`, `letrec-syntax`, `let-values` and `let*-values` bodies are bodies in
this sense — definitions are legal at their heads.

**Pattern matching.** `syntax-rules` literals match by *denotation*: a literal in a
pattern matches an input identifier only when the use-site and definition-site
denotations agree — unbound at both (the top level) is one denotation, anything else
must be the same binding (kaappi's `literal_bound` analogue, under paal's
approximation). Vector patterns and templates work (`#(a b …)` matches vectors
element-wise). A custom ellipsis — `(syntax-rules ell (lit …) clause …)` — is honored
through spec parsing, matching, instantiation and the rename walkers; a literal
outranks `_` and outranks an ellipsis position; improper-tail ellipsis patterns
(`(a … . tail)`) match per R7RS.

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

`syntax-rules` templates get the same treatment. Before instantiating a template,
the expander collects the identifiers that template *binds* — `lambda` formals,
`let`/`let*`/`letrec`/`letrec*`/`let-values` bindings, named-let loop names, `do`
variables, `guard` variables, and `define`/`define-values`/`define-syntax` binders
(a template may expand into definitions) — and renames each per expansion. Pattern
variables are excluded, since those names come from the use site. The renames are
added to the same environment `instantiate-template` already consults for pattern
variables, so the substitution costs nothing extra.

Without it, a template introducing `(let ((tmp a)) …)` shadows a user's `tmp`:
`swap!` written the textbook way silently did nothing when called as `(swap! x tmp)`.

Instantiation is *quote-aware*: the two substitutions part ways under `quote`.
Pattern-variable substitutions still apply — R7RS says a quoted datum in a template
transcribes its pattern variables — while hygiene renames are suppressed, so a
template's `'tmp` is the symbol `tmp`, never a rename of it.

Keyword capture is prevented from the other side by `%core%` marks: during the same
classification walk, a template's syntactic keywords are marked `%core%<name>` and
stripped again at dispatch, so a use site that binds `let` cannot capture a
template's `let`. Keywords the *definition* environment itself shadows are not
marked — that shadowing is the macro author's, and it holds. Excluded from marking:
quote and quasiquote internals, the ellipsis, `_`, `syntax-rules` itself, and the
library forms. Neither `%core%` nor `%kw-` nor `%mac-` ever reaches the IR — a leak
assertion in the suite pins all three.

That is the capture half. The other half — referential transparency — is handled by
marking a template's *free* identifiers `%gref%<name>`, which the emitter and the
tree-walking VM both resolve straight to the top level, past any binding the use site
introduced (the marker survives into the IR as an ordinary symbol in a `ref`, `set!`
or `define` name field; for what each backend then does with it, see `docs/ir.md` §
Marked names):

```scheme
(define (helper x) (* x 10))
(define-syntax use-helper (syntax-rules () ((_ v) (helper v))))
(let ((helper (lambda (x) (- x)))) (use-helper 3))   ; 30, not -3
```

The marking excludes pattern variables, template-bound identifiers, syntactic keywords
(a template's `let` is syntax, not a variable), names that already carry the marker
(double-marking yields `%gref%%gref%x`, which strips to nothing bound), and names that
are currently macros — plus `paal-expand` unmarks a marked head that turns out to name
a macro, covering one defined *after* the macro that referenced it. A nested
`syntax-rules` is skipped entirely: its pattern variables and `_` are not free
identifiers of the enclosing template, and its own free identifiers belong where that
inner macro is defined.

Resolving to the top level is exact for a value binding, because even a *local*
macro's table entry is global — the `%mac-` alias lives in the one macro table, and a
library-defined value a template names resolves through its `%gref%` mark
(`rename-core` follows the mark through a library rename, so a macro used inside its
own library still finds the renamed global). The genuine boundary is elsewhere: a
template-introduced identifier that is *bound only by a later expansion step* needs
per-identifier provenance — syntax objects — which paal's symbol-marking scheme does
not carry. That is the deferred case behind §4.3 tests 117/149/153 and the SRFI 26
adaptation; it is recorded in TODO.md, and nothing should attempt it without that
design.

**Local macro scope:** `letrec-syntax` installs all its bindings before expanding
anything, so its transformers may refer to each other and to themselves. `let-syntax`
gives its keywords the body as their region, not the bindings (R7RS 4.3.1): each
transformer captures its *definition* environment — `make-transformer` takes a
def-env, and transformers are `(lambda (form use-env) …)` — so a template naming a
sibling keyword resolves to the outer binding. (An earlier design got this effect by
expanding the body twice; def-env capture replaced the double expansion.)

The macro table is module-level state, so its lifetime has to be managed explicitly:
`paal-macros-reset!` runs wherever a fresh globals table is created, giving macros the
same lifetime as the definitions they sit alongside. Entry points that add to an
existing table — `pkaappi-load-file`, `pkaappi-run-string-in` — deliberately do not
reset, which is what keeps a loaded file's macros visible and lets the REPL accumulate
them across inputs.

**Ellipsis:** `syntax-rules` supports nesting to arbitrary depth — a pattern variable
bound under two ellipses instantiates under two in the template. Each ellipsis past the
first *splices* rather than nests, so `(a ... ...)` flattens what `((a ...) ...)` would
have kept structured. `(<ellipsis> <template>)` escapes: ellipses inside have no special
meaning, which is how a macro emits a literal `...` for a macro it defines.

**Quasiquote note:** `expand-qq` uses explicit `list`/`cons` calls rather than
quasiquote templates. Kaappi's own expander misinterprets `unquote-splicing` as a
special form when it appears as a literal symbol inside a template, even inside
`(quote …)`. The explicit construction avoids this.

---

## Pipeline Stage 3 — Compiler (Analyzer)

**Input:** list of core S-expressions  
**Output:** list of IR nodes — the eight tags are in `docs/ir.md` § Node Types

A recursive descent analyzer that converts each core form to a typed IR node. No
optimization passes at this stage; analysis is purely structural — and there are none
downstream either, which is a sizing decision rather than an omission: see
`docs/ir.md` § Source locations, types, and optimization are not in the IR.

Special cases in the analyzer:

- **`(lambda params body…)`** — `params` may be a proper list (fixed arity), the empty
  list (nullary), a symbol (pure variadic), or an improper list `(x . rest)` (mixed).
  `rest?` is set to `#t` for symbol and improper-list forms.
- **`(define (name params…) body…)`** shorthand — desugared to
  `ir:define name (ir:lambda params body rest?)`. The `rest?` flag is derived from
  `(not (list? params))`, matching the improper-list handling above. In the normal
  pipeline the analyzer never sees this spelling — the expander has already rewritten
  it — so the branch is a fallback for callers that analyze unexpanded forms. See
  `docs/ir.md` § `(define name val)`.
- **`(if test then)`** — missing `else` arm defaults to `ir:const #f`.

---

## Pipeline Stage 4 — VM (Bootstrap)

**Input:** list of IR nodes  
**Output:** result value of the last expression

A tree-walking interpreter with proper tail calls via a tagged-thunk trampoline. It
handles all eight node types (`docs/ir.md` § Node Types).

This is one of the IR's two consumers, not the only one: `(kaappi paal emitter)`
compiles the same node tree to bytecode, and the CLI's default file path goes through
*it* rather than through this stage. The tree-walking VM stays as the simpler
reference implementation, so a disagreement between the two is evidence of an emitter
bug. See `docs/ir.md` § Where the IR sits.

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

**Known limits.** Nesting was bounded by the host: kaappi up to v0.22.1 mishandled
more than 63 dynamically nested `guard` forms — at depth 64 the innermost handler was
skipped and an outer one caught instead, because the overflow arrived as a *catchable*
condition that the user's own `guard` swallowed. Fixed upstream by kaappi/kaappi#1919
(closing kaappi/kaappi#1886): the handler and wind stacks grow on demand, and a VM
overflow is now an uncatchable `KP3008`. Paal is correct at every depth tested against
a build of kaappi `main`. The fix is not in a release yet, so paal running against an
older kaappi still inherits the old ceiling.

See "Exception handlers" below for `raise-continuable`, and "The wind stack" for how
a guard's two dynamic environments are kept apart.

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

## Exception handlers

`with-exception-handler` cannot be a HOST procedure in the bytecode path — the handler
and thunk are paal closures, which HOST code cannot enter. And `raise-continuable`
cannot be built on the HOST condition system at all: its handler must run **without
unwinding**, so that the handler's return value can become the value of the
`raise-continuable` call. HOST `raise`/`guard` always unwind.

So handlers live on a paal-side stack, and `raise-continuable` simply calls the top one
in place and returns its result:

```scheme
(with-exception-handler (lambda (e) 10) (lambda () (+ 1 (raise-continuable 'x))))
; => 11 — the handler's 10 is the value of the raise, and (+ 1 …) resumes
```

The handler runs with the *outer* stack installed, per R7RS, so a raise inside a
handler reaches the next handler out rather than re-entering itself.

`raise` consults the same stack and then escapes. R7RS says a handler that returns from
a non-continuable raise triggers a secondary exception; paal raises one carrying the
message `"handler returned"`, which is what HOST kaappi does, so both pipelines report
it identically. With no handler installed, both `raise` and `raise-continuable` fall
straight through to the escape that `guard` catches — which is why `guard` needed no
changes.

A `guard` participates in this stack too: `run-guard!` pushes the escape procedure
itself while the body runs, so the guard is the innermost handler and a
`raise-continuable` inside its body belongs to it rather than to an enclosing
`with-exception-handler`. The stack is restored before the clauses run, so an
unmatched clause re-raises to the *outer* handler rather than back into the same
guard.

`with-exception-handler` deliberately has no `guard` of its own. A guard would push
its escaping handler on top of the one being installed and swallow the very
conditions it exists for; and cleanup on a non-local exit is unnecessary, since the
escape propagates to some enclosing guard whose `run-guard!` restores the stack to
what it captured beforehand.

The tree-walking VM keeps HOST `with-exception-handler` and inherits the host's own
handler stack. It only needs the trampoline forced on both the thunk and the handler
result: an unforced `(raise-continuable x)` in tail position would otherwise happen
after the handler had been uninstalled, and an unforced handler result would become a
thunk rather than the value of the raise.

---

## The wind stack

R7RS 4.2.7 puts the two halves of a `guard` in two different dynamic environments.
The clauses are evaluated in that of the `guard` expression; a condition no clause
matched is re-raised in that of the *original* `raise`. The sample implementation
gets there with `call/cc` twice — out to the guard to test the clauses, back to the
raise point to re-raise — which paal cannot do, having no continuations over paal
closures.

It does not need them, because a dynamic environment in paal is *data*: entering an
extent pushes a frame onto `%paal-winds`, and two states can be moved between by save
and restore rather than by jumping. The frames form a shared-tail list, so the extents
entered between two states W and W′ are exactly the frames of W that are not in W′,
and `%paal-wind-out!` / `%paal-wind-in!` walk that difference.

Two frame kinds share the stack, tagged with interned symbols so either copy of the
library recognizes the other's:

| Frame | Winding out | Winding in |
|-------|-------------|------------|
| `#(%paal-param-frame cells news olds)` | write `olds` | write `news` |
| `#(%paal-wind-frame before after)` | call `after` | call `before` |

The asymmetry is deliberate. A parameter's converter runs once, when the extent is
entered, so the frame stores the converted values and re-entry reuses them. A
`dynamic-wind`'s thunks are *meant* to run on every crossing.

`run-guard!` reads `%paal-winds` on entry and hands it to `%paal-guard-catch`, which
owns everything past the catch:

```scheme
(let ((w-raise %paal-winds))            ; host unwinding does not touch this
  (%paal-wind-out! w-raise w-guard)     ; the guard's environment
  (let ((result (clauses condition)))
    (if (eq? result %paal-guard-no-match)
        (begin (%paal-wind-in! w-raise w-guard)   ; back to the raise point
               (raise-continuable condition))
        result)))
```

Two consequences shape the rest of the design.

**`parameterize` and `dynamic-wind` have no cleanup handler of their own.** On a raise
the frame stays on `%paal-winds` and the extent stays open, which is exactly what makes
the raise point still reconstructable when the guard looks. Closing it is the enclosing
guard's job, and one `%paal-wind-out!` closes every extent between it and the raise in a
single pass — restoring parameters and running `after` thunks in innermost-first order.
A raise is no longer paal's only non-local exit — a continuation invoke is the other —
but the revisit this paragraph used to promise turned out to be a reuse: invoking a
continuation moves between dynamic environments with the same
`%paal-wind-out!`/`%paal-wind-in!` walk, out to the deepest shared tail of the two
wind stacks and back in to the captured one (see "Continuations in the bytecode VM").
`parameterize` and `dynamic-wind` still need no cleanup handler of their own: both
kinds of exit close every extent between the two states in one pass.

A guard *inside* an extent is not leaving it, so a guard that declines there does not
run the `after` thunk; only an escape that actually crosses the frame does. kaappi
answers `(before outer-clause after)` where paal answers `(before after outer-clause)`
— the same kaappi/kaappi#1988 ordering defect, seen through winders instead of
parameters.

**The expander stops emitting the re-raise.** A clause list with no `else` gets an
implicit `(else %paal-guard-no-match)` instead of `(else (raise-continuable var))`.
The re-raise has to be surrounded by the wind dance, so it belongs to the machinery,
which knows both states; returning a sentinel is how the handler says "nothing
matched, it is yours". The sentinel is a freshly allocated pair in
`paal-initial-env`, so no value a program can write is `eq?` to it.

Converters run once, when the extent is entered. The frame stores the converted
values, so winding in again reuses them rather than converting a second time.

Both pipelines implement this: the tree-walking VM as HOST procedures over a
module-level `%paal-winds`, the bytecode VM as paal source compiled into globals.

**A host bug this exposed**, fixed upstream by kaappi/kaappi#1991. kaappi
v0.22.0 answered `2` where R7RS requires `1`:

```scheme
(define p (make-parameter 1))
(guard (e (#t (p)))                        ; this guard's environment has p = 1
  (parameterize ((p 2))
    (guard (e ((number? e) 'no-match))     ; declines
      (raise 'boom))))
```

A guard that declined left the *declining* guard's dynamic environment in place, so
the next guard out ran its clauses in the wrong one. Paal answered `1` here from the
start, which is what surfaced it.

The cause was `compileGuard` evaluating the `cond` and then escaping with its
*value*, where R7RS escapes first and evaluates the clauses in the guard's
continuation — so the extents between were still installed while the clauses ran. The
same ordering showed up in `dynamic-wind`, whose `after` thunk ran after the outer
clauses rather than before them. Both are fixed; paal and kaappi now agree on every
case in the repro.

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

`%paal-parameterize` reads the old values, converts the new ones through each
parameter's converter, pushes a wind frame, installs, runs the thunk, and restores.
It needs no VM marker of its own — unlike `guard`, which had to be one — because
nothing here needs the VM: cells are ordinary vectors and the wind stack is an
ordinary list. Restoration on a raise is the enclosing guard's job; see "The wind
stack" above for why doing it here as well would be wrong.

Both pipelines provide it: the tree-walking VM as HOST procedures in
`paal-initial-env` (forcing the trampoline on the converter and on the thunk), the
bytecode VM as paal source compiled into globals by `pkaappi-make-globals`, which
overrides the HOST bindings.

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
| continuation | `%paal-continuation` | `frame.sld` |
| guard marker | `%paal-vm-guard-run` | `vm-bc.sld` |
| apply marker | `%paal-vm-apply` | `vm-bc.sld` |
| call/cc marker | `%paal-vm-call/cc` | `vm-bc.sld` |
| spawn marker | `%paal-vm-spawn` | `vm-bc.sld` |
| ffi-callback marker | `%paal-vm-ffi-callback` | `vm-bc.sld` |
| raise wrapper | `%paal-vm-escape` | `vm-bc.sld` |
| continuation-invoke escape | `%paal-vm-cont-invoke` | `vm-bc.sld` |

`spawn` and `ffi-callback` are markers for the boundary reason with a twist: their
procedure argument is called *later*, from HOST code — the fiber scheduler, or C. The
arm wraps the paal closure in a HOST trampoline over `paal-call-value` and hands that
to the raw primitive (kept under a `%paal-host-` name). Each trampoline entry
allocates a fresh register file — a fiber body interleaves with its spawner, and
sharing one would corrupt both at the first yield — and runs as its own dispatch-loop
episode. The paal-compiled copy of the VM builds its trampoline as a paal closure
again, so the self-hosted path keeps the boundary type error; the markers answer
`procedure?` like the others.

`<frame>` stays a `define-record-type`: frames are created and consumed inside a single
VM invocation and never enter globals.

The cost is that a user vector of the right length whose first slot is one of those
symbols would be mistaken for the internal type. The gain is that closures built by
either copy are callable by either — without it, every procedure `pkaappi-make-globals`
installs by paal-compiling it (`map`, `for-each`, `apply`, `filter`, `vector-map`,
`string-map`, `values`/`call-with-values`, and the promise system) failed under
`pkaappi-self-run-file` with `not a callable`. That was kaappi/paal#1.

### What the representation leaks, and what is done about it

Tagging with plain vectors means the representation is visible to the program running on
top of it. Three consequences, each settled differently.

**`procedure?` is corrected; `vector?` is deliberately not.** A closure is a 3-vector, so
the HOST `procedure?` said `#f` for every procedure a paal program defines — every
predicate dispatch on procedures was broken. `pkaappi-make-globals` now overrides
`procedure?` to recognize the `%paal-closure` tag, which is safe because `do-call!` and
`paal-call-value` both test `closure?` *before* `procedure?`.

`(vector? f)` still answers `#t`, and must. `vector?` is load-bearing for `closure?`
(`frame.sld`), `bytecode-function?` (`bytecode.sld`), `promise?`, `paal-vm-escape?` and
the wind-frame dispatch — and under self-hosting the paal-compiled `frame.sld` resolves
`vector?` out of the *user program's* globals table. Override it there and `closure?`
returns `#f` for every closure, so nothing is callable at all. This is the sharpest case
where the two-copies problem makes the obvious fix catastrophic. The leak is asserted in
the suite so the trade-off is recorded rather than rediscovered.

**`write` abbreviates procedures, one level deep.** Printing a closure raw means printing
its entire bytecode function — pages of nested vectors. `write` and `display` recognize
the two tags and print `#<procedure name>` / `#<code name>`. Deliberately shallow:
`(write (list f))` still shows the vector. Going deeper means a full R7RS writer in paal
source — cycle detection, datum labels, string and character escaping — a second
implementation to keep in step with kaappi's. The debugger's `%debug-write` makes the
same call for the same reason.

### Continuations in the bytecode VM

`call/cc` on this path is a VM operation, like `guard` and `apply` before it: the HOST
`call/cc` in `paal-initial-env` cannot work here (a paal closure is a tagged vector the
host cannot enter), so `%make-globals-table` strips it (`%paal-host-only-names`) and
binds both spellings to the marker `%paal-vm-call/cc`, which `do-call!` implements.

**Capture** copies the live prefix of the register file — `[0, abs-base+nargs+1)`,
exact because the emitter allocates every call's base as the next free register, so
bases grow monotonically down the frame list, across nested `paal-call-value` episodes
included — plus the frame list as plain `#(closure ip base dst)` tuples, the
`%paal-winds` and `%paal-handlers` list values (both stacks grow by rebinding, so the
reference is a snapshot), and the identity of the running dispatch loop. The result is
`#(%paal-continuation …)`, a tagged 7-vector from `frame.sld`, recognizable by both
self-hosting copies and by the blob's `procedure?`. The marker case then performs
apply's in-place rewrite — receiver into the callee slot, continuation as its one
argument, re-dispatch — so `(call/cc f)` in tail position stays a real tail call and
`f` may be a closure, HOST procedure, marker or another continuation.

**Invoke** is a `do-call!` arm on `continuation?` (so `(apply k args)` works free).
One argument is the value; any other count becomes the blob's MVR encoding, so
`call-with-values` consumers receive them all. The dynamic extent moves first — wind
out to the deepest shared tail of the current and captured `%paal-winds`, wind back in
to the captured state, using the same `%paal-wind-out!`/`%paal-wind-in!` walk a
declining guard performs — then `%paal-handlers` is restored by assignment, which is
load-bearing: `with-exception-handler`'s trailing restore never runs when a
continuation escapes its thunk. Control transfer is multi-shot: fresh frames are
rebuilt from the snapshot each time and the register prefix is copied back, so one
continuation can be re-entered any number of times, and a tail-position re-invoke
neither grows the frame list nor the host stack.

**Dispatch-loop episodes.** Each `paal-run-bc` and each nested `paal-call-value` run
installs a fresh loop identity in globals (`%paal-vm-loop`). An invoke inside the
capturing episode restores frames in place. Anywhere else it raises
`#(%paal-vm-cont-invoke cont value)`: `run-guard!` recognizes the tag and passes it
through — the one thing the reverted escape-only design could not do, and it must not
restore `%paal-handlers` on the way — and `paal-run-bc`, now a retry loop, resumes the
continuation when the identity matches. A continuation whose episode has finished — a
guard body that returned, a previous `eval` — dies with
`continuation invoked outside its dispatch extent`, deliberately past the program's
own guards, the way a kaappi `KP3008` is uncatchable: never corruption. This is paal's
analogue of kaappi's documented "cannot re-enter a returned native driver frame".

What invoke does **not** restore: heap state (boxes and upvalue cells keep their
current values, per R7RS), and the debugger hears nothing — like a guard escape, the
frame list changes wholesale rather than by one call or return, so `next`/`finish`
simply stop at the next event at or below their recorded base.

The escape-only design this replaces is described in `docs/TODO.md` Phase 7's history;
its fatal flaw — guards swallowing escapes they cannot recognize — dissolved when
capture and invoke moved into the dispatch loop, where the clauses never run.

---

## The stepping debugger

`paal debug <file>` runs a program with breakpoints, step / next / finish, and a
backtrace. It is in two halves: the events live in `lib/kaappi/paal/vm-bc.sld`, and the
hooks that consume them in `lib/kaappi/paal.sld`.

### Where events come from

The VM raises an event at the places the frame stack changes shape, and nowhere else:

| Where | Event |
|---|---|
| `do-call!`, closure branch | a paal closure is about to be entered |
| `dispatch!`, `return` opcode | a frame returns through a `return` instruction |
| `deliver-result!` with `tail?` | a frame returns through a tail call to a primitive |

The third is not an afterthought. A procedure whose body ends in a call to a primitive —
`(define (double x) (* x 2))` — never executes a `return` instruction; it leaves through
`deliver-result!`. For a program written entirely in tail position that is *every*
return it makes, and hooking only the opcode showed none of them.

Calls to HOST procedures raise no event: they have no frame, so there is nothing to step
through. A `guard`'s body thunk and handler are entered through `paal-call-value` rather
than `do-call!` and so raise no *call* event either — what shows up instead is the calls
made inside them, which is what the user of `guard` wrote.

### The hook protocol

```scheme
(hook kind name value depth backtrace) → 'step | 'next | 'finish | 'continue
```

| | |
|---|---|
| `kind` | `'call` or `'return` |
| `name` | the procedure's name, or `#f` for an anonymous lambda |
| `value` | the argument list (`'call`) or the returned value (`'return`) |
| `depth` | how many frames are live |
| `backtrace` | `((name arg …) …)`, innermost frame first |

Data only — no frame, register or closure object is handed over, so a hook cannot
disturb the run it is watching, and a test hook is an ordinary procedure returning a
scripted list of commands. An answer the VM does not recognize continues, so a hook that
returns something odd cannot wedge the program.

A frame is described by its procedure's name and the values of its parameters. That is
not a choice: registers carry no variable names by the time the emitter is done with
them, and `regs[base … base+arity]` is the one stretch of the register file whose
meaning is recoverable without debug info the emitter does not record. A call event
reports the arguments *as passed*; the backtrace reports them *as bound*, so for a
variadic procedure the rest list is already built in the second and not in the first.

### How next and finish measure depth

Both mean "run until an event no deeper than here", and depth is the frame's **register
base**, not the length of the frame list. The emitter allocates a call's base above
everything live, so bases grow with depth — and unlike the list length they keep growing
across a re-entrant `paal-call-value`, whose frame list is a fresh singleton. Comparing
lengths would make a `next` inside a `guard` body stop at the first event of the nested
loop.

`finish` at a call event finishes the frame the call is made *from*, matching gdb, where
`finish` completes the selected frame. A tail call is reached with the caller's frame
still current, so its base compares equal and `next` stops there — which is right: a
tail call is the last thing the frame does, so there is no rest of the frame to step
over. A breakpoint fires in every mode, `finish` included.

### Why the globals blob is skipped

`pkaappi-make-globals` installs paal-compiled `map`, `filter`, `apply`, `force` and the
rest of the blob into the table before the user's program is even compiled, and stepping
into those is never what anyone means. `paal-debug-start!` snapshots the closures already
in the table and no event fires for them.

The skip is by closure **identity**, not by name. The user's own procedures are defined
during the run, so they are not in the snapshot; and an anonymous lambda handed to `map`
still stops, because it is a different object from `map` itself. Keying on names would
have had to choose between skipping every anonymous lambda and stepping through the blob.

### What it does not do

There is no `up`/`down`. Selecting a frame is only useful if something can then be
evaluated in it, and a register file without variable names cannot answer "what is `x`
here". `bt` prints every frame with its arguments in one go, which is the part that is
recoverable; `p <name>` reads a top-level binding out of the globals table.

Like `--profile`, the debugger runs the HOST pipeline. The self-hosted path executes the
program through the paal-compiled copy of the VM, which has its own `%debug-hook` that
setting this one does not reach — the same two-copies problem as `%paal-lib-paths`.

---

## Public API (`lib/kaappi/paal.sld`)

High-level entry points that run the full pipeline:

```scheme
(pkaappi-run-string src)  ; string → result
(pkaappi-run-file path)   ; file path → result
```

Individual stage exports are also re-exported for embedding or incremental use.

### Library declarations

A `define-library` body speaks the full R7RS 5.6.1 vocabulary. `cond-expand`
and `include-library-declarations` — the two declarations that produce further
declarations — are rewritten away first (`normalize-decls`, recursive, since
each may yield more of either), so everything downstream reads a flat list of
`export` / `import` / `begin` / `include` / `include-ci`. The body is then
gathered in declaration order: `begin`, `include` and `include-ci` interleave
as written, so an included file can use a name an earlier `begin` defines and
vice versa. The same pass serves both `install-library!` and a
`define-library` evaluated as a program form (`paal file.sld`).

### Import scope

`(import (scheme base))` is enforced, and the mechanism is a **check rather than
aliases**. Aliases cannot restrict anything: the globals table holds every primitive
under its public name, so `(define sin sin)` is a no-op and `get-global sin` resolves
regardless. Making aliases bite would need a mangled-only table, which breaks the
globals blob and every cached pipeline library, since both resolve public names.

So after expansion the expander walks the program for free global references, and each
must be one the program is entitled to: defined by the program, granted by an import, or
`%`-prefixed (paal's own plumbing). **Only programs with a top-level `import` are
checked** — every bare script, `paal eval`, the REPL, the blob and each `.pbc` is
untouched, which is what makes the change safe to land at all.

The partition names the *small* libraries exhaustively and lets `(scheme base)` be
everything else, because base has some 200 names and a typo while enumerating it would
sit between a correct program and compiling. A name missing from a small library is only
over-permissive.

Three things must not leak into the check, and each did once:

| | |
|---|---|
| a spliced library **body** | governed by its own imports, not its importer's |
| a library's **own imports** | `(srfi 1)` imports base; that must not grant the importer base |
| the emitted **alias forms** | `(define m:sin sin)` names what `prefix` exists to hide |

The first two are handled by `expand-nested` plus a save/restore of the import-scope
state around the whole of `install-library!` — prologue as well as body. The third by
recording alias-defined names and skipping those forms.

`(scheme cxr)` is partitioned too: the 24 compositions of depth three and four, with
depth two — `caar`, `cadr`, `cdar`, `cddr` — left in base. R7RS 6.4 counts twenty-eight
in all, so the split is 4 + 24. paal's own libraries use `caddr` and `cadddr` freely
while importing only `(scheme base)`, which is fine because a `define-library` is never
checked and its body is skipped when spliced into an importer.

Modifiers over base narrow it. `(only (scheme base) car)` grants exactly `car` — the
names are manufactured as identity aliases, taken on faith since base has no export
list to validate against, and outer modifiers compose over them, so
`(prefix (only (scheme base) car) b:)` defines and grants `b:car`. `except` over base
records an exclusion set instead, one per spec so that imports still union:
`(import (except (scheme base) car) (scheme base))` grants `car` back through the
second spec. `environment` honours its import specs by the same computation, packaged
as `paal-import-grant-predicate`: the table is built full and filtered down to the
grant, with `%`-prefixed plumbing always kept; a spec rooted in a file-backed library
leaves the table full, since resolving it would load the library into the caller.

Two deliberate limits remain, both over-permissive rather than wrongly rejecting: a
name `only` takes on faith that base does not actually have surfaces at run time as an
unbound global rather than at the check; and because base is "everything else", a name
belonging to no library at all reaches the runtime rather than the check. A bare
`prefix` or `rename` directly over base (no `only` beneath) still grants base whole —
there is no list to transform.

### One feature list, one owner

`(kaappi paal expander)` exports **`paal-feature-list`**, and it is the single answer to
"what is this implementation". `paal-initial-env` binds `features` to it, and
`cond-expand` tests against the same list.

They used to be different lists: `features` answered with the *host's*, which does not
contain `paal`, while `cond-expand` answered from the expander's — so a program asking
what it was running on and a `cond-expand` asking the same question disagreed. Under
self-hosting the user's `(features)` resolves through the HOST expander and `cond-expand`
through the loaded one, but both are built from this one definition, so they agree.

The list claims only what holds: `paal kaappi r7rs exact-closed exact-complex ieee-float
posix scheme`. The middle four are inherited from kaappi's runtime, which advertises
exactly those; `full-unicode` and `ratios` are *not* in kaappi's list, so paal does not
claim them either. `scheme` is a paal extension rather than an R7RS feature identifier,
kept because paal's own `cond-expand`s use it.

## CLI tooling

The query and diagnostic subcommands live outside the pipeline: each is either a thin
CLI rendering over an exported procedure, or a support library no pipeline stage
imports. None of them is needed to compile or run code.

**`features [--json]`** renders `paal-features` — an alist of the version, the
feature-identifier list, the embedded-library names (from `paal-embedded-names`, so the
report derives from the same table the expander resolves against), and the pipeline
cache state. The facts are data apart from the two renderings (`paal-features-text`,
`paal-features-json`), so the suite asserts on the report without parsing either.

**`cache status|clear [file...]`** manages paal's two caches. With files, the subject
is the `<file>.<hash>.pbc` entries `--cache` writes beside sources: `pkaappi-cache-entries`
lists them with the current one marked — the hash is in the name, so a source edit
strands the old entry — and `pkaappi-cache-clear!` removes them. A *run* can never do
this (it cannot tell its own leavings from a user's `.pbc`); an explicit subcommand can,
by the naming scheme. Directory listing is the one operation R7RS lacks; the host's
`(srfi 170)` supplies it, which is safe because `(kaappi paal)` is HOST-side API and
never compiled by paal itself. With no files the subject is the pipeline cache under
`cache/` (`paal-pipeline-cache-status`).

**`dis <file>`** and the runtime `(disassemble proc)` render bytecode through
`(kaappi paal disassembler)`. Instructions are tagged lists already, so each line is the
instruction written verbatim, numbered; an embedded `(closure dst fn specs)` function
becomes a label (`fn1`, `fn2`, … breadth-first) and is listed under that label after its
parent. The runtime binding prints to the HOST error port, as kaappi's prints to stderr:
the listing is a diagnostic, so a paal-level port rebinding deliberately does not
capture it.

**`--coverage-xml <file>`** writes the run's procedure coverage as Cobertura XML — the
shape Codecov ingests, matching kaappi's writer field for field: one package per report
(for a program, the file), one class, one `<line>` per procedure. The VM half is
`paal-coverage-hits`, a second reader over the state `--coverage` already collects:
`(name . count)` per program-defined procedure, zeroes included, in definition order.
Line numbers come from scanning the source for each procedure's define, with the
1-based position as fallback when the scan misses, exactly as kaappi's. The writer
(`paal-coverage-xml`) is a pure string function.

**The REPL** is one driver (`%run-repl-driver`) for every route; what differs per route
— how a datum is expanded, compiled and run — is a hook alist. `%repl-host-hooks`
closes over one HOST globals table; `%repl-loaded-hooks` crosses into the loaded
pipeline as data, injecting each datum as a global and running fixed program strings
that read it out, so no string is ever built from user text. Input is read as datums
straight off the port (a form may span lines; there is no continuation prompt — the
reader's state is not observable, and a wrong guess is worse than none). `_` holds the
last value. `,cmd` — which the reader hands over as `(unquote cmd)` — is the command
surface: `,help ,quit ,env ,history`, and taking the next datum as argument,
`,time ,expand ,ir ,dis`; the diagnostics run through the session's own hooks, so
under self-hosting `,expand` shows the loaded expander's output, prompt-defined macros
included. History lives in memory for `,history` and mirrors to a file when the CLI
passes one (`~/.paal_history`; R7RS has no append-open, so the file is rewritten per
entry, capped at 500). Echo abbreviates procedures the way the debugger prints them.

**`check` warnings** come from `(kaappi paal lint)`, run by `pkaappi-check-file` after a
successful compile. Two lints over the emitted bytecode: an *unknown top-level
variable* (a `get-global` name the program neither defines anywhere in its function
tree nor the runtime binds — the driver hands the lint the names of a freshly built,
memoized globals table, the runtime's real surface) and an *arity mismatch* on a direct
call to a program-defined procedure. Both are warnings and never rejections — kaappi's
invariant. The arity lint trusts only what it can see whole: the callee was loaded by
`get-global` in straight-line code (register tracking drops at every jump and call),
and the name was defined exactly once, from a `closure` instruction, and never `set!`.
Warnings are data — `(unknown-variable NAME)`, `(arity NAME EXPECTED VARIADIC? GOT)` —
rendered by the check driver.
