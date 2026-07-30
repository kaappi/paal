# Paal — Intermediate Representation

The IR is defined in `lib/kaappi/paal/ir.sld` as the `(kaappi paal ir)` library.

## Representation

Each IR node is a tagged list `(tag field…)` built with:

```scheme
(define (make-node tag . fields) (cons tag fields))
(define (node-tag n) (car n))
(define (node-ref n i) (list-ref (cdr n) i))
```

This is intentionally simple — no record types, no GC overhead beyond ordinary pairs.
The tag is an eq?-comparable symbol. Accessors use `node-ref` with a fixed index.

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
`(ir:if test then (ir:const #f))`.

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
lambda bodies.

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

`params` is the raw parameter spec (symbol, proper list, or improper list).
`rest?` is `#t` when the last binding collects remaining arguments.

The VM's `env-bind` dispatches on `(symbol? params)` and `rest?` to handle all cases.

---

### `(call proc args)`

A procedure application.

```scheme
(ir:call proc-node (list arg1-node arg2-node))
```

**Constructor:** `(ir:call proc args)` — `args` is a list of IR nodes  
**Predicate:** `(ir:call? node)`  
**Accessors:** `(ir:call-proc node)`, `(ir:call-args node)`

All arguments are evaluated eagerly left-to-right before the call.

---

### `(set! name val)`

A mutation of an existing binding.

```scheme
(ir:set! 'x val-node)
```

**Constructor:** `(ir:set! name val)`  
**Predicate:** `(ir:set!? node)`  
**Accessors:** `(ir:set!-name node)`, `(ir:set!-val node)`

The VM uses `env-set!` which walks the environment alist by `assq` and mutates the
vector box in place.

---

### `(define name val)`

A top-level binding. **Only valid at the top level** — the VM errors if `ir:define`
appears in expression position. Use `paal-eval-program` to process top-level sequences.

```scheme
(ir:define 'fact lambda-node)
```

**Constructor:** `(ir:define name val)`  
**Predicate:** `(ir:define? node)`  
**Accessors:** `(ir:define-name node)`, `(ir:define-val node)`

`paal-eval-program` handles defines with a mutable placeholder box so recursive
definitions can see themselves (see `docs/architecture.md` — top-level define semantics).

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

## Future Nodes

The following node types will be added in later phases:

| Node | Phase | Purpose |
|------|-------|---------|
| `tailcall` | 4 (bytecode) | mark a call in tail position |
| `upvalue-ref` / `upvalue-set!` | 4 | captured variable access in closures |
| `local-ref` / `local-set!` | 4 | register-local variable access |
