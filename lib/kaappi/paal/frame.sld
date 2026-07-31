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
    ;;
    ;; A closure is a tagged vector:  #(%paal-closure function upvalues)
    ;;
    ;; Hand-written rather than define-record-type for the same reason as
    ;; <bytecode-function> — see the note in bytecode.sld.  Closures are the
    ;; values that actually cross the HOST/self-hosted boundary: the HOST
    ;; pkaappi-make-globals installs paal-compiled `map`, `apply`, `force` and
    ;; friends into the globals table, and the self-hosted VM has to be able to
    ;; enter them.  With define-record-type it could not, and every one of those
    ;; procedures failed with "not a callable" under pkaappi-self-run-file
    ;; (kaappi/paal#1).
    ;;
    ;; <frame> below stays a record: frames are created and consumed inside a
    ;; single VM invocation and never cross.

    (define %closure-tag '%paal-closure)

    (define (make-closure function upvalues)   ; upvalues: vector of captured values
      (vector %closure-tag function upvalues))

    (define (closure? x)
      (and (vector? x)
           (= (vector-length x) 3)
           (eq? (vector-ref x 0) %closure-tag)))

    (define (closure-function cl) (vector-ref cl 1))
    (define (closure-upvalues cl) (vector-ref cl 2))

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
