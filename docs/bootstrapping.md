# Paal — Bootstrapping Roadmap

Paal is designed to be self-hosting: `pkaappi` will eventually compile its own source.
This document describes the stages of that process and the design decisions behind each.

## The Bootstrap Problem

A self-hosting compiler needs to be built with itself, but it can't compile itself
before it exists. The standard solution is a bootstrap chain:

```
Stage 0: kaappi (host interpreter, Zig)
    │  runs paal source as interpreted Scheme
    ▼
Stage 1: paal tree-walking VM (current)
    │  compiles paal source to IR + evaluates
    ▼
Stage 2: paal bytecode compiler
    │  compiles paal source to paal bytecode
    ▼
Stage 3: paal bytecode VM
    │  runs paal bytecode natively
    ▼
Stage 4: pkaappi can compile pkaappi
    │  self-hosting achieved
    ▼
Stage 5: pkaappi binary (no host dependency)
```

## Current Status: Stage 6 pre-work in progress

All five bootstrapping stages are done. Stage 6 (self-compilation) requires paal to
handle the forms used in its own `.sld` source files. Three such forms have been added
to the expander in this phase — 157 tests pass across all pipelines.

```sh
make run ARGS="eval '(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 20)'"
```

### Stage 6 Prerequisites — forms now handled

| Form | Where used in paal source | Status |
|------|--------------------------|--------|
| Internal `define` in lambda/let bodies | Throughout all `.sld` files | ✓ done |
| `define-record-type` | `bytecode.sld`, `frame.sld` | ✓ done |
| `define-library` / `import` / `export` | All `.sld` files (top-level) | ✓ done (minimal: splices `begin` body, ignores imports/exports) |
| `define-syntax` / `syntax-rules` | Not used in paal source | deferred |
| `case-lambda` | Not used in paal source | deferred |

**Key expander changes (all in `expander.sld`):**

- `expand-body` — hoists leading `(define ...)` forms in a lambda body to `letrec*`
  (R7RS §5.3.2). Called from the `lambda` dispatch case.
- `expand-define-record-type` — desugars to `begin` of `define`s using vector storage.
  Vector layout: `[type-tag, field0, field1, …]`. Tag is a fresh pair for eq? identity.
- `define-library` handler — extracts all `(begin …)` declarations and splices them.
  `import` and `export` declarations expand to `(quote #f)` (no-op).
- `paal-expand-all` — changed from `(map paal-expand forms)` to a splicing variant:
  top-level `(begin …)` results are recursively spliced. This is required for
  `define-record-type` and `define-library` to produce multiple top-level defines
  that `paal-eval-program` can process at the proper scope.

### Remaining work for Stage 6

- Load and evaluate paal's own `bytecode.sld` + `frame.sld` via `pkaappi-run-file`
  (should work now with the above changes).
- Implement the self-compilation pipeline: paal compiles its own `.sld` files to
  bytecode, producing a `pkaappi` binary with no kaappi host dependency.

## Remaining Stages

### Stage 2 — Tail Call Optimization ✓ complete

