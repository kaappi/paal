;;; (kaappi paal bytecode) — Bytecode function record and ISA
;;;
;;; A bytecode-function represents one compiled lambda (or the top-level
;;; program). Instructions are tagged lists; values are embedded directly
;;; (no separate constant pool needed at this stage).
;;;
;;; ISA — instruction shapes:
;;;   (load-const  dst val)       reg[dst] = val
;;;   (load-true   dst)           reg[dst] = #t
;;;   (load-false  dst)           reg[dst] = #f
;;;   (load-nil    dst)           reg[dst] = ()
;;;   (move        dst src)       reg[dst] = reg[src]
;;;   (get-global  dst sym)       reg[dst] = globals[sym]
;;;   (set-global  sym src)       globals[sym] = reg[src]
;;;   (define-global sym src)     globals[sym] = reg[src]  (create/overwrite)
;;;   (get-upvalue dst idx)       reg[dst] = closure.upvalues[idx]
;;;   (set-upvalue idx src)       closure.upvalues[idx] = reg[src]
;;;   (make-box    dst src)       reg[dst] = fresh box holding reg[src]
;;;   (box-ref     dst src)       reg[dst] = contents of the box in reg[src]
;;;   (box-set!    box val)       box in reg[box] := reg[val]
;;;   (closure     dst fn specs)  instantiate closure; specs = ((local? . idx)...)
;;;   (call        base nargs)    non-tail call; callee at reg[base]
;;;   (tail-call   base nargs)    tail call; reuses current frame
;;;   (return      src)           return reg[src] to caller
;;;   (jump        offset)        ip += offset + 1  (relative to next instr)
;;;   (jump-if-false test offset) if reg[test]=#f, ip += offset + 1
;;;   (halt)                      stop; caller receives reg[0].  Dispatched
;;;                               but never emitted: `return` ends every
;;;                               function, the top level included
;;;
;;; Boxes carry captured variables that are mutated: the emitter boxes a
;;; local (rest parameters included) when some closure captures it and
;;; something set!s it, so all copies see the write.

(define-library (kaappi paal bytecode)
  (import (scheme base))
  (export make-bytecode-function bytecode-function?
          bytecode-function-code
          bytecode-function-arity
          bytecode-function-variadic?
          bytecode-function-upvalue-count
          bytecode-function-name)
  (begin

    ;; A bytecode-function is a tagged vector:
    ;;   #(%paal-bytecode-function code arity variadic? upvalue-count name)
    ;;
    ;; Deliberately hand-written rather than define-record-type.  Self-hosting
    ;; keeps two copies of this library live at once — the HOST one and the
    ;; paal-compiled one in cache/paal-bytecode.pbc — and a bytecode-function
    ;; built by either has to be usable by the other, because the self-hosted
    ;; VM runs closures that the HOST pipeline installed into globals.
    ;;
    ;; define-record-type cannot give that.  Under HOST kaappi it produces an
    ;; opaque native record; paal's own expander desugars it to a vector tagged
    ;; with a freshly allocated (list '<name>) pair.  So the two copies disagree
    ;; on representation *and* on tag identity.  Spelling the representation out
    ;; here makes both copies emit the same vector, and an interned symbol as
    ;; the tag is eq? across both.  See kaappi/paal#1.
    ;;
    ;; The trade-off is that a user 6-vector whose first slot happens to be the
    ;; symbol %paal-bytecode-function would be mistaken for one.  Same trade-off
    ;; the exception markers in vm-bc.sld already make.

    (define %bytecode-function-tag '%paal-bytecode-function)

    (define (make-bytecode-function code arity variadic? upvalue-count name)
      (vector %bytecode-function-tag
              (if (vector? code) code (list->vector code))
              arity variadic? upvalue-count name))

    (define (bytecode-function? x)
      (and (vector? x)
           (= (vector-length x) 6)
           (eq? (vector-ref x 0) %bytecode-function-tag)))

    (define (bytecode-function-code fn)          (vector-ref fn 1))
    (define (bytecode-function-arity fn)         (vector-ref fn 2))
    (define (bytecode-function-variadic? fn)     (vector-ref fn 3))
    (define (bytecode-function-upvalue-count fn) (vector-ref fn 4))
    (define (bytecode-function-name fn)          (vector-ref fn 5))))
