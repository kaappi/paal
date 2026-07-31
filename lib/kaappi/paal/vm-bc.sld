;;; (kaappi paal vm-bc) — Bytecode VM dispatch loop
;;;
;;; Executes bytecode-function objects produced by (kaappi paal emitter).
;;; Maintains a flat register vector and a frame stack.
;;;
;;; See docs/architecture.md for the call convention and tail-call design.

(define-library (kaappi paal vm-bc)
  (import (scheme base) (kaappi paal bytecode) (kaappi paal frame))
  (export paal-run-bc paal-make-globals
          %paal-guard-run-marker paal-vm-raise-escape!)
  (begin

    (define REGS-SIZE 16384)

    ;; ---------------------------------------------------------------
    ;; guard / raise across the HOST ↔ self-hosted boundary
    ;; ---------------------------------------------------------------
    ;;
    ;; `guard` cannot be an ordinary binding in globals.  A HOST procedure
    ;; cannot invoke a paal closure — paal closures are <closure> records that
    ;; only this dispatch loop knows how to enter — and `guard` has to run a
    ;; body thunk and then, on an exception, a handler.
    ;;
    ;; So the expander compiles (guard ...) into a call to %paal-guard-run,
    ;; whose value in globals is the marker symbol below, and do-call! performs
    ;; the whole operation itself.  Keeping the logic here matters for
    ;; self-hosting: two copies of this library are live at once — the HOST one
    ;; and the paal-compiled one in cache/paal-vm-bc.pbc — and whichever copy is
    ;; running the VM must supply both the exception catch and the callback,
    ;; since each can only enter closures its own copy created.
    ;;
    ;; Both markers are interned symbols on purpose.  A record type or a fresh
    ;; (list 'tag) allocated per copy would not be eq? across the boundary, so
    ;; the paal-compiled VM would fail to recognize a marker installed by the
    ;; HOST library — and vice versa.  Symbols intern to one object in both.

    (define %paal-guard-run-marker '%paal-vm-guard-run)

    ;; paal `raise` is the HOST procedure paal-vm-raise-escape!, which raises a
    ;; HOST exception carrying the paal value in a tagged wrapper.  The wrapper
    ;; keeps arbitrary raised values (strings, numbers, records) distinguishable
    ;; from HOST conditions, so a handler receives exactly what was raised.
    ;; paal-vm-condition strips it; HOST conditions (say, a type error from
    ;; `car`) pass through untouched, so paal `guard` catches primitive errors
    ;; too, as R7RS requires.

    (define %paal-escape-tag '%paal-vm-escape)

    (define (paal-vm-escape? e)
      (and (vector? e) (= (vector-length e) 2)
           (eq? (vector-ref e 0) %paal-escape-tag)))

    (define (paal-vm-raise-escape! obj)
      (raise (vector %paal-escape-tag obj)))

    (define (paal-vm-condition e)
      (if (paal-vm-escape? e) (vector-ref e 1) e))

    ;; ---------------------------------------------------------------
    ;; Global environment (simple association list, mutable via set!)
    ;; ---------------------------------------------------------------

    (define (paal-make-globals initial-alist)
      ; globals is a mutable vector holding a single alist
      (vector initial-alist))

    (define (globals-ref! g sym)
      (let ((pair (assq sym (vector-ref g 0))))
        (if pair
            (cdr pair)
            (error "paal-bc: unbound variable" sym))))

    (define (globals-set! g sym val)
      (let ((pair (assq sym (vector-ref g 0))))
        (if pair
            (set-cdr! pair val)
            (error "paal-bc: set! on unbound variable" sym))))

    (define (globals-define! g sym val)
      (let ((pair (assq sym (vector-ref g 0))))
        (if pair
            (set-cdr! pair val)
            (vector-set! g 0 (cons (cons sym val) (vector-ref g 0))))))

    ;; ---------------------------------------------------------------
    ;; Main entry point
    ;; ---------------------------------------------------------------

    (define (paal-run-bc fn globals)
      (let* ((regs    (make-vector REGS-SIZE #f))
             ; Top-level frame: base=0, dst=0, no closure wrapping needed
             (top-closure (make-closure fn (vector)))
             (top-frame   (make-frame top-closure 0 0))
             (frames  (list top-frame)))
        ; An escape that reached the top was raised by paal code with no guard
        ; around it.  Strip the wrapper and re-raise so the caller sees the value
        ; the program actually raised rather than VM plumbing.
        (guard (e ((paal-vm-escape? e) (raise (vector-ref e 1))))
          (run! regs globals frames))))

    ;; ---------------------------------------------------------------
    ;; Re-entrant call — enter a paal closure from HOST code
    ;; ---------------------------------------------------------------
    ;;
    ;; Runs `callee` on `args` in a nested dispatch loop whose frame list is a
    ;; singleton, so `return` hands the value straight back here instead of
    ;; falling through into the program that was interrupted.
    ;;
    ;; `base` must be a register index at or above the caller's high-water mark;
    ;; the emitter allocates a call's base as the next free register, so anything
    ;; at or above a call's base+1+nargs is unused by every live frame.  The
    ;; nested run therefore cannot clobber the suspended one.  Closure upvalues
    ;; and boxes live in heap objects rather than registers, so values shared
    ;; across the boundary stay intact.

    (define (paal-call-value regs globals base callee args)
      (cond
        ((closure? callee)
         (let* ((fn        (closure-function callee))
                (arity     (bytecode-function-arity fn))
                (variadic? (bytecode-function-variadic? fn)))
           (let loop ((i 0) (as args))
             (cond
               ((< i arity)
                (when (null? as)
                  (error "paal-bc: too few arguments" (bytecode-function-name fn)))
                (vector-set! regs (+ base i) (car as))
                (loop (+ i 1) (cdr as)))
               (variadic?
                (vector-set! regs (+ base arity) as))
               ((not (null? as))
                (error "paal-bc: too many arguments" (bytecode-function-name fn)))))
           (run! regs globals (list (make-frame callee base base)))))

        ((procedure? callee) (apply callee args))

        (else (error "paal-bc: not a callable" callee))))

    ;; ---------------------------------------------------------------
    ;; Dispatch loop
    ;; ---------------------------------------------------------------

    (define (run! regs globals frames)
      (if (null? frames)
          #f
          (let* ((frame (car frames))
                 (instr (frame-fetch! frame)))
            (dispatch! regs globals frames frame instr))))

    (define (dispatch! regs globals frames frame instr)
      (define (abs r) (+ (frame-base frame) r))  ; relative → absolute register

      (case (car instr)

        ;; --- Constants ---

        ((load-const)
         (vector-set! regs (abs (cadr instr)) (caddr instr))
         (run! regs globals frames))

        ((load-true)
         (vector-set! regs (abs (cadr instr)) #t)
         (run! regs globals frames))

        ((load-false)
         (vector-set! regs (abs (cadr instr)) #f)
         (run! regs globals frames))

        ((load-nil)
         (vector-set! regs (abs (cadr instr)) '())
         (run! regs globals frames))

        ;; --- Register move ---

        ((move)
         (vector-set! regs (abs (cadr instr)) (vector-ref regs (abs (caddr instr))))
         (run! regs globals frames))

        ;; --- Globals ---

        ((get-global)
         (vector-set! regs (abs (cadr instr)) (globals-ref! globals (caddr instr)))
         (run! regs globals frames))

        ((set-global)
         (globals-set! globals (cadr instr) (vector-ref regs (abs (caddr instr))))
         (run! regs globals frames))

        ((define-global)
         (globals-define! globals (cadr instr) (vector-ref regs (abs (caddr instr))))
         (run! regs globals frames))

        ;; --- Upvalues ---

        ((get-upvalue)
         (let ((cl (frame-closure frame)))
           (vector-set! regs (abs (cadr instr))
                        (vector-ref (closure-upvalues cl) (caddr instr)))
           (run! regs globals frames)))

        ((set-upvalue)
         (let ((cl (frame-closure frame)))
           (vector-set! (closure-upvalues cl) (cadr instr)
                        (vector-ref regs (abs (caddr instr))))
           (run! regs globals frames)))

        ;; --- Closure instantiation ---

        ((closure)
         (let* ((dst   (cadr instr))
                (fn    (caddr instr))
                (specs (cadddr instr))
                (uvs   (list->vector
                         (map (lambda (spec)
                                (let ((is-local? (car spec))
                                      (src-idx   (cdr spec)))
                                  (if is-local?
                                      (vector-ref regs (abs src-idx))
                                      (vector-ref (closure-upvalues (frame-closure frame))
                                                  src-idx))))
                              specs))))
           (vector-set! regs (abs dst) (make-closure fn uvs))
           (run! regs globals frames)))

        ;; --- Non-tail call ---

        ((call)
         (let* ((base-off  (cadr instr))
                (nargs     (caddr instr))
                (abs-base  (abs base-off))
                (callee    (vector-ref regs abs-base)))
           (do-call! regs globals frames frame callee abs-base nargs base-off #f)))

        ;; --- Tail call ---

        ((tail-call)
         (let* ((base-off (cadr instr))
                (nargs    (caddr instr))
                (abs-base (abs base-off))
                (callee   (vector-ref regs abs-base)))
           (do-call! regs globals frames frame callee abs-base nargs base-off #t)))

        ;; --- Return ---

        ((return)
         (let* ((result   (vector-ref regs (abs (cadr instr))))
                (rest     (cdr frames)))
           (if (null? rest)
               result
               (let ((caller (car rest)))
                 (vector-set! regs (frame-dst frame) result)
                 (run! regs globals rest)))))

        ;; --- Branches ---

        ((jump)
         (frame-set-ip! frame (+ (frame-ip frame) (cadr instr)))
         (run! regs globals frames))

        ((jump-if-false)
         (when (eq? #f (vector-ref regs (abs (cadr instr))))
           (frame-set-ip! frame (+ (frame-ip frame) (caddr instr))))
         (run! regs globals frames))

        ;; --- Mutable box (for letrec/named-let mutable captured variables) ---

        ((make-box)
         ; (make-box dst src) — create 1-element mutable vector
         (vector-set! regs (abs (cadr instr))
                      (vector (vector-ref regs (abs (caddr instr)))))
         (run! regs globals frames))

        ((box-ref)
         ; (box-ref dst src) — read value from box
         (vector-set! regs (abs (cadr instr))
                      (vector-ref (vector-ref regs (abs (caddr instr))) 0))
         (run! regs globals frames))

        ((box-set!)
         ; (box-set! box-reg val-reg) — mutate box
         (vector-set! (vector-ref regs (abs (cadr instr))) 0
                      (vector-ref regs (abs (caddr instr))))
         (run! regs globals frames))

        ((halt)
         (vector-ref regs (abs 0)))

        (else
         (error "paal-bc: unknown opcode" (car instr)))))

    ;; ---------------------------------------------------------------
    ;; Call dispatch (shared by call and tail-call)
    ;; ---------------------------------------------------------------

    ;; Run a guard's body thunk; if it raises, apply the handler to the
    ;; condition.  Both run at register base `nbase`, above the live frames.
    ;;
    ;; Kept separate from do-call! only for legibility.  Inlining it once broke
    ;; `make pbc-pipeline` with an opaque "read error" on cache/paal-vm-bc.pbc,
    ;; which looked like a size or nesting budget — it is not.  kaappi's `read`
    ;; mis-handles a dotted pair straddling a 4096-byte chunk boundary on a file
    ;; port (kaappi/kaappi#1920), and inlining merely shifted the byte offsets
    ;; so that one of the `(#t . N)` upvalue specs landed on one.  Splitting the
    ;; procedure is not a defence: any edit to this file can shift offsets again.
    (define (run-guard! regs globals nbase body handler)
      (guard (e (#t (paal-call-value regs globals nbase handler
                                     (list (paal-vm-condition e)))))
        (paal-call-value regs globals nbase body '())))

    ;; Hand `result` back to the caller of a completed HOST call or guard.
    (define (deliver-result! regs globals frames frame abs-base result tail?)
      (if tail?
          ; Tail call: deliver to the caller's dst, or return if there is none.
          (let ((rest (cdr frames)))
            (if (null? rest)
                result
                (begin
                  (vector-set! regs (frame-dst frame) result)
                  (run! regs globals rest))))
          (begin
            (vector-set! regs abs-base result)
            (run! regs globals frames))))

    ;; Collect the nargs arguments sitting above the callee slot.
    (define (call-args regs abs-base nargs)
      (let loop ((i nargs) (acc '()))
        (if (= i 0)
            acc
            (loop (- i 1) (cons (vector-ref regs (+ abs-base i)) acc)))))

    (define (do-call! regs globals frames frame callee abs-base nargs base-off tail?)
      (cond
        ; Paal closure
        ((closure? callee)
         (let* ((fn        (closure-function callee))
                (arity     (bytecode-function-arity fn))
                (variadic? (bytecode-function-variadic? fn))
                (new-base  (+ abs-base 1)))
           ; Handle variadic: collect rest args into a list
           (when variadic?
             (let ((rest-args
                     (let loop ((i (+ new-base arity)) (end (+ abs-base nargs)) (acc '()))
                       (if (> i end)
                           (reverse acc)
                           (loop (+ i 1) end (cons (vector-ref regs i) acc))))))
               (vector-set! regs (+ new-base arity) rest-args)))
           (let ((new-frame (make-frame callee new-base abs-base)))
             (if tail?
                 ; Reuse caller's register space: copy args to frame.base
                 (let* ((caller-base (frame-base frame))
                        (caller-dst  (frame-dst  frame))
                        ; Snapshot args before overwriting
                        (arg-vals (let loop ((i 0) (acc '()))
                                    (if (= i (+ arity (if variadic? 1 0)))
                                        (reverse acc)
                                        (loop (+ i 1)
                                              (cons (vector-ref regs (+ new-base i)) acc))))))
                   (for-each (lambda (val i)
                               (vector-set! regs (+ caller-base i) val))
                             arg-vals
                             (let lp ((i 0) (acc '()))
                               (if (= i (length arg-vals)) (reverse acc)
                                   (lp (+ i 1) (cons i acc)))))
                   (let ((reused (make-frame callee caller-base caller-dst)))
                     (run! regs globals (cons reused (cdr frames)))))
                 (run! regs globals (cons new-frame frames))))))

        ; guard — (%paal-guard-run body-thunk handler); see run-guard! above.
        ((eq? callee %paal-guard-run-marker)
         (deliver-result! regs globals frames frame abs-base
                          (run-guard! regs globals (+ abs-base nargs 1)
                                      (vector-ref regs (+ abs-base 1))
                                      (vector-ref regs (+ abs-base 2)))
                          tail?))

        ; Host (Scheme) procedure
        ((procedure? callee)
         (let ((result (apply callee (call-args regs abs-base nargs))))
           (deliver-result! regs globals frames frame abs-base result tail?)))

        (else
         (error "paal-bc: not a callable" callee))))))
