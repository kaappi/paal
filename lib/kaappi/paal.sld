;;; (kaappi paal) — Paal Kaappi public API
;;;
;;; Provides both the tree-walking VM pipeline and the bytecode pipeline.
;;; Individual stages can also be imported directly via (kaappi paal <stage>).

(define-library (kaappi paal)
  (import (scheme base)
          (scheme file)
          (scheme write)
          (kaappi paal reader)
          (kaappi paal expander)
          (kaappi paal compiler)
          (kaappi paal vm)
          (kaappi paal emitter)
          (kaappi paal vm-bc)
          (kaappi paal serializer))
  (export
    ;; Reader
    paal-read paal-read-string paal-read-all paal-read-file
    ;; Expander
    paal-expand paal-expand-all paal-macros-reset!
    ;; Library path / module system
    paal-lib-path-add! paal-lib-paths-list paal-libraries-reset!
    ;; Compiler (analyzer)
    paal-analyze paal-analyze-all
    ;; Tree-walking VM
    paal-eval paal-eval-program paal-initial-env
    ;; Bytecode pipeline
    paal-emit-program paal-run-bc paal-make-globals
    ;; High-level pipeline (tree-walking)
    pkaappi-run-string pkaappi-run-file
    ;; High-level pipeline (bytecode)
    pkaappi-compile pkaappi-run-bc-string pkaappi-run-bc-file
    ;; Multi-file sequential loading
    pkaappi-make-globals pkaappi-load-file pkaappi-run-string-in
    ;; Self-hosted run, compile, and REPL
    pkaappi-self-run-file pkaappi-self-compile-to-file pkaappi-self-repl
    ;; Command-line injection for user programs
    pkaappi-set-command-line!
    ;; Serializer
    paal-write-bc paal-read-bc paal-write-bc-file paal-read-bc-file
    pkaappi-compile-to-file pkaappi-run-pbc-file
    ;; Compile-only checking
    pkaappi-check-file pkaappi-check-files)
  (begin

    ;; --- Tree-walking pipeline ---

    ;; Each of these runs a self-contained program against a fresh environment,
    ;; so it starts with a fresh macro table too — otherwise a define-syntax
    ;; here would still be installed for the next caller.  The `-in`/`load`
    ;; entry points below deliberately do not reset: those add to an existing
    ;; table, and macros should accumulate alongside the definitions.

    (define (pkaappi-run-string src)
      (paal-macros-reset!)
      (paal-eval-program
        (paal-analyze-all
          (paal-expand-all
            (paal-read-string src)))))

    (define (pkaappi-run-file path)
      (paal-macros-reset!)
      (paal-eval-program
        (paal-analyze-all
          (paal-expand-all
            (paal-read-file path)))))

    ;; --- Bytecode pipeline ---

    (define (pkaappi-compile-forms forms)
      (paal-emit-program (paal-analyze-all (paal-expand-all forms))))

    (define (pkaappi-compile src)
      (pkaappi-compile-forms (paal-read-string src)))

    ;; Globals first, then compile — pkaappi-make-globals resets the macro table,
    ;; and argument evaluation order is unspecified, so building it inline would
    ;; leave whether the reset precedes the user's expansion up to the host.
    (define (pkaappi-run-bc-string src)
      ;; Use pkaappi-make-globals so paal-compiled HOF (values, apply, map, etc.)
      ;; are available — HOST versions cannot call paal closures.
      (let ((g (pkaappi-make-globals)))
        (paal-run-bc (pkaappi-compile src) g)))

    (define (pkaappi-run-bc-file path)
      (let ((g (pkaappi-make-globals)))
        (paal-run-bc (pkaappi-compile-forms (paal-read-file path)) g)))

    ;; --- Multi-file sequential loading ---

    ;; Create a fresh globals table seeded with kaappi primitives.
    ;; The returned object can be passed to pkaappi-load-file repeatedly;
    ;; each call accumulates the loaded file's definitions in place.
    ;;
    ;; Optional: pass a list of strings as the first argument to pre-set
    ;; (command-line) for user programs.  Example: (pkaappi-make-globals '("f.scm" "a"))
    (define (pkaappi-make-globals . opts)
      ;; A fresh globals table starts a fresh program, so the macro table starts
      ;; fresh with it — macros get the same lifetime as the definitions they
      ;; sit alongside.  pkaappi-load-file and pkaappi-run-string-in add to an
      ;; existing table and so leave macros in place, which is what lets a
      ;; loaded file's macros stay visible and the REPL accumulate them.
      (paal-macros-reset!)
      (let* ((cmd-args  (if (null? opts) '() (car opts)))
             ; cmd-cell is a HOST mutable pair; (car cmd-cell) = current command-line list.
             ; command-line is a HOST lambda closing over cmd-cell — safe to call from
             ; any pipeline (HOST or self-hosted) without closure-tag mismatch.
             (cmd-cell    (list cmd-args))
             ; Holds the table being built, so eval/load/interaction-environment
             ; can reach it; filled in by set-car! once paal-make-globals returns.
             (g-cell      (list #f))
             ; Build a genuine HOST error object (so error-object? and friends
             ; recognize it) without raising past this point: HOST error raises it,
             ; and the guard hands the object back as an ordinary value.
             (make-host-error (lambda (msg irritants)
                                (guard (e (#t e)) (apply error msg irritants))))
             (base-alist (map (lambda (pair) (cons (car pair) (vector-ref (cdr pair) 0)))
                              (paal-initial-env)))
             (g (paal-make-globals
                  (append
                    `((pkaappi-make-globals       . ,pkaappi-make-globals)
                      (pkaappi-set-command-line!  . ,pkaappi-set-command-line!)
                      ; command-line HOST lambda closes over cmd-cell (safe across pipelines).
                      (command-line               . ,(lambda () (car cmd-cell)))
                      (%paal-cmd-cell             . ,cmd-cell)

                      ;; --- Exceptions (bytecode path) ---
                      ; %paal-vm-raise escapes to the nearest guard, wrapping the
                      ; value so any paal datum survives the trip through the HOST
                      ; condition system.  raise, raise-continuable, error and
                      ; with-exception-handler are paal definitions layered on it
                      ; below, so they can consult the handler stack — which no
                      ; HOST procedure could, since handlers are paal closures.
                      ; These three bindings are the pre-override fallbacks.
                      (%paal-vm-raise             . ,paal-vm-raise-escape!)
                      (%paal-make-error           . ,make-host-error)
                      (raise                      . ,paal-vm-raise-escape!)
                      (raise-continuable          . ,paal-vm-raise-escape!)
                      (error                      . ,(lambda (msg . irritants)
                                                       (paal-vm-raise-escape!
                                                         (make-host-error msg irritants))))
                      ; Marker handled by do-call!, which spreads the argument
                      ; list into real argument registers.  No arity ceiling, and
                      ; a tail-position (apply f args) stays a tail call.
                      (apply                      . ,%paal-apply-marker)
                      ; Target of the expander's `guard` desugaring.  Only a marker:
                      ; do-call! implements the operation, so whichever copy of the
                      ; VM is running supplies the catch and the closure callbacks
                      ; (see vm-bc.sld).
                      (%paal-guard-run            . ,%paal-guard-run-marker)
                      ;; --- (scheme eval) / (scheme load) / (scheme repl) ---
                      ;;
                      ;; eval re-enters the pipeline on a datum the program
                      ;; built at run time.  Each reads the table out of
                      ;; g-cell rather than closing over `g`, which is not
                      ;; bound until this alist has been evaluated; set-car!
                      ;; below fills it in.  Same trick as cmd-cell, and it
                      ;; keeps working across the HOST/self-hosted boundary
                      ;; because a pair is plain data.
                      ;;
                      ;; These use the HOST pipeline even under self-hosting.
                      ;; The loaded pipeline would be the purer choice, but
                      ;; reaching it means passing source *text* through
                      ;; pkaappi-run-string-in, and eval's argument is a datum
                      ;; -- writing it back out to re-read would lose every
                      ;; object in it that has no read syntax.
                      (%paal-globals-cell         . ,g-cell)
                      (eval                       . ,(lambda (expr . rest)
                                                       (paal-run-bc
                                                         (pkaappi-compile-forms (list expr))
                                                         (if (pair? rest)
                                                             (car rest)
                                                             (car g-cell)))))
                      ;; R7RS environment takes import specs; paal has one flat
                      ;; table per program, so any spec yields a fresh one with
                      ;; everything in it.  Honouring the specs would need the
                      ;; module system to build a table rather than splice.
                      (environment                . ,(lambda specs
                                                       (pkaappi-make-globals)))
                      (interaction-environment    . ,(lambda () (car g-cell)))
                      (load                       . ,(lambda (path . rest)
                                                       (paal-run-bc
                                                         (pkaappi-compile-forms
                                                           (paal-read-file path))
                                                         (if (pair? rest)
                                                             (car rest)
                                                             (car g-cell))))))
                    base-alist))))
        (set-car! g-cell g)
        ; Install the paal-native exception handler stack.
        ;
        ; with-exception-handler cannot be a HOST procedure here: the handler and
        ; thunk are paal closures, which HOST code cannot enter — it failed with
        ; "expected procedure, got #<vector>".  And raise-continuable cannot be
        ; built on the HOST condition system at all, because its handler must run
        ; *without unwinding* so its result can become the value of the raise.
        ;
        ; So handlers live on a paal-side stack and raise-continuable simply calls
        ; the top one in place.  The handler runs with the outer stack installed,
        ; per R7RS, so a raise inside a handler reaches the next handler out
        ; rather than itself.
        ;
        ; raise consults the same stack, then escapes: R7RS says a handler that
        ; returns from a non-continuable raise triggers a secondary exception, and
        ; escaping propagates the original outward to the next handler or guard.
        ; With an empty stack both fall straight through to %paal-vm-raise, which
        ; is what `guard` catches — so guard keeps working unchanged.
        (paal-run-bc
          (pkaappi-compile
            "(define %paal-handlers '())
             ; No guard around the thunk, deliberately.  A guard pushes its own
             ; escaping handler, which would sit on top of this one and swallow
             ; the very conditions this handler is installed for.  Cleanup on a
             ; non-local exit is not needed either: the escape propagates to some
             ; enclosing guard, whose run-guard! restores the stack to what it
             ; captured before this push.
             (define (with-exception-handler handler thunk)
               (let ((saved %paal-handlers))
                 (set! %paal-handlers (cons handler saved))
                 (let ((result (thunk)))
                   (set! %paal-handlers saved)
                   result)))
             (define (raise-continuable obj)
               (if (null? %paal-handlers)
                   (%paal-vm-raise obj)
                   (let ((h (car %paal-handlers))
                         (saved %paal-handlers))
                     (set! %paal-handlers (cdr saved))
                     (let ((result (h obj)))
                       (set! %paal-handlers saved)
                       result))))
             (define (raise obj)
               (if (null? %paal-handlers)
                   (%paal-vm-raise obj)
                   (let ((h (car %paal-handlers))
                         (saved %paal-handlers))
                     (set! %paal-handlers (cdr saved))
                     (h obj)
                     (set! %paal-handlers saved)
                     ; R7RS: returning from a handler invoked by a
                     ; non-continuable raise triggers a secondary exception.
                     ; Same message HOST kaappi uses, so both pipelines agree.
                     (%paal-vm-raise (%paal-make-error \"handler returned\" '())))))
             (define (error msg . irritants)
               (raise (%paal-make-error msg irritants)))")
          g)

        ; Install paal-native promise system (separate from HOST tree-walking path).
        ; %paal-delay-impl creates a lazy promise vector; force/promise?/make-promise
        ; use the same paal-allocated tag.  Bytecode VM paal closures work here.
        (paal-run-bc
          (pkaappi-compile
            "(define %paal-promise-tag (list 'paal-promise-tag))
             (define (%paal-delay-impl thunk)
               (let ((v (make-vector 3)))
                 (vector-set! v 0 %paal-promise-tag)
                 (vector-set! v 1 #f)
                 (vector-set! v 2 thunk)
                 v))
             (define (promise? x)
               (and (vector? x) (= (vector-length x) 3)
                    (eq? (vector-ref x 0) %paal-promise-tag)))
             (define (make-promise x)
               (if (promise? x)
                   x
                   (let ((v (make-vector 3)))
                     (vector-set! v 0 %paal-promise-tag)
                     (vector-set! v 1 #t)
                     (vector-set! v 2 x)
                     v)))
             (define (force p)
               (if (not (promise? p))
                   p
                   (if (vector-ref p 1)
                       (vector-ref p 2)
                       (let ((r ((vector-ref p 2))))
                         (vector-set! p 1 #t)
                         (vector-set! p 2 r)
                         r))))")
          g)

        ; Install paal-native HOFs and multiple-values support,
        ; replacing HOST stubs that cannot call paal closures.
        ;
        ; apply is not here — it is a VM marker (see vm-bc.sld), since no paal
        ; procedure can issue a call whose argument count is only known at run
        ; time.  It used to be a hand-unrolled cond, capped at 16 arguments.
        ; values/call-with-values: MVR-tagged encoding; no value-count limit
        ; since call-with-values hands the values to apply.
        ; map, for-each, filter: 1-or-2-list version covering paal's own usage.
        ; vector-map, vector-for-each, string-map, string-for-each: 1-vector/string.
        (paal-run-bc
          (pkaappi-compile
            "(define %paal-mvr-tag (list 'paal-mvr))
             (define (values . vals) (cons %paal-mvr-tag vals))
             ; The consumer's arity is only known at run time, which is exactly
             ; what apply now handles — so no unrolled dispatch and no ceiling.
             ; Both arms stay in tail position, so apply re-dispatches as a tail
             ; call and a producer/consumer loop does not grow the host stack.
             (define (call-with-values producer consumer)
               (let ((r (producer)))
                 (if (and (pair? r) (eq? (car r) %paal-mvr-tag))
                     (apply consumer (cdr r))
                     (consumer r))))
             ; The three R7RS procedures that return two values need paal
             ; definitions here.  The HOST ones inherited from paal-initial-env
             ; return real kaappi multiple values, which arrive in the VM's
             ; single-value context as one opaque #<values> object — so
             ; call-with-values saw a non-MVR value and passed that object
             ; through as a single argument, and (let-values (((q r) (floor/ 7 2)))
             ; ...) bound both q and r to it.  Rebuilt on the single-value
             ; quotient/remainder primitives and paal's own `values`.
             (define (floor/ n d)
               (values (floor-quotient n d) (floor-remainder n d)))
             (define (truncate/ n d)
               (values (truncate-quotient n d) (truncate-remainder n d)))
             ; Newton's method on integers: from x = n, x' = (x + n/x)/2 descends
             ; to floor(sqrt n) and then stops falling.  Avoids going through a
             ; flonum sqrt, which would lose exactness on large inputs.
             (define (exact-integer-sqrt n)
               (if (< n 0)
                   (error \"exact-integer-sqrt: negative argument\" n)
                   (if (= n 0)
                       (values 0 0)
                       (let loop ((x n))
                         (let ((y (quotient (+ x (quotient n x)) 2)))
                           (if (< y x)
                               (loop y)
                               (values x (- n (* x x)))))))))
             (define (map f lst . rest)
               (if (null? lst)
                   '()
                   (if (null? rest)
                       (cons (f (car lst)) (map f (cdr lst)))
                       (cons (f (car lst) (car (car rest)))
                             (map f (cdr lst) (cdr (car rest)))))))
             (define (for-each f lst . rest)
               (if (null? lst)
                   (if #f #f)
                   (begin
                     (if (null? rest)
                         (f (car lst))
                         (f (car lst) (car (car rest))))
                     (if (null? rest)
                         (for-each f (cdr lst))
                         (for-each f (cdr lst) (cdr (car rest)))))))
             (define (filter pred lst)
               (if (null? lst)
                   '()
                   (if (pred (car lst))
                       (cons (car lst) (filter pred (cdr lst)))
                       (filter pred (cdr lst)))))
             (define (vector-map f v)
               (let* ((n (vector-length v))
                      (result (make-vector n)))
                 (let loop ((i 0))
                   (if (= i n)
                       result
                       (begin
                         (vector-set! result i (f (vector-ref v i)))
                         (loop (+ i 1)))))))
             (define (vector-for-each f v)
               (let ((n (vector-length v)))
                 (let loop ((i 0))
                   (if (< i n)
                       (begin (f (vector-ref v i)) (loop (+ i 1)))
                       (if #f #f)))))
             (define (string-map f s)
               (list->string (map f (string->list s))))
             (define (string-for-each f s)
               (for-each f (string->list s)))")
          g)

        ; Install paal-native parameter objects (overriding the HOST make-parameter
        ; inherited from paal-initial-env).  A parameter is a paal closure over a
        ; 2-slot cell #(value converter); calling it with no arguments reads the
        ; value, and calling it with %paal-param-key — a key only this code knows —
        ; hands back the cell so %paal-parameterize can rebind it.  That avoids a
        ; registry mapping parameters to cells, which would leak.
        ;
        ; The whole thing is paal source rather than a VM marker because nothing
        ; here needs the VM: cells are ordinary vectors and the wind stack is an
        ; ordinary list.  A raise is the only non-local exit from the extent —
        ; paal has no continuations for paal closures — and the enclosing guard
        ; unwinds it, so parameterize itself needs no cleanup handler.
        ;
        ; %paal-winds is that stack, and the reason `guard` can honour R7RS
        ; 4.2.7 without capturing a continuation.  See the long note beside its
        ; HOST twin in lib/kaappi/paal/vm.sld.
        (paal-run-bc
          (pkaappi-compile
            "(define %paal-param-key (list 'paal-param-key))
             (define %paal-winds '())
             (define (make-parameter init . rest)
               (let* ((conv (if (null? rest) (lambda (x) x) (car rest)))
                      (cell (vector (conv init) conv)))
                 (lambda args
                   (if (null? args)
                       (vector-ref cell 0)
                       (if (eq? (car args) %paal-param-key)
                           cell
                           (error \"parameter: unexpected argument\"))))))
             (define (%paal-param-cells params)
               (if (null? params)
                   '()
                   (cons ((car params) %paal-param-key)
                         (%paal-param-cells (cdr params)))))
             (define (%paal-param-read cells)
               (if (null? cells)
                   '()
                   (cons (vector-ref (car cells) 0) (%paal-param-read (cdr cells)))))
             ; Each converter runs once, when the extent is entered — winding
             ; back in later reuses the converted values rather than converting
             ; again, so %paal-param-write! is a plain write in both directions.
             (define (%paal-param-convert cells vals)
               (if (null? cells)
                   '()
                   (cons ((vector-ref (car cells) 1) (car vals))
                         (%paal-param-convert (cdr cells) (cdr vals)))))
             (define (%paal-param-write! cells vals)
               (if (null? cells)
                   (if #f #f)
                   (begin
                     (vector-set! (car cells) 0 (car vals))
                     (%paal-param-write! (cdr cells) (cdr vals)))))
             ; Two frame kinds share the stack:
             ;   #(%paal-param-frame cells news olds)   parameterize
             ;   #(%paal-wind-frame before after)       dynamic-wind
             ; Interned symbol tags, so either copy of the library recognizes
             ; the other's frames.
             (define %paal-param-frame '%paal-param-frame)
             (define %paal-wind-frame  '%paal-wind-frame)
             (define (%paal-wind-out! from to)
               (if (eq? from to)
                   #t
                   (let ((f (car from)))
                     (if (eq? (vector-ref f 0) %paal-param-frame)
                         (%paal-param-write! (vector-ref f 1) (vector-ref f 3))
                         ((vector-ref f 2)))
                     (%paal-wind-out! (cdr from) to))))
             (define (%paal-wind-in! from to)
               (if (eq? from to)
                   #t
                   (begin
                     (%paal-wind-in! (cdr from) to)
                     (let ((f (car from)))
                       (if (eq? (vector-ref f 0) %paal-param-frame)
                           (%paal-param-write! (vector-ref f 1) (vector-ref f 2))
                           ((vector-ref f 1)))))))
             ; HOST dynamic-wind cannot enter a paal closure, so this has to be
             ; paal source; and its winders have to live on the same stack a
             ; guard walks, or the two views of the dynamic environment drift.
             (define (dynamic-wind before thunk after)
               (before)
               (let ((saved %paal-winds))
                 (set! %paal-winds
                       (cons (vector %paal-wind-frame before after) saved))
                 (let ((result (thunk)))
                   ; Pop before running after, so the after thunk runs outside
                   ; the extent it is closing.
                   (set! %paal-winds saved)
                   (after)
                   result)))
             ; No cleanup handler around the thunk: on a raise the frame stays
             ; on %paal-winds and the values stay installed, which is what makes
             ; the raise point still reconstructable when the guard looks.
             (define (%paal-parameterize params vals thunk)
               (let* ((cells (%paal-param-cells params))
                      (olds  (%paal-param-read cells))
                      (news  (%paal-param-convert cells vals))
                      (saved %paal-winds))
                 (set! %paal-winds
                       (cons (vector %paal-param-frame cells news olds) saved))
                 (%paal-param-write! cells news)
                 (let ((result (thunk)))
                   (%paal-param-write! cells olds)
                   (set! %paal-winds saved)
                   result)))
             ; Everything a guard does once its body has raised.  run-guard!
             ; calls this with the wind stack as it stood when the guard was
             ; entered; %paal-winds still holds the raise point's, because
             ; unwinding the host stack does not touch it.
             (define (%paal-guard-catch condition clauses w-guard)
               (let ((w-raise %paal-winds))
                 (%paal-wind-out! w-raise w-guard)
                 (set! %paal-winds w-guard)
                 (let ((result (clauses condition)))
                   (if (eq? result %paal-guard-no-match)
                       (begin
                         ; Back to the raise point to re-raise there, per R7RS.
                         ; If an outer handler returns, the raise-continuable
                         ; that got us here returns its value and the extent
                         ; carries on, so wind out again before handing it back.
                         (%paal-wind-in! w-raise w-guard)
                         (set! %paal-winds w-raise)
                         (let ((v (raise-continuable condition)))
                           (%paal-wind-out! w-raise w-guard)
                           (set! %paal-winds w-guard)
                           v))
                       result))))")
          g)
        g))

    ;; Inject a command-line list into a globals table created by pkaappi-make-globals.
    ;; The user program's (command-line) will return this list.
    ;; args must be a proper list of strings: (path arg1 arg2 ...).
    ;;
    ;; Implementation: set-car! the cmd-cell stored in globals as %paal-cmd-cell.
    ;; The command-line HOST lambda closes over that cell, so changes are reflected
    ;; immediately. Using set-car! avoids paal-compiled code and the closure-tag issue.
    (define (pkaappi-set-command-line! globals args)
      (set-car! (pkaappi-run-string-in globals "%paal-cmd-cell") args))

    ;; Compile a .sld or .scm file and run it into an existing globals table.
    ;; New names defined by the file are added to globals via define-global ops.
    ;; Returns globals for easy chaining: (pkaappi-load-file b (pkaappi-load-file a g))
    (define (pkaappi-load-file path globals)
      (paal-run-bc (pkaappi-compile-forms (paal-read-file path)) globals)
      globals)

    ;; Compile and evaluate a source string in an existing globals table.
    ;; get-global ops resolve against all previously loaded definitions.
    (define (pkaappi-run-string-in globals src)
      (paal-run-bc (pkaappi-compile src) globals))

    ;; --- Serializer high-level API ---

    (define (pkaappi-compile-to-file input output)
      (let ((fn (pkaappi-compile-forms (paal-read-file input))))
        (paal-write-bc-file fn output)))

    ;; --- check: compile without running ---

    ;; Everything the compiler can tell you about a file without executing it:
    ;; read, expand, analyze, emit.  Emitting rather than stopping at the IR is
    ;; deliberate — register allocation and upvalue resolution happen there, so
    ;; skipping it would miss the errors a user is least likely to have thought
    ;; about.  Nothing runs, so a file with side effects is safe to check.
    ;;
    ;; Returns #t if the file compiled, #f otherwise, printing one diagnostic
    ;; line per failure.  A fresh macro table per file, so a define-syntax in
    ;; one checked file cannot silently satisfy a reference in the next.
    (define (pkaappi-check-file path)
      (guard (e (#t (display "error: " (current-error-port))
                    (display path (current-error-port))
                    (display ": " (current-error-port))
                    (%display-condition e (current-error-port))
                    (newline (current-error-port))
                    #f))
        (paal-macros-reset!)
        (pkaappi-compile-forms (paal-read-file path))
        #t))

    ;; Conditions reaching here are HOST error objects most of the time, but a
    ;; paal `raise` can deliver any value at all, so fall back to writing it.
    (define (%display-condition e port)
      (if (error-object? e)
          (begin
            (display (error-object-message e) port)
            (for-each (lambda (x) (display " " port) (write x port))
                      (error-object-irritants e)))
          (write e port)))

    ;; #t only if every file compiled.  Checks them all rather than stopping at
    ;; the first, so one run reports every broken file in a tree.
    (define (pkaappi-check-files paths)
      (let loop ((ps paths) (ok #t))
        (if (null? ps)
            ok
            (let ((this (pkaappi-check-file (car ps))))
              (loop (cdr ps) (and ok this))))))

    ;; Uses pkaappi-make-globals rather than a bare paal-initial-env blob: a .pbc
    ;; that calls map, for-each, apply or force needs the paal-compiled versions,
    ;; since the HOST ones cannot invoke a paal closure.  With the raw initial env
    ;; `paal file.pbc` failed with "type error in 'map': expected procedure".
    (define (pkaappi-run-pbc-file path)
      (paal-run-bc (paal-read-bc-file path) (pkaappi-make-globals)))

    ;; --- Self-hosted run ---

    ; Library file load order for paal's own pipeline.
    (define %paal-lib-files
      '("lib/kaappi/paal/ir.sld"
        "lib/kaappi/paal/bytecode.sld"
        "lib/kaappi/paal/reader.sld"
        "lib/kaappi/paal/expander.sld"
        "lib/kaappi/paal/compiler.sld"
        "lib/kaappi/paal/frame.sld"
        "lib/kaappi/paal/emitter.sld"
        "lib/kaappi/paal/vm-bc.sld"))

    ; Pre-compiled .pbc cache paths (produced by `make pbc-pipeline`).
    ; One .pbc per library file; cache/paal-serializer.pbc only for compile.
    (define %paal-cache-files
      '("cache/paal-ir.pbc"
        "cache/paal-bytecode.pbc"
        "cache/paal-reader.pbc"
        "cache/paal-expander.pbc"
        "cache/paal-compiler.pbc"
        "cache/paal-frame.pbc"
        "cache/paal-emitter.pbc"
        "cache/paal-vm-bc.pbc"))

    (define %paal-serializer-cache "cache/paal-serializer.pbc")

    ; True only when all 8 pipeline .pbc files exist (partial cache is unsafe).
    (define (paal-cache-complete?)
      (let loop ((files %paal-cache-files))
        (or (null? files)
            (and (file-exists? (car files))
                 (loop (cdr files))))))

    ; Load all 8 pipeline .pbc files into globals g.
    ; Reads each .pbc (fast: parse + reconstruct) then runs it into g.
    (define (pkaappi-load-cached-pipeline g)
      (for-each (lambda (pbc) (paal-run-bc (paal-read-bc-file pbc) g))
                %paal-cache-files))

    ; Serialize a Scheme value to a string using write.
    (define (paal-write-to-string val)
      (let ((p (open-output-string)))
        (write val p)
        (get-output-string p)))

    ; Load paal's pipeline into a fresh globals, then compile and run the user's
    ; file through the loaded pipeline (reader, expander, emitter, VM).
    ; Priority: cache (.pbc) > .sld sources > HOST bytecode fallback.
    ; user-args: extra strings after the filename, set as (command-line) inside the program.
    (define (pkaappi-self-run-file path . user-args)
      (let* ((cmd-list (cons path user-args))
             ; Serialize cmd-list to embed in the dispatch string passed to inner pkaappi-make-globals
             (cmd-str  (paal-write-to-string cmd-list)))
        (cond
          ((paal-cache-complete?)
           (let ((g (pkaappi-make-globals)))
             (pkaappi-load-cached-pipeline g)
             (pkaappi-run-string-in g
               (string-append
                 "(paal-run-bc"
                 "  (paal-emit-program"
                 "    (paal-analyze-all"
                 "      (paal-expand-all"
                 "        (paal-read-file \"" path "\"))))"
                 "  (pkaappi-make-globals (quote " cmd-str ")))"))))
          ((file-exists? "lib/kaappi/paal/ir.sld")
           (let ((g (pkaappi-make-globals)))
             (for-each (lambda (p) (pkaappi-load-file p g)) %paal-lib-files)
             (pkaappi-run-string-in g
               (string-append
                 "(paal-run-bc"
                 "  (paal-emit-program"
                 "    (paal-analyze-all"
                 "      (paal-expand-all"
                 "        (paal-read-file \"" path "\"))))"
                 "  (pkaappi-make-globals (quote " cmd-str ")))"))))
          (else
           ; Fallback: run through HOST bytecode pipeline (no self-hosting)
           ; command-line not forwarded in this path (bootstrap only).
           (pkaappi-run-bc-file path)))))

    ; Load paal's pipeline + serializer into a fresh globals, compile the input
    ; file through the loaded pipeline, and write bytecode to output.
    ; Priority: cache (.pbc) > .sld sources > HOST bytecode fallback.
    ; The serializer cache is loaded only if it already exists — when building
    ; the serializer cache itself it won't exist yet, so fall back to .sld.
    (define (pkaappi-self-compile-to-file input output)
      (cond
        ((paal-cache-complete?)
         (let ((g (pkaappi-make-globals)))
           (pkaappi-load-cached-pipeline g)
           (if (file-exists? %paal-serializer-cache)
               (paal-run-bc (paal-read-bc-file %paal-serializer-cache) g)
               (pkaappi-load-file "lib/kaappi/paal/serializer.sld" g))
           (pkaappi-run-string-in g
             (string-append
               "(paal-write-bc-file"
               "  (paal-emit-program"
               "    (paal-analyze-all"
               "      (paal-expand-all"
               "        (paal-read-file \"" input "\"))))"
               "  \"" output "\")"))))
        ((file-exists? "lib/kaappi/paal/ir.sld")
         (let ((g (pkaappi-make-globals)))
           (for-each (lambda (p) (pkaappi-load-file p g)) %paal-lib-files)
           (pkaappi-load-file "lib/kaappi/paal/serializer.sld" g)
           (pkaappi-run-string-in g
             (string-append
               "(paal-write-bc-file"
               "  (paal-emit-program"
               "    (paal-analyze-all"
               "      (paal-expand-all"
               "        (paal-read-file \"" input "\"))))"
               "  \"" output "\")"))))
        (else
         (pkaappi-compile-to-file input output))))

    ;; The loaded pipeline is a second copy of the expander with its own
    ;; %paal-lib-paths, so --lib-path has to be replayed into it.  Without this
    ;; the self-hosted path searched "." alone and every import silently
    ;; resolved to nothing.
    ; --- Self-hosted REPL ---

    ; Internal: run a REPL loop inside an already-loaded globals g.
    ; The loop persists user globals across expressions so define accumulates.
    ; Internal: run a REPL loop with pipeline already loaded in g.
    ; The loop runs in HOST Scheme so we can use HOST guard for error handling.
    ; Each iteration reads one datum via the loaded paal-read, stashes it in g
    ; as %repl-last-input, then compiles and runs it through the loaded pipeline.
    (define (%run-repl g)
      ; Create persistent user globals inside g — defines accumulate here.
      (pkaappi-run-string-in g "(define %repl-user-globals (pkaappi-make-globals))")
      (let loop ()
        (display "paal> ")
        (flush-output-port (current-output-port))
        ; Read one datum using the loaded reader; store it in g.
        (pkaappi-run-string-in g
          "(define %repl-last-input (paal-read (current-input-port)))")
        (let ((is-eof (pkaappi-run-string-in g "(eof-object? %repl-last-input)")))
          (unless is-eof
            (guard (exn (#t
                         (display "error: ")
                         (display (error-object-message exn))
                         (for-each (lambda (x) (display " ") (write x))
                                   (error-object-irritants exn))
                         (newline)))
              (let* ((result
                      (pkaappi-run-string-in g
                        "(paal-run-bc
                           (paal-emit-program
                             (paal-analyze-all
                               (paal-expand-all (list %repl-last-input))))
                           %repl-user-globals)"))
                     (is-def
                      (pkaappi-run-string-in g
                        "(and (pair? %repl-last-input)
                              (memq (car %repl-last-input)
                                    '(define define-values define-record-type
                                      define-library import)))")))
                (unless is-def
                  (write result)
                  (newline))))
            (loop)))))

    ; Load paal's pipeline and start an interactive REPL.
    ; Priority: cache (.pbc) > .sld sources > error (no pipeline available).
    (define (pkaappi-self-repl)
      (cond
        ((paal-cache-complete?)
         (let ((g (pkaappi-make-globals)))
           (pkaappi-load-cached-pipeline g)
           (%run-repl g)))
        ((file-exists? "lib/kaappi/paal/ir.sld")
         (let ((g (pkaappi-make-globals)))
           (for-each (lambda (p) (pkaappi-load-file p g)) %paal-lib-files)
           (%run-repl g)))
        (else
         (display "error: repl requires cache (make pbc-pipeline) or paal sources\n"))))))
