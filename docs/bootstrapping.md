# Paal — Bootstrapping Roadmap

Paal is designed to be self-hosting: `paal` will eventually compile its own source.
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
Stage 4: paal can compile paal
    │  self-hosting achieved
    ▼
Stage 5: paal binary (no host dependency)
```

## Current Status: Stage 6 complete — 606 tests pass

Paal can load all 8 of its own library files through its bytecode pipeline and
compile and execute arbitrary Scheme through its own loaded pipeline with no HOST
pipeline involvement in the compute path:

```scheme
; All through paal's own loaded code:
(paal-run-bc
  (paal-emit-program
    (paal-analyze-all
      (paal-expand-all '((define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
                         (fact 5)))))
  (pkaappi-make-globals))
; → 120
```

### Stage 6 — What was done

| Item | Status |
|------|--------|
| Expander: `define-record-type`, `define-library`, internal define lifting | ✓ |
| Bytecode VM: `letrec`/named-let mutable upvalue fix (box mutable captured vars) | ✓ |
| Emitter: box variables a *nested closure* assigns, not just same-level `set!` | ✓ |
| HOST/paal boundary: paal-native `map`/`for-each`/`filter` in globals | ✓ |
| HOST/paal boundary: `<closure>`/`<bytecode-function>` as interned-symbol tagged vectors, so either copy can enter the other's closures | ✓ |
| Self-execution loop: vm-bc.sld loaded, `pkaappi-make-globals` in globals | ✓ |
| Expander bug: shorthand `define` now uses `expand-body` (internal define lifting) | ✓ |
| Reader: `\|...\|` bar-quoted symbol support | ✓ |
| Self-hosted `paal run` subcommand (`pkaappi-self-run-file`) | ✓ |
| Bytecode serializer (`.pbc` text S-expression format) | ✓ |
| `paal compile input.scm -o output.pbc` subcommand | ✓ |
| Self-hosted `paal compile` (uses paal's own loaded pipeline) | ✓ |
| Pipeline cache: `make pbc-pipeline` → `cache/*.pbc`; fast load path | ✓ |

### Remaining work

None. This section listed `define-syntax` / `syntax-rules` and `case-lambda` as
deferred because paal's own source does not use them, so self-compilation never
needed them. Both were built anyway in Phase 1 of `docs/TODO.md` — programs paal
*runs* use them constantly — and the entries here outlived that:

```sh
paal eval "(define-syntax swap! (syntax-rules () ((_ a b) (let ((t a)) (set! a b) (set! b t)))))
           (define x 1) (define y 2) (swap! x y) (list x y)"   ; → (2 1)
```

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
paal compile lib/kaappi/paal/compiler.sld -o compiler.pbc
paal run compiler.pbc lib/kaappi/paal/vm-bc.sld > vm-bc.pbc
```

The final `paal` binary is produced by bundling the compiler, VM, and standard
library into a standalone executable — no kaappi host required.

## Design Principles

**Layers, not rewrites.** Each stage adds capability on top of the previous one. The
tree-walking VM remains usable throughout; the bytecode VM is tested against it for
equivalence. This means bugs can be isolated to a single stage.

**Source is the spec.** Paal's `.sld` files ARE its specification. There is no separate
spec document for the language — if paal can compile a form, it supports it.

**Kaappi compatibility.** Paal targets R7RS-small. All paal-compiled code should run
on kaappi too. The `paal` binary adds no extensions beyond what kaappi already
provides, keeping the ecosystem coherent.

**One binary, no package manager.** Paal ships `paal` and nothing else. Packaging is
`thottam`'s job — the existing Zig one in the kaappi repo — since a paal
reimplementation would have to track the same manifest format and registry to be
useful, and would gain nothing by being written in Scheme.
