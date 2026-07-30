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
;;;   (closure     dst fn specs)  instantiate closure; specs = ((local? . idx)...)
;;;   (call        base nargs)    non-tail call; callee at reg[base]
;;;   (tail-call   base nargs)    tail call; reuses current frame
;;;   (return      src)           return reg[src] to caller
;;;   (jump        offset)        ip += offset + 1  (relative to next instr)
;;;   (jump-if-false test offset) if reg[test]=#f, ip += offset + 1
;;;   (halt)                      stop; caller receives reg[0]

(define-library (kaappi paal bytecode)
  (import (scheme base))
  (export make-bytecode-function bytecode-function?
          bytecode-function-code
          bytecode-function-arity
          bytecode-function-variadic?
          bytecode-function-upvalue-count
          bytecode-function-name)
  (begin

    (define-record-type <bytecode-function>
      (%make-bytecode-function code arity variadic? upvalue-count name)
      bytecode-function?
      (code          bytecode-function-code)
      (arity         bytecode-function-arity)
      (variadic?     bytecode-function-variadic?)
      (upvalue-count bytecode-function-upvalue-count)
      (name          bytecode-function-name))

    (define (make-bytecode-function code arity variadic? upvalue-count name)
      (%make-bytecode-function
        (if (vector? code) code (list->vector code))
        arity variadic? upvalue-count name))))