**Why first:** Scheme mandates proper tail calls. Any tail-recursive program (including
paal's own compiler passes) will stack-overflow on the tree-walking VM without TCO.
This must be done before paal can compile itself.

**Approach: tagged-thunk trampoline** in `lib/kaappi/paal/vm.sld`

Add a `tail?` parameter to `paal-eval`. In tail position for `ir:call`, instead of
`(apply proc args)`, return a tagged thunk `(cons %thunk-tag (lambda () (apply proc args)))`.
The trampoline at the top of `paal-eval-program` loops until the result is not a thunk.

Tail positions: last expression of `ir:begin`, both arms of `ir:if`, lambda body.

**Test gate:** `(define (loop n) (if (= n 0) 'done (loop (- n 1)))) (loop 1000000)`
must complete without stack overflow.

### Stage 3 — Bytecode Compiler ✓ complete

**Files to create:**
- `lib/kaappi/paal/bytecode.sld` — ISA definitions (instruction tags + operand shapes)
- `lib/kaappi/paal/emitter.sld` — IR → instruction list compiler
- `lib/kaappi/paal/frame.sld` — call frame record + register array

**ISA design:** A minimal register-based ISA inspired by kaappi's 29-opcode set, but
starting with ~15 opcodes:

```
load-const  dst idx       reg[dst] = constants[idx]
load-true   dst           reg[dst] = #t
load-false  dst           reg[dst] = #f
load-nil    dst           reg[dst] = ()
move        dst src       reg[dst] = reg[src]
get-global  dst sym-idx   reg[dst] = globals[sym]
set-global  sym-idx src   globals[sym] = reg[src]
define-global sym-idx src define/overwrite global
get-upvalue dst uv-idx    reg[dst] = closure.upvalues[uv-idx]
set-upvalue uv-idx src    closure.upvalues[uv-idx] = reg[src]
closure     dst fn-idx n  + n × (local? idx) upvalue descriptors
call        base nargs    push frame; callee at reg[base]
tail-call   base nargs    reuse current frame (O(1) tail call)
return      src           pop frame; deliver result
jump        offset        unconditional relative branch
jump-if-false test offset branch if reg[test] = #f
halt                      stop VM
```

**Call convention** (matching kaappi's):
- Callee at `reg[base]`; arg₀ at `reg[base+1]`, …, argₙ at `reg[base+n]`
- New frame's `base = old-base + 1`
- Return value delivered to caller's `dst` register

**Register allocation:** Linear cursor (`next-reg`), `alloc-reg!` / `free-reg!`.
Single-pass, no liveness analysis.

**Closure/upvalue model:** Same vector-box protocol as the tree-walking VM. The `closure`
instruction captures upvalues lazily — boxing a register on first capture. Box detection:
a pair `(val . VOID)` where `VOID` is a sentinel.

**Tail calls:** For a bytecode-to-bytecode tail call, overwrite the current frame's
`closure`, `code`, and `ip = 0`, copy args to `frame.base + 0..n-1`. No frame push.
The dispatch loop's `while` is the implicit trampoline.

**Instruction encoding during development:** Instructions are tagged lists
`(list 'load-const dst idx)` etc. A later phase migrates to bytevector encoding
for performance and eventual self-compilation.

### Stage 4 — Bytecode VM Dispatch ✓ complete

**File to create:** `lib/kaappi/paal/vm-bc.sld`

A `named-let` dispatch loop over a frame stack and register vector (implemented as a
Scheme `vector`). The loop processes one instruction per iteration:

```scheme
(define (bc-run fn)
  (let ((regs   (make-vector 4096 #f))
        (frames (list (make-frame fn 0 0 #f))))
    (let dispatch ((frames frames))
      (let* ((frame (car frames))
             (instr (frame-next-instr! frame)))
        (case (car instr)
          ((load-const) ...)
          ((call)       ...)   ; push frame
          ((tail-call)  ...)   ; mutate frame in-place, dispatch
          ((return)     ...)   ; pop frame, deliver result
          ...)))))
```

**Integration:** `lib/kaappi/paal.sld` gains `pkaappi-compile` (source → bytecode
function) and `pkaappi-run-bc` (run bytecode). The tree-walking VM stays as a fallback
during the transition. The same 79 tests run against both VMs to verify equivalence.

### Stage 5 — Self-Hosted Reader ✓ complete

**File to rewrite:** `lib/kaappi/paal/reader.sld`

Replace the host `read` wrapper with a character-level reader written in Kaappi Scheme.
TCO (Stage 2) is a prerequisite — the recursive descent parser needs proper tail calls
to handle deep nesting without stack overflow.

**Token types for initial implementation** (sufficient to read paal's own source):

| Token | Notes |
|-------|-------|
| `lparen` `rparen` `dot` | list structure |
| `quote` `backquote` `comma` `comma-at` | abbreviations |
| `boolean` | `#t` `#f` |
| `fixnum` | decimal integers first; radix prefixes (`#b` `#o` `#x`) later |
| `flonum` | including `+inf.0` `-inf.0` `+nan.0` |
| `string` | with `\"` `\\` `\n` `\r` `\t` `\xHH;` escapes |
| `symbol` | standard initial/subsequent character sets |
| `character` | `#\space` `#\newline` `#\x41` and single chars |
| `hash-lparen` | `#(` vector |
| `eof` | end of input |

Comments: `;` (line), `#|…|#` (nested block), `#;` (datum).

**Deferred:** bignum, rational, complex, datum labels (`#N=` `#N#`), `#u8(`,
SRFI 207 raw strings — add incrementally as needed.

**Test gate:** `pkaappi-run-file` on paal's own `.sld` source files must parse and
return correct results with the new reader.

### Stage 6 — Self-Compilation

Once stages 2–5 are complete, paal can compile its own source:

```sh
pkaappi compile lib/kaappi/paal/compiler.sld -o compiler.pbc
pkaappi run compiler.pbc lib/kaappi/paal/vm-bc.sld > vm-bc.pbc
```

The final `pkaappi` binary is produced by bundling the compiler, VM, and standard
library into a standalone executable — no kaappi host required.

## Design Principles

**Layers, not rewrites.** Each stage adds capability on top of the previous one. The
tree-walking VM remains usable throughout; the bytecode VM is tested against it for
equivalence. This means bugs can be isolated to a single stage.

**Source is the spec.** Paal's `.sld` files ARE its specification. There is no separate
spec document for the language — if paal can compile a form, it supports it.

**Kaappi compatibility.** Paal targets R7RS-small. All paal-compiled code should run
on kaappi too. The `pkaappi` binary adds no extensions beyond what kaappi already
provides, keeping the ecosystem coherent.

**Binary naming.** Paal binaries use the `p` prefix to avoid collision with kaappi
tools: `pkaappi` (compiler/interpreter), `pthottam` (future package manager).
