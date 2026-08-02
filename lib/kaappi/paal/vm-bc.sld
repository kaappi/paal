;;; (kaappi paal vm-bc) — Bytecode VM dispatch loop
;;;
;;; Executes bytecode-function objects produced by (kaappi paal emitter).
;;; Maintains a flat register vector and a frame stack.
;;;
;;; See docs/architecture.md for the call convention and tail-call design.

(define-library (kaappi paal vm-bc)
  (import (scheme base) (kaappi paal bytecode) (kaappi paal frame))
  (export paal-run-bc paal-make-globals
          %paal-guard-run-marker %paal-apply-marker %paal-callcc-marker
          %paal-spawn-marker %paal-ffi-callback-marker
          paal-vm-raise-escape!
          paal-profile-start! paal-profile-report paal-profile-masked
          paal-coverage-start! paal-coverage-report paal-coverage-hits
          paal-debug-start! paal-debug-stop!
          paal-debug-break! paal-debug-unbreak! paal-debug-breaks)
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

    ;; apply is a marker for the same reason: the `call` instruction carries a
    ;; fixed nargs operand, so no procedure written in paal can call another
    ;; with an argument count known only at run time.  Written in paal it has to
    ;; dispatch on (length args) through a hand-unrolled cond, which is where
    ;; the old 16-argument ceiling came from.  do-call! can just spread the list
    ;; into argument registers and issue the call.
    (define %paal-apply-marker '%paal-vm-apply)

    ;; call/cc is a marker for the closure-boundary reason guard is one: the
    ;; receiver is usually a paal closure, and capture needs the frame list and
    ;; register file, which only do-call! can see.  Invoking the captured
    ;; continuation is a do-call! arm too, so (apply k args) works unchanged.
    (define %paal-callcc-marker '%paal-vm-call/cc)

    ;; spawn and ffi-callback are markers for the boundary reason again, with
    ;; a twist: their procedure argument is not called now but *later*, from
    ;; HOST code — the fiber scheduler, or C.  The arm wraps the paal closure
    ;; in a HOST trampoline over paal-call-value and hands that to the raw
    ;; primitive, kept in the table under a %paal-host- name.
    (define %paal-spawn-marker '%paal-vm-spawn)
    (define %paal-ffi-callback-marker '%paal-vm-ffi-callback)

    ;; A continuation invoked outside the dispatch loop that captured it cannot
    ;; be resumed by returning — the loop that owns its frames is suspended
    ;; somewhere down the HOST stack, or already gone.  The invoke escapes with
    ;; this tag instead; run-guard! passes it through untouched, and the retry
    ;; loop in paal-run-bc resumes the continuation when the loop identity
    ;; matches or reports it cleanly when it never can.  A 3-vector, so
    ;; paal-vm-escape? (length 2) never confuses the two.
    (define %paal-cont-invoke-tag '%paal-vm-cont-invoke)

    (define (paal-vm-cont-invoke? e)
      (and (vector? e) (= (vector-length e) 3)
           (eq? (vector-ref e 0) %paal-cont-invoke-tag)))

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

    ;; Like globals-ref! but yields `default` when the name is unbound, for
    ;; globals tables built straight from paal-initial-env rather than by
    ;; pkaappi-make-globals — those have no handler stack.
    (define (globals-ref-default g sym default)
      (let ((pair (assq sym (vector-ref g 0))))
        (if pair (cdr pair) default)))

    (define (globals-define! g sym val)
      (let ((pair (assq sym (vector-ref g 0))))
        (if pair
            (set-cdr! pair val)
            (vector-set! g 0 (cons (cons sym val) (vector-ref g 0))))))

    ;; ---------------------------------------------------------------
    ;; Main entry point
    ;; ---------------------------------------------------------------

    ;; Every dispatch-loop episode carries a fresh identity in globals under
    ;; %paal-vm-loop — a fresh pair, compared with eq?.  A continuation may
    ;; only restore frames inside the episode that captured them: frames of a
    ;; finished episode have no loop left to return into, and frames of a
    ;; suspended one are reachable only by unwinding the HOST stack back to
    ;; it, which is what the %paal-vm-cont-invoke escape does.
    ;; paal-call-value gives its nested episode a fresh identity too, so a
    ;; capture inside a guard body cannot be replayed after the body's loop
    ;; has returned — invoking such a continuation reports it cleanly instead
    ;; of resuming dead frames.

    (define (paal-run-bc fn globals)
      (let* ((regs    (make-vector REGS-SIZE #f))
             ; Top-level frame: base=0, dst=0, no closure wrapping needed
             (top-closure (make-closure fn (vector)))
             (top-frame   (make-frame top-closure 0 0))
             (my-id    (list 'loop))
             (outer-id (globals-ref-default globals '%paal-vm-loop #f)))
        (globals-define! globals '%paal-vm-loop my-id)
        ; The retry loop re-arms the guard after every resumed continuation,
        ; so one episode absorbs any number of cross-loop invokes.  An escape
        ; that reached the top was raised by paal code with no guard around
        ; it: strip the wrapper and re-raise so the caller sees the value the
        ; program actually raised rather than VM plumbing.
        (let ((result
               (let retry ((fs (list top-frame)))
                 (guard (e ((paal-vm-cont-invoke? e)
                            (let ((cont  (vector-ref e 1))
                                  (value (vector-ref e 2)))
                              (if (eq? (continuation-loop cont) my-id)
                                  (begin
                                    ; The escape skipped every nested restore
                                    ; on the way here, so reclaim the identity
                                    ; before resuming.
                                    (globals-define! globals '%paal-vm-loop my-id)
                                    (let ((nfs (restore-cont! regs cont value)))
                                      (if (null? nfs) value (retry nfs))))
                                  (error "paal-bc: continuation invoked outside its dispatch extent"))))
                           ((paal-vm-escape? e) (raise (vector-ref e 1)))
                           ; A raw HOST condition — a primitive's error — with
                           ; no paal guard anywhere below this loop.  paal
                           ; `raise` consults %paal-handlers before escaping,
                           ; but a primitive raises through the HOST condition
                           ; system, which only a guard's host-side catch
                           ; intercepts — so a with-exception-handler with no
                           ; guard around it never saw primitive errors (the
                           ; shelf's srfi 27/35 audits are exactly that shape:
                           ; call/cc + handler, no guard).  Run the top
                           ; handler here, after the unwind — the timing
                           ; kaappi's own handlers get.  The tree-walking
                           ; pipeline needs none of this: it binds the HOST
                           ; with-exception-handler, so primitive errors run
                           ; its handlers natively.
                           ;
                           ; A handler escapes into a captured continuation as
                           ; a rule; when the continuation is this episode's,
                           ; its invoke raises through this very arm, where
                           ; the retry loop is still in scope — the outer
                           ; guard cannot re-catch a raise from its own
                           ; clause, so the resume happens here, mirroring the
                           ; cont-invoke arm above.  Returning from the
                           ; handler belongs to the non-continuable raise
                           ; protocol: the blob-raise secondary error.
                           ((let ((hs (globals-ref-default globals '%paal-handlers '())))
                              (and (pair? hs) hs))
                            => (lambda (hs)
                                 (globals-define! globals '%paal-handlers (cdr hs))
                                 (guard (e2 ((and (paal-vm-cont-invoke? e2)
                                                  (eq? (continuation-loop (vector-ref e2 1))
                                                       my-id))
                                             (globals-define! globals '%paal-vm-loop my-id)
                                             (let ((nfs (restore-cont! regs (vector-ref e2 1)
                                                                       (vector-ref e2 2))))
                                               (if (null? nfs)
                                                   (vector-ref e2 2)
                                                   (retry nfs)))))
                                   (paal-call-value regs globals 0 (car hs) (list e))
                                   (globals-define! globals '%paal-handlers hs)
                                   (error "paal-bc: handler returned from non-continuable raise")))))
                   (run! regs globals fs)))))
          (globals-define! globals '%paal-vm-loop outer-id)
          result)))

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
           ; A fresh loop identity for the nested episode: a continuation
           ; captured inside it must not be replayable once this run! has
           ; returned.  On an escape the restore below is skipped — every
           ; catcher reinstalls the identity current at its own entry.
           ;
           ; The retry guard mirrors paal-run-bc's, and it exists for the
           ; same two jobs *at nested depth*.  First, a continuation this
           ; episode owns can now be resumed from a catcher's arm — without
           ; the retry, a guard body's episode became unresumable the moment
           ; a HOST catch unwound its run!, though its frames lived on in
           ; the capture.  Second, and the reason the first matters: a raw
           ; primitive error must visit any with-exception-handler entries
           ; the episode pushed *before* some enclosing guard's clauses see
           ; it — paal `raise` consults %paal-handlers, but a primitive
           ; raises through the HOST condition system, which no paal-side
           ; stack ever sees.  This is the innermost host frame that can
           ; still resume the episode, so the routing lives here: pop and
           ; call handlers innermost-first, and when one escapes into a
           ; continuation of this episode — the (call/cc k) +
           ; with-exception-handler idiom — the inner arm resumes it on the
           ; retry loop.  A handler that returns violates the
           ; non-continuable protocol and its secondary error goes outward
           ; to the nearest guard, blob-raise style; a handler that raises
           ; a paal value has walked the remaining stack itself, so its
           ; vm-escape passes outward untouched.  With no handler pending —
           ; the stack empty or a guard's escape on top — the condition
           ; re-raises outward exactly as before, so guard-only programs
           ; never enter the arm.
           (let ((outer-id (globals-ref-default globals '%paal-vm-loop #f))
                 (my-id    (list 'loop)))
             (globals-define! globals '%paal-vm-loop my-id)
             (let ((result
                    (let retry ((fs (list (make-frame callee base base))))
                      (guard (e ((and (paal-vm-cont-invoke? e)
                                      (eq? (continuation-loop (vector-ref e 1))
                                           my-id))
                                 (globals-define! globals '%paal-vm-loop my-id)
                                 (let ((nfs (restore-cont! regs (vector-ref e 1)
                                                           (vector-ref e 2))))
                                   (if (null? nfs) (vector-ref e 2) (retry nfs))))
                                ((paal-vm-cont-invoke? e) (raise e))
                                ((paal-vm-escape? e) (raise e))
                                ((let ((hs (globals-ref-default
                                             globals '%paal-handlers '()))
                                       (esc (globals-ref-default
                                              globals '%paal-vm-raise #f)))
                                   (and (pair? hs)
                                        (not (eq? (car hs) esc))
                                        hs))
                                 =>
                                 (lambda (hs0)
                                   (let ((esc (globals-ref-default
                                                globals '%paal-vm-raise #f)))
                                     (let route ((condition e) (hs hs0))
                                       (if (or (null? hs)
                                               (eq? (car hs) esc))
                                           (raise condition)
                                           (begin
                                             (globals-define!
                                               globals '%paal-handlers (cdr hs))
                                             (let ((outcome
                                                    (guard (e2 ((and (paal-vm-cont-invoke? e2)
                                                                     (eq? (continuation-loop
                                                                            (vector-ref e2 1))
                                                                          my-id))
                                                                (globals-define!
                                                                  globals '%paal-vm-loop my-id)
                                                                (let ((nfs (restore-cont!
                                                                             regs
                                                                             (vector-ref e2 1)
                                                                             (vector-ref e2 2))))
                                                                  (vector 'resumed
                                                                          (if (null? nfs)
                                                                              (vector-ref e2 2)
                                                                              (retry nfs)))))
                                                               ((paal-vm-cont-invoke? e2)
                                                                (raise e2))
                                                               ((paal-vm-escape? e2)
                                                                (raise e2))
                                                               (#t (vector 'route e2)))
                                                      (paal-call-value
                                                        regs globals base
                                                        (car hs) (list condition))
                                                      'returned)))
                                               (cond
                                                 ((eq? outcome 'returned)
                                                  (raise (handler-returned-condition)))
                                                 ((eq? (vector-ref outcome 0) 'resumed)
                                                  (vector-ref outcome 1))
                                                 (else
                                                  (route (vector-ref outcome 1)
                                                         (globals-ref-default
                                                           globals
                                                           '%paal-handlers '()))))))))))))
                        (run! regs globals fs)))))
               (globals-define! globals '%paal-vm-loop outer-id)
               result))))

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
           (when %debug-hook (debug-return! regs frames frame result))
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
    ;; procedure was never the defence; paal-read-bc-file now parses .pbc from a
    ;; string port, which removes the boundary entirely.
    ;; In R7RS terms a guard *is* an exception handler, and must be the innermost
    ;; one while its body runs: a raise-continuable inside the body belongs to
    ;; this guard, not to an enclosing with-exception-handler.  Pushing the escape
    ;; procedure itself onto the handler stack achieves that — paal `raise` and
    ;; `raise-continuable` call whatever is on top, and calling this one lands in
    ;; the HOST guard below, where the clauses run.  Without it an outer
    ;; with-exception-handler would swallow conditions belonging to this guard.
    ;;
    ;; The stack is restored before the clauses run, so an unmatched clause
    ;; re-raises to the *outer* handler rather than back into this one.
    ;;
    ;; Everything past the catch is one call into %paal-guard-catch, which is
    ;; paal source (see lib/kaappi/paal.sld).  It owns the R7RS 4.2.7 dance:
    ;; the clauses are evaluated in the dynamic environment of the guard, but an
    ;; unmatched condition is re-raised in that of the original raise.  It needs
    ;; the wind stack as it stood when this guard was entered, which only this
    ;; procedure can still see, so `winds` is passed in.  With no
    ;; %paal-guard-catch — a globals table straight from paal-initial-env — the
    ;; clauses are applied directly and an unmatched condition re-raised here.
    ;;
    ;; The escape pushed onto the stack is taken from globals rather than being
    ;; this library's own paal-vm-raise-escape!.  Under self-hosting this file is
    ;; paal-compiled, so that name would be a paal closure — and a paal closure
    ;; resolves its free globals against whichever table the VM happens to be
    ;; running, not the one it was compiled in.  Pushing it into the user
    ;; program's globals left its own module-level names unbound at call time.
    ;; The globals entry is the HOST procedure, callable from any table, and it
    ;; raises the same interned-symbol tag either copy recognizes.
    ;;
    ;; #f means "no handler stack here" — a globals table built straight from
    ;; paal-initial-env has neither name, and needs no push.
    (define (run-guard! regs globals nbase body handler)
      (let ((escape (globals-ref-default globals '%paal-vm-raise #f))
            (saved  (globals-ref-default globals '%paal-handlers #f))
            (catch  (globals-ref-default globals '%paal-guard-catch #f))
            (winds  (globals-ref-default globals '%paal-winds '()))
            (entry-id (globals-ref-default globals '%paal-vm-loop #f)))
        (when (and escape saved)
          (globals-define! globals '%paal-handlers (cons escape saved)))
        (let ((result
               (guard (e ((paal-vm-cont-invoke? e)
                          ; A continuation invoke passing through on its way to
                          ; the loop that owns it.  Nothing here may touch
                          ; %paal-handlers: the invoke already installed the
                          ; captured stack, and restoring `saved` would clobber
                          ; it.  The winds are the invoke's business too.
                          (raise e))
                         (#t (when saved
                               (globals-define! globals '%paal-handlers saved))
                             ; The escape skipped paal-call-value's restore, so
                             ; the body loop's identity is still current; the
                             ; clauses belong to this guard's own loop.
                             ;
                             ; A *raw* HOST condition arriving here has already
                             ; visited any with-exception-handler entries the
                             ; body pushed: paal-call-value's own retry guard
                             ; routes primitive errors through them while the
                             ; body's episode is still resumable.  Whatever
                             ; reaches this catch belongs to the clauses.
                             (globals-define! globals '%paal-vm-loop entry-id)
                             (let ((condition (paal-vm-condition e)))
                               (if catch
                                   (paal-call-value regs globals nbase catch
                                                    (list condition handler winds))
                                   (run-clauses-bare! regs globals nbase
                                                      handler condition)))))
                 (paal-call-value regs globals nbase body '()))))
          (when saved
            (globals-define! globals '%paal-handlers saved))
          result)))

    ;; A HOST condition value to stand for the blob raise's secondary error,
    ;; built by catching our own raise so no host constructor is assumed.
    (define (handler-returned-condition)
      (guard (e (#t e))
        (error "handler returned from non-continuable raise")))

    ;; Fallback for a globals table with no %paal-guard-catch: no wind stack to
    ;; restore, so the clauses can be applied straight and an unmatched
    ;; condition re-raised from here.  The escape comes from globals when there
    ;; is one, for the reason given above.
    (define (run-clauses-bare! regs globals nbase handler condition)
      (let ((result (paal-call-value regs globals nbase handler (list condition))))
        (if (eq? result (globals-ref-default globals '%paal-guard-no-match #f))
            (let ((escape (globals-ref-default globals '%paal-vm-raise #f)))
              (if escape (escape condition) (paal-vm-raise-escape! condition)))
            result)))

    ;; Hand `result` back to the caller of a completed HOST call or guard.
    ;;
    ;; With tail? the current frame is finishing, so this is a frame return and
    ;; the debugger hears about it — a `return` instruction is not the only way
    ;; out of a frame.  A procedure whose body ends in a call to a primitive
    ;; leaves through here instead, which for a program written entirely in tail
    ;; position is *every* return it makes.  Without tail? the frame carries on
    ;; with the primitive's value in a register, which is not an event.
    (define (deliver-result! regs globals frames frame abs-base result tail?)
      (when (and %debug-hook tail?)
        (debug-return! regs frames frame result))
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

    ;; (a1 ... an lst) -> (a1 ... an . lst).  apply's final argument holds the
    ;; trailing arguments; everything before it is passed through as given.
    (define (flatten-apply-args as)
      (if (null? (cdr as))
          (car as)
          (cons (car as) (flatten-apply-args (cdr as)))))

    ;; Collect the nargs arguments sitting above the callee slot.
    (define (call-args regs abs-base nargs)
      (let loop ((i nargs) (acc '()))
        (if (= i 0)
            acc
            (loop (- i 1) (cons (vector-ref regs (+ abs-base i)) acc)))))

    ;; --- continuations -------------------------------------------------
    ;;
    ;; Full-copy, multi-shot, kaappi's model: capture copies the live register
    ;; prefix and the frame list; invoke copies them back and re-enters the
    ;; dispatch loop.  An escape-only design was tried before this and
    ;; reverted — it cannot honour dynamic-wind re-entry, and its escapes were
    ;; swallowed by intervening guards (see docs/architecture.md).  The wind
    ;; stack needs no new machinery here: a dynamic environment in paal is
    ;; data, and %paal-wind-out!/%paal-wind-in! already walk the difference
    ;; between two states.

    ;; Capture the current continuation as seen at a call/cc call site.
    ;;
    ;; Registers: the live prefix [0, abs-base+nargs+1).  The emitter
    ;; allocates a call's base as the next free register and bases grow
    ;; monotonically down the frame list — across nested paal-call-value
    ;; episodes too — so everything at or above that bound is unused by every
    ;; live frame.
    ;;
    ;; Frames: #(closure ip base dst) per frame, innermost first.
    ;; frame-fetch! pre-increments, so the top frame's ip already points at
    ;; the resume point.  In tail position the current frame is finishing —
    ;; the captured continuation is the caller's — so the current frame is
    ;; dropped and the value lands where this frame would have delivered.
    ;;
    ;; Winds and handlers are the list values themselves: both stacks grow by
    ;; rebinding, never by in-place mutation, so holding the reference is a
    ;; true snapshot.  %paal-vm-none marks a table that has no handler stack
    ;; (one built straight from paal-initial-env), so invoke can skip it.
    (define (capture-continuation regs globals frames frame abs-base nargs tail?)
      (let* ((snap  (vector-copy regs 0 (+ abs-base nargs 1)))
             (fdata (let walk ((fs (if tail? (cdr frames) frames)))
                      (if (null? fs)
                          '()
                          (cons (vector (frame-closure (car fs))
                                        (frame-ip (car fs))
                                        (frame-base (car fs))
                                        (frame-dst (car fs)))
                                (walk (cdr fs))))))
             (target (if tail? (frame-dst frame) abs-base)))
        (make-continuation snap fdata target
                           (globals-ref-default globals '%paal-winds '())
                           (globals-ref-default globals '%paal-handlers '%paal-vm-none)
                           (globals-ref-default globals '%paal-vm-loop #f))))

    ;; Rebuild fresh frames from a continuation's snapshot.  Fresh records per
    ;; invoke: frames mutate their ip as they run, and one snapshot may be
    ;; entered any number of times.
    (define (rebuild-frames fdata)
      (if (null? fdata)
          '()
          (let* ((fd (car fdata))
                 (f  (make-frame (vector-ref fd 0)
                                 (vector-ref fd 2)
                                 (vector-ref fd 3))))
            (frame-set-ip! f (vector-ref fd 1))
            (cons f (rebuild-frames (cdr fdata))))))

    ;; Install a continuation's registers and deliver the value; the rebuilt
    ;; frame list comes back, '() when the capture was at the bottom of its
    ;; loop — the value is then the episode's own result.  Restoring a prefix
    ;; is sound: frames only address registers at or above their own base, so
    ;; everything a restored frame can read lies inside the snapshot, and
    ;; anything the abandoned computation left above it is dead.
    (define (restore-cont! regs cont value)
      (let ((snap (continuation-regs cont)))
        (vector-copy! regs 0 snap 0 (vector-length snap))
        (let ((frames (rebuild-frames (continuation-frames cont))))
          (vector-set! regs (continuation-target cont) value)
          frames)))

    ;; The deepest shared tail of two wind stacks.  Both are shared-tail
    ;; lists, so aligning the lengths and walking in step finds the join; '()
    ;; — no shared extent — is a valid answer, since it is the empty tail of
    ;; both.
    (define (winds-common-tail a b)
      (let* ((la (length a))
             (lb (length b))
             (a2 (if (> la lb) (list-tail a (- la lb)) a))
             (b2 (if (> lb la) (list-tail b (- lb la)) b)))
        (let walk ((x a2) (y b2))
          (if (eq? x y) x (walk (cdr x) (cdr y))))))

    ;; Invoke a continuation with the given arguments.
    ;;
    ;; One argument is that value; any other count is delivered as the same
    ;; MVR-tagged list the blob's `values` builds, so a call-with-values
    ;; consumer receives them all.  Then the dynamic extent moves: wind out of
    ;; the extents entered since the capture and back into the captured ones —
    ;; the same wind-stack walk a declining guard performs — and the handler
    ;; stack is restored by assignment, which matters because
    ;; with-exception-handler's trailing restore never runs when a
    ;; continuation escapes its thunk.  safe-base sits above every live
    ;; register, so the wind thunks run without clobbering anything.
    ;;
    ;; Control: within the capturing episode the restored frames are simply
    ;; entered — everything from run! down is in tail position, so repeated
    ;; invokes grow neither the HOST stack nor the frame list.  Anywhere else
    ;; the invoke escapes to the loop that owns the frames; see
    ;; %paal-cont-invoke-tag above.
    (define (invoke-continuation! regs globals cont args safe-base)
      (let ((value
             (if (and (pair? args) (null? (cdr args)))
                 (car args)
                 (let ((tag (globals-ref-default globals '%paal-mvr-tag #f)))
                   (if tag
                       (cons tag args)
                       (error "paal-bc: continuation expects one value" args)))))
            (from (globals-ref-default globals '%paal-winds '()))
            (to   (continuation-winds cont)))
        (when (not (eq? from to))
          (let ((wind-out (globals-ref-default globals '%paal-wind-out! #f))
                (wind-in  (globals-ref-default globals '%paal-wind-in! #f)))
            (when wind-out
              (let ((common (winds-common-tail from to)))
                (paal-call-value regs globals safe-base wind-out (list from common))
                (globals-define! globals '%paal-winds common)
                (paal-call-value regs globals safe-base wind-in (list to common))
                (globals-define! globals '%paal-winds to)))))
        (let ((h (continuation-handlers cont)))
          (when (not (eq? h '%paal-vm-none))
            (globals-define! globals '%paal-handlers h)))
        (if (eq? (continuation-loop cont)
                 (globals-ref-default globals '%paal-vm-loop #f))
            (let ((fs (restore-cont! regs cont value)))
              (if (null? fs) value (run! regs globals fs)))
            (raise (vector %paal-cont-invoke-tag cont value)))))

    ;; --- profiling ---------------------------------------------------
    ;;
    ;; Off unless paal-profile-start! is called, so the call path pays one
    ;; boolean test and nothing else in the normal case.  Counted here rather
    ;; than in paal-call-value because do-call! is where every paal-level call
    ;; arrives, tail and non-tail alike; paal-call-value is only the HOST
    ;; re-entry door and sees a small fraction of them.
    ;;
    ;; Keyed by the function's name, with anonymous lambdas sharing #f rather
    ;; than being dropped, so the counts still add up to the calls made.

    (define %profiling? #f)
    (define %profile-counts '())

    (define (paal-profile-start!)
      (set! %profiling? #t)
      (set! %profile-counts '()))

    (define (paal-profile-count! callee)
      (let* ((name (bytecode-function-name (closure-function callee)))
             (hit  (assq name %profile-counts)))
        (if hit
            (set-cdr! hit (+ (cdr hit) 1))
            (set! %profile-counts (cons (cons name 1) %profile-counts)))))

    ;; Unsorted: the caller decides presentation, and sorting here would need
    ;; a total order on names this VM has no reason to define.
    (define (paal-profile-report) %profile-counts)

    ;; Run thunk with counting off, restoring the prior state on the way out.
    ;; %make-globals-table wraps itself in this: the blob's load-time calls
    ;; (the port blob calls make-parameter) are no more the user's code than
    ;; the blob's definitions are — the same judgement the debugger's
    ;; identity-snapshot skip and coverage's baseline snapshot already make —
    ;; and a table built mid-run by eval or environment would otherwise leak
    ;; those calls into the counts too, which no snapshot taken at start time
    ;; can see coming.
    (define (paal-profile-masked thunk)
      (let ((was %profiling?))
        (dynamic-wind
          (lambda () (set! %profiling? #f))
          thunk
          (lambda () (set! %profiling? was)))))

    ;; --- coverage ------------------------------------------------------
    ;;
    ;; Which procedures a run actually called, over which it defined.  Reuses
    ;; the profile counts for "called" -- a procedure is covered exactly when
    ;; it was called at least once -- so starting coverage starts profiling.
    ;;
    ;; "Defined" is read off the globals table at report time: every entry
    ;; whose value is a paal closure.  That needs no emitter support, but it
    ;; would also sweep up the procedures pkaappi-make-globals installs (map,
    ;; filter, with-exception-handler and the rest of the blob), which are not
    ;; the user's code.  So the start call snapshots the table, and only
    ;; entries added afterwards count -- the same take-until trick the macro
    ;; table uses for library-local macros.

    (define %coverage-baseline #f)

    (define (paal-coverage-start! globals)
      (paal-profile-start!)
      (set! %coverage-baseline (vector-ref globals 0)))

    ;; -> (covered total uncalled-names)
    (define (paal-coverage-report globals)
      (let loop ((alist (vector-ref globals 0))
                 (total 0) (covered 0) (uncalled '()))
        (cond
          ((or (null? alist) (eq? alist %coverage-baseline))
           (list covered total (reverse uncalled)))
          ((closure? (cdr (car alist)))
           (let ((name (car (car alist))))
             (if (assq name %profile-counts)
                 (loop (cdr alist) (+ total 1) (+ covered 1) uncalled)
                 (loop (cdr alist) (+ total 1) covered (cons name uncalled)))))
          (else (loop (cdr alist) total covered uncalled)))))

    ;; -> ((name . hits) ...) over the same entries paal-coverage-report
    ;; counts, in definition order, zeroes included — what a per-line
    ;; coverage writer needs and the summary does not.  The alist is
    ;; newest-first, so consing on the way down restores program order.
    (define (paal-coverage-hits globals)
      (let loop ((alist (vector-ref globals 0)) (acc '()))
        (cond
          ((or (null? alist) (eq? alist %coverage-baseline)) acc)
          ((closure? (cdr (car alist)))
           (let* ((name (car (car alist)))
                  (hit  (assq name %profile-counts)))
             (loop (cdr alist)
                   (cons (cons name (if hit (cdr hit) 0)) acc))))
          (else (loop (cdr alist) acc)))))

    ;; --- stepping debugger ---------------------------------------------
    ;;
    ;; Same shape as profiling: nothing runs unless a hook is installed, so the
    ;; call path pays one test against #f.  Events fire at the two places where
    ;; the frame stack changes shape — a call to a paal closure in do-call!, and
    ;; a frame return in dispatch! — which between them are every point a
    ;; debugger has anything to say about.
    ;;
    ;; The hook is HOST code and is handed nothing but data:
    ;;
    ;;   (hook kind name value depth backtrace) -> command
    ;;
    ;;     kind       'call or 'return
    ;;     name       the procedure's name, or #f for an anonymous lambda
    ;;     value      the argument list ('call) or the returned value ('return)
    ;;     depth      how many frames are live
    ;;     backtrace  ((name arg ...) ...), innermost frame first
    ;;
    ;; and answers 'step, 'next, 'finish or 'continue.  No frame, register or
    ;; closure object is exposed, so a hook cannot disturb the run it is
    ;; watching — and a test hook is an ordinary procedure returning a scripted
    ;; sequence of commands, which is how the suite drives this without a
    ;; terminal.
    ;;
    ;; A frame is described by its procedure's name and the values of its
    ;; parameters.  That is not a choice: registers carry no variable names by
    ;; the time the emitter is done with them, and regs[base .. base+arity] is
    ;; the one stretch of the register file whose meaning is recoverable without
    ;; debug info the emitter does not record.

    (define %debug-hook   #f)             ; procedure, or #f when not debugging
    (define %debug-mode   'off)           ; off | run | step | next | finish
    (define %debug-base   0)              ; register base next/finish resume at
    (define %debug-breaks '())            ; procedure names to stop on
    (define %debug-skip   '())            ; closures never to stop on

    ;; `next` and `finish` both mean "run until an event no deeper than here",
    ;; and depth is measured as the frame's *register base* rather than the
    ;; length of the frame list.  The emitter allocates a call's base above
    ;; everything live, so bases grow with depth — and unlike the list length
    ;; they keep growing across a re-entrant paal-call-value, whose frame list
    ;; is a fresh singleton.  Comparing lengths would make a `next` inside a
    ;; guard body stop at the first event in the nested loop.
    ;;
    ;; A tail call is reached with the caller's frame still current, so its base
    ;; compares equal and `next` stops there.  That is right: a tail call is the
    ;; last thing the frame does, so there is no "rest of this frame" left to
    ;; step over.

    (define (paal-debug-start! globals hook . opts)
      (set! %debug-hook hook)
      (set! %debug-mode (if (null? opts) 'step (car opts)))
      (set! %debug-base 0)
      (set! %debug-breaks '())
      ;; pkaappi-make-globals installs paal-compiled map, filter, apply, force
      ;; and the rest of the blob into the table before the user's program is
      ;; even compiled, and stepping into those is never what anyone means.
      ;; Skipping by closure identity rather than by name: the user's own
      ;; procedures are defined during the run, so they are not in the snapshot,
      ;; and an anonymous lambda handed to `map` still stops — it is a different
      ;; object from `map` itself.
      (set! %debug-skip
            (let loop ((a (vector-ref globals 0)) (acc '()))
              (cond ((null? a) acc)
                    ((closure? (cdr (car a))) (loop (cdr a) (cons (cdr (car a)) acc)))
                    (else (loop (cdr a) acc)))))
      #t)

    (define (paal-debug-stop!)
      (set! %debug-hook #f)
      (set! %debug-mode 'off)
      #t)

    (define (paal-debug-break! name)
      (if (memq name %debug-breaks)
          %debug-breaks
          (begin (set! %debug-breaks (cons name %debug-breaks))
                 %debug-breaks)))

    (define (paal-debug-unbreak! name)
      (set! %debug-breaks
            (let loop ((l %debug-breaks) (acc '()))
              (cond ((null? l) (reverse acc))
                    ((eq? (car l) name) (loop (cdr l) acc))
                    (else (loop (cdr l) (cons (car l) acc))))))
      %debug-breaks)

    (define (paal-debug-breaks) %debug-breaks)

    ;; A frame's parameters: regs[base .. base+arity-1], plus the rest list at
    ;; regs[base+arity] when the procedure is variadic.
    (define (debug-frame-args regs frame)
      (let* ((fn    (closure-function (frame-closure frame)))
             (base  (frame-base frame))
             (n     (+ (bytecode-function-arity fn)
                       (if (bytecode-function-variadic? fn) 1 0))))
        (let loop ((i (- n 1)) (acc '()))
          (if (< i 0) acc (loop (- i 1) (cons (vector-ref regs (+ base i)) acc))))))

    (define (debug-backtrace regs frames)
      (let loop ((fs frames) (acc '()))
        (if (null? fs)
            (reverse acc)
            (loop (cdr fs)
                  (cons (cons (bytecode-function-name
                                (closure-function (frame-closure (car fs))))
                              (debug-frame-args regs (car fs)))
                        acc)))))

    ;; Ask the hook what to do next.  `here` is the register base of the frame
    ;; that resumes once this event is done — the caller for a call, the frame
    ;; being returned into for a return — which is what next and finish measure
    ;; against.  An unrecognized answer continues, so a hook that returns
    ;; something odd cannot wedge the program.
    (define (debug-stop! kind name value frames here backtrace)
      (let ((cmd (%debug-hook kind name value (length frames) backtrace)))
        (set! %debug-base here)
        (set! %debug-mode
              (cond ((eq? cmd 'step)   'step)
                    ((eq? cmd 'next)   'next)
                    ((eq? cmd 'finish) 'finish)
                    (else              'run)))))

    ;; A breakpoint fires in every mode, `finish` included — the same as any
    ;; other debugger, where running to the end of a frame still stops at a
    ;; breakpoint hit on the way.
    (define (debug-call! regs frames frame callee args)
      (let ((name (bytecode-function-name (closure-function callee)))
            (base (frame-base frame)))
        (when (and (not (memq callee %debug-skip))
                   (or (memq name %debug-breaks)
                       (eq? %debug-mode 'step)
                       (and (eq? %debug-mode 'next) (<= base %debug-base))))
          (debug-stop! 'call name args frames base
                       (debug-backtrace regs frames)))))

    (define (debug-return! regs frames frame result)
      (let ((base (frame-base frame))
            (rest (cdr frames)))
        (when (and (not (memq (frame-closure frame) %debug-skip))
                   (or (eq? %debug-mode 'step)
                       (and (or (eq? %debug-mode 'next) (eq? %debug-mode 'finish))
                            (<= base %debug-base))))
          (debug-stop! 'return
                       (bytecode-function-name
                         (closure-function (frame-closure frame)))
                       result frames
                       (if (null? rest) 0 (frame-base (car rest)))
                       (debug-backtrace regs frames)))))

    (define (do-call! regs globals frames frame callee abs-base nargs base-off tail?)
      (cond
        ; Paal closure
        ((closure? callee)
         (when %profiling? (paal-profile-count! callee))
         (when %debug-hook
           (debug-call! regs frames frame callee (call-args regs abs-base nargs)))
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

        ; apply — (apply f a1 ... an lst).  Rewrites the call in place: the
        ; callee slot gets f, the spread arguments follow it, and do-call! runs
        ; again on the real callee.  Re-dispatching rather than using
        ; paal-call-value keeps `tail?` meaningful, so (apply f args) in tail
        ; position stays a tail call instead of growing the host stack.
        ;
        ; Writing above abs-base+nargs is safe: the emitter allocates a call's
        ; base as the next free register, so everything at or above it is unused
        ; by every live frame — and abs-base+1 is exactly where the callee's
        ; frame expects its arguments.
        ((eq? callee %paal-apply-marker)
         (if (< nargs 2)
             (error "paal-bc: apply needs a procedure and an argument list")
             (let* ((given  (call-args regs abs-base nargs))
                    (f      (car given))
                    (spread (flatten-apply-args (cdr given))))
               (if (not (list? spread))
                   (error "paal-bc: apply: last argument must be a proper list")
                   (let ((n (length spread)))
                     (if (>= (+ abs-base 1 n) REGS-SIZE)
                         (error "paal-bc: apply: argument list too long" n)
                         (begin
                           (vector-set! regs abs-base f)
                           (let loop ((i 1) (as spread))
                             (if (null? as)
                                 (do-call! regs globals frames frame
                                           f abs-base n base-off tail?)
                                 (begin
                                   (vector-set! regs (+ abs-base i) (car as))
                                   (loop (+ i 1) (cdr as))))))))))))

        ; guard — (%paal-guard-run body-thunk handler); see run-guard! above.
        ((eq? callee %paal-guard-run-marker)
         (deliver-result! regs globals frames frame abs-base
                          (run-guard! regs globals (+ abs-base nargs 1)
                                      (vector-ref regs (+ abs-base 1))
                                      (vector-ref regs (+ abs-base 2)))
                          tail?))

        ; call/cc — capture, then hand the continuation to the receiver by the
        ; same in-place rewrite apply uses: the callee slot gets the receiver,
        ; the continuation becomes its one argument, and do-call! runs again.
        ; That keeps (call/cc f) in tail position a real tail call, and lets f
        ; be a closure, HOST procedure, marker or another continuation with no
        ; special cases.  Capture happens before the rewrite: the two slots it
        ; overwrites are dead once the call is resolved, and a resumed frame
        ; reads only the delivery target.
        ((eq? callee %paal-callcc-marker)
         (if (not (= nargs 1))
             (error "paal-bc: call/cc expects one argument")
             (let ((f    (vector-ref regs (+ abs-base 1)))
                   (cont (capture-continuation regs globals frames frame
                                               abs-base nargs tail?)))
               (vector-set! regs abs-base f)
               (vector-set! regs (+ abs-base 1) cont)
               (do-call! regs globals frames frame f abs-base 1 base-off tail?))))

        ; spawn — (spawn thunk).  The thunk is called later, by the fiber
        ; scheduler, which is HOST code that cannot enter a paal closure.  The
        ; trampoline allocates a fresh register file per entry: the fiber body
        ; runs interleaved with the program that spawned it, and sharing one
        ; file would let either side overwrite the other's live registers at
        ; the first yield.  paal-call-value gives the entry its own loop
        ; identity, so a continuation captured inside the fiber cannot be
        ; replayed from outside it.  (Fiber switches interleaving *separate*
        ; paal episodes share the one '%paal-vm-loop cell — call/cc across an
        ; interleaving is untested territory; see docs/TODO.md.)
        ;
        ; In the paal-compiled copy of this VM the trampoline is itself a paal
        ; closure again, so the self-hosted path keeps the boundary type
        ; error — the same class of HOST-only limit as the debugger hooks.
        ((eq? callee %paal-spawn-marker)
         (if (not (= nargs 1))
             (error "paal-bc: spawn expects one thunk")
             (let ((f   (vector-ref regs (+ abs-base 1)))
                   (raw (globals-ref! globals '%paal-host-spawn)))
               (deliver-result! regs globals frames frame abs-base
                                (raw (lambda ()
                                       (let ((fregs (make-vector REGS-SIZE #f)))
                                         (paal-call-value fregs globals 0 f '()))))
                                tail?))))

        ; ffi-callback — (ffi-callback proc arg-types ret-type).  Same shape:
        ; only the procedure needs wrapping, the type lists pass through, and
        ; the fresh register file per invocation keeps a callback fired
        ; mid-run reentrant.
        ((eq? callee %paal-ffi-callback-marker)
         (if (< nargs 1)
             (error "paal-bc: ffi-callback expects a procedure first")
             (let* ((given (call-args regs abs-base nargs))
                    (f     (car given))
                    (raw   (globals-ref! globals '%paal-host-ffi-callback)))
               (deliver-result! regs globals frames frame abs-base
                                (apply raw
                                       (lambda args
                                         (let ((fregs (make-vector REGS-SIZE #f)))
                                           (paal-call-value fregs globals 0 f args)))
                                       (cdr given))
                                tail?))))

        ; Continuation invoke — reached by direct (k v) calls and through
        ; apply's re-dispatch, so (apply k args) needs nothing extra.  No
        ; debugger event fires: like a guard escape, the frame list changes
        ; wholesale rather than by one call or return.
        ((continuation? callee)
         (invoke-continuation! regs globals callee
                               (call-args regs abs-base nargs)
                               (+ abs-base nargs 1)))

        ; Host (Scheme) procedure
        ((procedure? callee)
         (let ((result (apply callee (call-args regs abs-base nargs))))
           (deliver-result! regs globals frames frame abs-base result tail?)))

        (else
         (error "paal-bc: not a callable" callee))))))
