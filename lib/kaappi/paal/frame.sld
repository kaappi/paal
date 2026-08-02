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
          make-continuation continuation?
          continuation-regs continuation-frames continuation-target
          continuation-winds continuation-handlers continuation-loop
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

    ;; --- Continuation ---
    ;;
    ;; A first-class continuation for the bytecode VM: the copied live prefix
    ;; of the register file, the frame list as plain data, where the resumed
    ;; value lands, and the wind stack, handler stack and dispatch-loop
    ;; identity at capture.  A tagged vector for the same reason as <closure>
    ;; above — a continuation is a value user programs hold and pass, so both
    ;; self-hosting copies of the pipeline must recognize one.
    ;;
    ;; frames holds plain 4-vectors #(closure ip base dst), never <frame>
    ;; records: records do not cross the copy boundary, and the invoke side
    ;; rebuilds fresh frames anyway, so one snapshot can be entered any number
    ;; of times without sharing mutable ip state between entries.

    (define %continuation-tag '%paal-continuation)

    (define (make-continuation regs-snapshot frames-data target winds handlers loop-id)
      (vector %continuation-tag regs-snapshot frames-data target
              winds handlers loop-id))

    (define (continuation? x)
      (and (vector? x)
           (= (vector-length x) 7)
           (eq? (vector-ref x 0) %continuation-tag)))

    (define (continuation-regs c)     (vector-ref c 1))
    (define (continuation-frames c)   (vector-ref c 2))
    (define (continuation-target c)   (vector-ref c 3))
    (define (continuation-winds c)    (vector-ref c 4))
    (define (continuation-handlers c) (vector-ref c 5))
    (define (continuation-loop c)     (vector-ref c 6))

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
