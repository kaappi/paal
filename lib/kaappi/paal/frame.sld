;;; (kaappi paal frame) — Call frame and closure records for the bytecode VM
;;;
;;; Register layout:
;;;   regs[frame.base + 0]  = arg0 (or first local)
;;;   regs[frame.base + 1]  = arg1 ...
;;;
;;; Call convention (matching docs/architecture.md):
;;;   Caller places callee at regs[caller.base + call-base].
;;;   Args follow at regs[caller.base + call-base + 1 .. + nargs].
;;;   New frame: base = caller.base + call-base + 1
;;;   Return value: stored at regs[frame.dst]  (absolute index)

(define-library (kaappi paal frame)
  (import (scheme base) (kaappi paal bytecode))
  (export make-closure closure? closure-function closure-upvalues
          make-frame   frame?
          frame-closure frame-set-closure!
          frame-code    frame-set-code!
          frame-ip      frame-set-ip!
          frame-base    frame-dst
          frame-fetch!)
  (begin

    ;; --- Closure ---

    (define-record-type <closure>
      (make-closure function upvalues)
      closure?
      (function  closure-function)
      (upvalues  closure-upvalues))    ; vector of captured values

    ;; --- Call frame ---

    (define-record-type <frame>
      (%make-frame closure code ip base dst)
      frame?
      (closure frame-closure frame-set-closure!)
      (code    frame-code    frame-set-code!)
      (ip      frame-ip      frame-set-ip!)
      (base    frame-base)
      (dst     frame-dst))

    (define (make-frame closure base dst)
      (%make-frame closure
                   (bytecode-function-code (closure-function closure))
                   0
                   base
                   dst))

    ;; Fetch the current instruction and advance ip.
    (define (frame-fetch! frame)
      (let ((instr (vector-ref (frame-code frame) (frame-ip frame))))
        (frame-set-ip! frame (+ (frame-ip frame) 1))
        instr))))
