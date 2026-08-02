;;; (kaappi paal) — Paal Kaappi public API
;;;
;;; Provides both the tree-walking VM pipeline and the bytecode pipeline.
;;; Individual stages can also be imported directly via (kaappi paal <stage>).

(define-library (kaappi paal)
  (import (scheme base)
          (scheme file)
          (scheme write)
          (scheme process-context)
          (srfi 170)
          (kaappi ffi)
          (kaappi fibers)
          (kaappi paal bytecode)
          (kaappi paal frame)
          (kaappi paal embedded)
          (kaappi paal reader)
          (kaappi paal expander)
          (kaappi paal compiler)
          (kaappi paal vm)
          (kaappi paal emitter)
          (kaappi paal vm-bc)
          (kaappi paal serializer)
          (kaappi paal formatter)
          (kaappi paal disassembler))
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
    pkaappi-check-file pkaappi-check-files
    ;; Opt-in bytecode cache for user programs
    pkaappi-run-file-cached pkaappi-cache-path
    ;; CLI queries: capability report, cache inspection
    paal-version paal-features paal-features-text paal-features-json
    paal-embedded-names
    paal-pipeline-cache-status pkaappi-cache-entries pkaappi-cache-clear!
    ;; Formatter
    paal-format-string paal-format-file paal-format-file!
    paal-format-check-file
    ;; Disassembler
    paal-disassemble
    ;; Profiling
    paal-profile-start! paal-profile-report
    paal-coverage-start! paal-coverage-report
    pkaappi-run-bc-string-covered
    ;; Stepping debugger
    paal-debug-start! paal-debug-stop!
    paal-debug-break! paal-debug-unbreak! paal-debug-breaks
    pkaappi-debug-string pkaappi-debug-file)
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

    ;; Coverage needs the globals table both to snapshot and to report on, so
    ;; it cannot go through pkaappi-run-bc-string, which builds one internally.
    (define (pkaappi-run-bc-string-covered src)
      (let ((g (pkaappi-make-globals)))
        (paal-coverage-start! g)
        (paal-run-bc (pkaappi-compile src) g)
        (paal-coverage-report g)))

    (define (pkaappi-run-bc-file path)
      (let ((g (pkaappi-make-globals)))
        (paal-run-bc (pkaappi-compile-forms (paal-read-file path)) g)))

    ;; --- Stepping debugger ---
    ;;
    ;; The VM half is in (kaappi paal vm-bc): it raises call and return events
    ;; and asks a hook what to do next.  This half supplies the two hooks worth
    ;; having — one scripted, for the test suite, and one that talks to a
    ;; terminal, for `paal debug`.
    ;;
    ;; Both run the HOST pipeline, for the same reason `--profile` does: the
    ;; self-hosted path executes the program through the paal-compiled copy of
    ;; the VM, which has its own %debug-hook that setting this one does not
    ;; reach.

    ;; Run `src` under `hook`.  With breakpoint names given the session starts
    ;; running and first stops at one of them; with none it stops at the first
    ;; call, which is where an interactive session sets its breakpoints.
    ;;
    ;; The debugger is turned off again even if the program raises — otherwise
    ;; a hook installed by a failed run would still be armed for the next one.
    (define (pkaappi-debug-string src hook . opts)
      (let ((g      (pkaappi-make-globals))
            (breaks (if (null? opts) '() (car opts))))
        (paal-debug-start! g hook (if (null? breaks) 'step 'run))
        (for-each paal-debug-break! breaks)
        (guard (e (#t (paal-debug-stop!) (raise e)))
          (let ((result (paal-run-bc (pkaappi-compile src) g)))
            (paal-debug-stop!)
            result))))

    (define (pkaappi-debug-file path . user-args)
      (let ((g (pkaappi-make-globals (cons path user-args))))
        (paal-debug-start! g (%debug-console-hook g))
        (display "paal debugger: h for help, c to run, q to quit\n")
        (guard (e (#t (paal-debug-stop!) (raise e)))
          (let ((result (paal-run-bc
                          (pkaappi-compile-forms (paal-read-file path)) g)))
            (paal-debug-stop!)
            result))))

    ;; A procedure printed in full is its entire bytecode function — pages of
    ;; vectors.  Anything a debugger displays goes through here first.  Only the
    ;; value itself is abbreviated, not procedures buried inside a list; that is
    ;; rare enough not to justify walking every structure a program prints.
    (define (%debug-write v)
      (cond
        ((closure? v)
         (display "#<procedure ")
         (display (%debug-label (bytecode-function-name (closure-function v))))
         (display ">"))
        ((bytecode-function? v)
         (display "#<code ")
         (display (%debug-label (bytecode-function-name v)))
         (display ">"))
        (else (write v))))

    (define (%debug-label name) (if name name "<anonymous>"))

    ;; (name arg ...) shown as the call it was.
    (define (%debug-form name args)
      (display "(")
      (display (%debug-label name))
      (for-each (lambda (a) (display " ") (%debug-write a)) args)
      (display ")"))

    (define (%debug-announce kind name value depth)
      (if (eq? kind 'call)
          (begin (display "call   ") (%debug-form name value))
          (begin (display "return ")
                 (display (%debug-label name))
                 (display " -> ")
                 (%debug-write value)))
      (display "   [depth ") (display depth) (display "]")
      (newline))

    (define (%debug-backtrace-show bt)
      (let loop ((fs bt) (i 0))
        (unless (null? fs)
          (display "#") (display i) (display "  ")
          (%debug-form (car (car fs)) (cdr (car fs)))
          (newline)
          (loop (cdr fs) (+ i 1)))))

    (define (%debug-breaks-show)
      (let ((bs (paal-debug-breaks)))
        (if (null? bs)
            (display "no breakpoints\n")
            (begin
              (display "breakpoints:")
              (for-each (lambda (b) (display " ") (display b)) bs)
              (newline)))))

    (define (%debug-help)
      (display "  s, step      run to the next call or return\n")
      (display "  n, next      run to the next event in this frame or a caller\n")
      (display "  f, finish    run until this frame returns\n")
      (display "  c, continue  run to the next breakpoint\n")
      (display "  b [name]     set a breakpoint on a procedure, or list them\n")
      (display "  d <name>     delete a breakpoint\n")
      (display "  bt           backtrace: every live frame and its arguments\n")
      (display "  p <name>     print a top-level binding\n")
      (display "  q, quit      stop the program\n")
      (display "  h, help      this list\n")
      (display "  <enter>      repeat step\n"))

    ;; Whitespace-separated words.  A one-line splitter rather than `read`,
    ;; because a command is not a datum: `b foo` is two words, and `bt` must not
    ;; read as the symbol bt followed by whatever the next line happens to hold.
    (define (%debug-tokens line)
      (let ((n (string-length line)))
        (let loop ((i 0) (start 0) (acc '()))
          (define (flush) (if (> i start) (cons (substring line start i) acc) acc))
          (cond
            ((= i n) (reverse (flush)))
            ((or (char=? (string-ref line i) #\space)
                 (char=? (string-ref line i) #\tab))
             (loop (+ i 1) (+ i 1) (flush)))
            (else (loop (+ i 1) start acc))))))

    ;; Closes over the globals table so `p` can look a binding up.  The hook
    ;; protocol deliberately hands over data only, so the table has to come from
    ;; here — the one place that has both it and the terminal.
    (define (%debug-console-hook g)
      (lambda (kind name value depth backtrace)
        (%debug-announce kind name value depth)
        (let prompt ()
          (display "(paal) ")
          (let ((line (read-line)))
            (if (eof-object? line)
                ;; No terminal left to ask.  Continuing runs the program to
                ;; completion, which is the only answer that terminates.
                'continue
                (let ((ts (%debug-tokens line)))
                  (if (null? ts)
                      'step
                      (let ((cmd (car ts)) (rest (cdr ts)))
                        (cond
                          ((or (string=? cmd "s") (string=? cmd "step"))     'step)
                          ((or (string=? cmd "n") (string=? cmd "next"))     'next)
                          ((or (string=? cmd "f") (string=? cmd "finish"))   'finish)
                          ((or (string=? cmd "c") (string=? cmd "continue")) 'continue)
                          ((or (string=? cmd "q") (string=? cmd "quit"))     (exit 0))
                          ((or (string=? cmd "bt") (string=? cmd "where"))
                           (%debug-backtrace-show backtrace) (prompt))
                          ((string=? cmd "b")
                           (unless (null? rest)
                             (paal-debug-break! (string->symbol (car rest))))
                           (%debug-breaks-show) (prompt))
                          ((string=? cmd "d")
                           (if (null? rest)
                               (display "usage: d <name>\n")
                               (paal-debug-unbreak! (string->symbol (car rest))))
                           (%debug-breaks-show) (prompt))
                          ((string=? cmd "p")
                           (if (null? rest)
                               (display "usage: p <name>\n")
                               (let ((hit (assq (string->symbol (car rest))
                                                (vector-ref g 0))))
                                 (if hit
                                     (begin (%debug-write (cdr hit)) (newline))
                                     (display "unbound\n"))))
                           (prompt))
                          ((or (string=? cmd "h") (string=? cmd "help")
                               (string=? cmd "?"))
                           (%debug-help) (prompt))
                          (else
                           (display "unknown command: ") (display cmd)
                           (display "  (h for help)") (newline)
                           (prompt)))))))))))

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
      (apply %make-globals-table opts))

    ;; The same table without the macro reset.
    ;;
    ;; `environment` needs this and `pkaappi-make-globals` will not do: an R7RS
    ;; environment is created *inside* a running program, and there is one macro
    ;; table for the whole expander, so resetting it there destroys the macros of
    ;; the program doing the nesting.  Every `define-syntax` before an
    ;; `(environment …)` call became an unbound variable after it.
    ;;
    ;; It stays hidden under whole-program compilation, where expansion finishes
    ;; before anything runs, and under the cached REPL, where the reset lands on
    ;; the HOST expander while the REPL expands through the loaded one.  It is
    ;; plainly visible anywhere forms are expanded and run one at a time — which
    ;; is how the R7RS conformance harness drives the suite, and how it was
    ;; found: `(environment '(scheme base))` in §6.12 took out `(chibi test)`'s
    ;; `test` macro and darkened the remaining 292 forms of the suite.
    ;; Table construction runs five blobs through the VM, and since the port
    ;; blob those make paal-level calls at load time (make-parameter, its
    ;; converter).  They are setup, not the program: mask the profiler for the
    ;; duration, or `--profile` and a mid-run (environment ...) would report
    ;; them.  The eval/environment entries below call this same name, so
    ;; nested tables mask themselves.
    (define (%make-globals-table . opts)
      (paal-profile-masked (lambda () (apply %make-globals-table-raw opts))))

    (define (%make-globals-table-raw . opts)
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
             (base-alist (%without-host-only
                           (map (lambda (pair)
                                  (cons (car pair) (vector-ref (cdr pair) 0)))
                                (paal-initial-env))))
             (g (paal-make-globals
                  (append
                    `((pkaappi-make-globals       . ,pkaappi-make-globals)
                      (pkaappi-set-command-line!  . ,pkaappi-set-command-line!)
                      ; command-line HOST lambda closes over cmd-cell (safe across pipelines).
                      (command-line               . ,(lambda () (car cmd-cell)))
                      (%paal-cmd-cell             . ,cmd-cell)
                      ; Seeds for the blob's port parameters: the host port
                      ; objects, plain data both copies can hold.
                      (%paal-init-in              . ,(current-input-port))
                      (%paal-init-out             . ,(current-output-port))
                      (%paal-init-err             . ,(current-error-port))

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
                      ; call/cc and its long spelling are VM markers like
                      ; apply: capture and invoke both live in do-call!, the
                      ; only place the frame list and register file are
                      ; visible.  These replace the HOST call/cc that
                      ; %without-host-only strips from base-alist below.
                      (call/cc                    . ,%paal-callcc-marker)
                      (call-with-current-continuation . ,%paal-callcc-marker)
                      ; Target of the expander's `guard` desugaring.  Only a marker:
                      ; do-call! implements the operation, so whichever copy of the
                      ; VM is running supplies the catch and the closure callbacks
                      ; (see vm-bc.sld).
                      (%paal-guard-run            . ,%paal-guard-run-marker)
                      ; The two primitives whose procedure argument is called
                      ; *later*, from HOST code.  The markers shadow the raw
                      ; bindings base-alist carries from paal-initial-env;
                      ; do-call! wraps the paal closure in a HOST trampoline
                      ; and hands it to the raw primitive kept just below.
                      ; First-order fiber and ffi names (yield, channels,
                      ; ffi-fn, …) stay raw — plain data crosses unaided.
                      (spawn                      . ,%paal-spawn-marker)
                      (ffi-callback               . ,%paal-ffi-callback-marker)
                      (%paal-host-spawn           . ,spawn)
                      (%paal-host-ffi-callback    . ,ffi-callback)
                      ; kaappi's (disassemble proc) parity.  Prints to the
                      ; HOST error port, as kaappi prints to stderr: the
                      ; listing is a diagnostic, not program output, so a
                      ; paal-level port rebinding deliberately does not
                      ; capture it.  A closure is plain data here — a tagged
                      ; vector — so a HOST lambda can take it apart.
                      (disassemble
                        . ,(lambda (x)
                             (cond
                               ((closure? x)
                                (paal-disassemble (closure-function x)
                                                  (current-error-port)))
                               ((bytecode-function? x)
                                (paal-disassemble x (current-error-port)))
                               (else
                                (error "disassemble: expected a paal procedure"
                                       x)))))
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
                      ;; R7RS environment takes import specs, and they are
                      ;; honoured by filtration: the table is built full —
                      ;; the blob's plumbing has to run regardless — and then
                      ;; narrowed to what the specs grant, the same
                      ;; computation the import-scope check runs, packaged as
                      ;; a predicate.  %-prefixed plumbing always survives;
                      ;; eval'd code that reaches for an ungranted name gets
                      ;; an unbound global at run time, since a bare
                      ;; expression has no import to check against.  A spec
                      ;; rooted in a file-backed library yields #f — loading
                      ;; it here would splice into the caller — and the
                      ;; environment stays a full table, the old behaviour.
                      ;;
                      ;; %make-globals-table, not pkaappi-make-globals: this
                      ;; runs inside the caller's program, and the reset would
                      ;; take the caller's own macros with it.
                      (environment                . ,(lambda specs
                                                       (let ((g (%make-globals-table))
                                                             (grants? (paal-import-grant-predicate specs)))
                                                         (when grants?
                                                           (vector-set! g 0
                                                             (filter (lambda (e) (grants? (car e)))
                                                                     (vector-ref g 0))))
                                                         g)))
                      ;; (scheme r5rs).  Same honest limitation as
                      ;; `environment` -- paal has one flat table per program,
                      ;; so any spec yields a full one -- but the version
                      ;; argument is at least checked, since 5 is the only one
                      ;; R7RS defines.  %make-globals-table, not
                      ;; pkaappi-make-globals: these run inside the caller's
                      ;; program and the reset would take its macros with it.
                      (scheme-report-environment
                        . ,(lambda (v)
                             (if (eqv? v 5)
                                 (%make-globals-table)
                                 (error "scheme-report-environment: unsupported version" v))))
                      (null-environment
                        . ,(lambda (v)
                             (if (eqv? v 5)
                                 (%make-globals-table)
                                 (error "null-environment: unsupported version" v))))
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
             ; Iterative through chained promises, as R7RS 7.3's reference
             ; force is: forcing a promise whose thunk answers another
             ; promise forces that one too, so (delay (delay x)) forces to
             ; x.  kaappi behaves this way, and SRFI 41 leans on it -- its
             ; stream-lambda wraps a body that is itself a stream in one
             ; more delay.  Each link is still memoised individually.
             (define (force p)
               (if (not (promise? p))
                   p
                   (if (vector-ref p 1)
                       (force (vector-ref p 2))
                       (let ((r ((vector-ref p 2))))
                         (vector-set! p 1 #t)
                         (vector-set! p 2 r)
                         (force r)))))")
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
             ; One value is that value, not a one-element MVR.  R7RS 6.10: a
             ; call to values with a single argument is equivalent to the
             ; argument itself, and every context that is not
             ; call-with-values sees exactly that.  Tagging it made
             ; (+ (values 1) 2) a type error and (list (values 'a)) return the
             ; tag -- roughly a hundred assertions of the R7RS suite, mostly in
             ; numeric syntax, where the reader's own (values n) round trip
             ; goes through here.
             ; (values) still tags: (pair? '()) is #f, so zero values stays an
             ; MVR and call-with-values still hands the consumer nothing.
             (define (values . vals)
               (if (and (pair? vals) (null? (cdr vals)))
                   (car vals)
                   (cons %paal-mvr-tag vals)))
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
             ; A paal closure is a tagged vector, so the HOST procedure? says
             ; #f for every procedure a paal program defines -- and vector?
             ; says #t.  Every predicate dispatch on procedures was wrong.
             ;
             ; The tag is the interned symbol from frame.sld, so it is eq?
             ; across both live copies.  Safe to override because do-call! and
             ; paal-call-value both test closure? *before* procedure?, so a
             ; closure never reaches the procedure? arm of either.
             ;
             ; vector? is deliberately NOT given the same treatment.  It is
             ; load-bearing for closure?, bytecode-function?, promise?,
             ; paal-vm-escape? and the wind-frame dispatch, and under
             ; self-hosting the paal-compiled frame.sld resolves it out of the
             ; *user program's* table -- so overriding it there makes closure?
             ; return #f for every closure, and every call reports that its
             ; callee is not callable.  The leak is documented in
             ; docs/architecture.md.
             ;
             ; NB this blob is a Scheme string literal: a double quote anywhere
             ; in it, comments included, ends the string and silently wrecks the
             ; rest of the library.
             ;
             ; The VM markers are what apply, call/cc, spawn and ffi-callback
             ; resolve to in this table, and each behaves as a procedure when
             ; called -- do-call! has an arm per marker -- so procedure? must
             ; say so.  The %paal-vm- namespace is do-call!'s own; a user
             ; datum colliding with it is already inside paal's plumbing.
             (define (%paal-vm-marker? x)
               (if (eq? x '%paal-vm-apply)
                   #t
                   (if (eq? x '%paal-vm-call/cc)
                       #t
                       (if (eq? x '%paal-vm-guard-run)
                           #t
                           (if (eq? x '%paal-vm-spawn)
                               #t
                               (eq? x '%paal-vm-ffi-callback))))))
             (define (procedure? x)
               (if (%paal-host-procedure? x)
                   #t
                   (if (vector? x)
                       (if (= (vector-length x) 3)
                           (eq? (vector-ref x 0) '%paal-closure)
                           ; A continuation is a 7-slot tagged vector from
                           ; frame.sld, and R7RS calls it a procedure --
                           ; (call-with-current-continuation procedure?) is
                           ; a suite assertion.
                           (if (= (vector-length x) 7)
                               (eq? (vector-ref x 0) '%paal-continuation)
                               #f))
                       (if (symbol? x)
                           (%paal-vm-marker? x)
                           #f))))
             ; map/for-each take any number of lists and stop at the shortest,
             ; per R7RS.  They used to accept two and silently ignore the rest,
             ; so (map + '(1 2) '(3 4) '(5 6)) answered (4 6).
             ;
             ; The one-list arm stays inlined rather than delegating to the
             ; n-ary path: map is on paal's own hot path when self-hosting --
             ; the expander and emitter call it constantly -- and that case must
             ; not pay an apply.  apply here is the VM marker, spread by
             ; do-call! with no arity ceiling, which is what it exists for.
             (define (%paal-any-null? ls)
               (if (null? ls) #f (if (null? (car ls)) #t (%paal-any-null? (cdr ls)))))
             (define (%paal-cars ls)
               (if (null? ls) '() (cons (car (car ls)) (%paal-cars (cdr ls)))))
             (define (%paal-cdrs ls)
               (if (null? ls) '() (cons (cdr (car ls)) (%paal-cdrs (cdr ls)))))
             (define (map f lst . rest)
               (if (null? rest)
                   (if (null? lst) '() (cons (f (car lst)) (map f (cdr lst))))
                   (%paal-map-n f (cons lst rest))))
             (define (%paal-map-n f ls)
               (if (%paal-any-null? ls)
                   '()
                   (cons (apply f (%paal-cars ls)) (%paal-map-n f (%paal-cdrs ls)))))
             (define (for-each f lst . rest)
               (if (null? rest)
                   (if (null? lst)
                       (if #f #f)
                       (begin (f (car lst)) (for-each f (cdr lst))))
                   (%paal-for-each-n f (cons lst rest))))
             (define (%paal-for-each-n f ls)
               (if (%paal-any-null? ls)
                   (if #f #f)
                   (begin (apply f (%paal-cars ls))
                          (%paal-for-each-n f (%paal-cdrs ls)))))
             (define (filter pred lst)
               (if (null? lst)
                   '()
                   (if (pred (car lst))
                       (cons (car lst) (filter pred (cdr lst)))
                       (filter pred (cdr lst)))))
             ; Same story as map: these took one sequence and dropped the rest,
             ; so (vector-map + #(1 2 3) #(4 5 6)) answered #(1 2 3).  R7RS
             ; stops at the shortest sequence.
             (define (%paal-min-length vs)
               (if (null? (cdr vs))
                   (vector-length (car vs))
                   (let ((n (vector-length (car vs)))
                         (m (%paal-min-length (cdr vs))))
                     (if (< n m) n m))))
             (define (%paal-nths vs i)
               (if (null? vs) '() (cons (vector-ref (car vs) i) (%paal-nths (cdr vs) i))))
             (define (vector-map f v . rest)
               (if (null? rest)
                   (let* ((n (vector-length v))
                          (result (make-vector n)))
                     (let loop ((i 0))
                       (if (= i n)
                           result
                           (begin
                             (vector-set! result i (f (vector-ref v i)))
                             (loop (+ i 1))))))
                   (let* ((vs (cons v rest))
                          (n (%paal-min-length vs))
                          (result (make-vector n)))
                     (let loop ((i 0))
                       (if (= i n)
                           result
                           (begin
                             (vector-set! result i (apply f (%paal-nths vs i)))
                             (loop (+ i 1))))))))
             (define (vector-for-each f v . rest)
               (if (null? rest)
                   (let ((n (vector-length v)))
                     (let loop ((i 0))
                       (if (< i n)
                           (begin (f (vector-ref v i)) (loop (+ i 1)))
                           (if #f #f))))
                   (let* ((vs (cons v rest))
                          (n (%paal-min-length vs)))
                     (let loop ((i 0))
                       (if (< i n)
                           (begin (apply f (%paal-nths vs i)) (loop (+ i 1)))
                           (if #f #f))))))
             ; The string forms go through map, so they became n-ary with it;
             ; the one-string path still avoids apply.
             (define (%paal-string-lists ss)
               (if (null? ss) '() (cons (string->list (car ss))
                                        (%paal-string-lists (cdr ss)))))
             (define (string-map f s . rest)
               (if (null? rest)
                   (list->string (map f (string->list s)))
                   (list->string
                     (%paal-map-n f (%paal-string-lists (cons s rest))))))
             (define (string-for-each f s . rest)
               (if (null? rest)
                   (for-each f (string->list s))
                   (%paal-for-each-n f (%paal-string-lists (cons s rest)))))")
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
             ; (p v) sets the value through the converter -- the SRFI 39
             ; convention R7RS dropped but kaappi keeps, so paal keeps it too.
             (define (make-parameter init . rest)
               (let* ((conv (if (null? rest) (lambda (x) x) (car rest)))
                      (cell (vector (conv init) conv)))
                 (lambda args
                   (if (null? args)
                       (vector-ref cell 0)
                       (if (eq? (car args) %paal-param-key)
                           cell
                           (vector-set! cell 0 (conv (car args))))))))
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

        ; Port parameters and the I/O wrappers that consult them.  The three
        ; current-port names become paal parameters — the tree-walking path
        ; made the same move in paal-initial-env, and for the same reason: a
        ; HOST parameter answers %paal-param-key with nonsense, so paal's
        ; parameterize could not rebind the ports at all.  Each wrapper
        ; captures the raw procedure out of the table *before* overriding the
        ; name — a blob define reads the table at that moment — and always
        ; hands it an explicit port, so the raw layer's own defaulting never
        ; runs.  Runs after the parameterize blob: make-parameter and
        ; parameterize must exist.
        (paal-run-bc
          (pkaappi-compile
            "(define %paal-raw-display display)
             (define %paal-raw-write write)
             (define %paal-raw-write-shared write-shared)
             (define %paal-raw-write-simple write-simple)
             (define %paal-raw-newline newline)
             (define %paal-raw-write-char write-char)
             (define %paal-raw-write-string write-string)
             (define %paal-raw-write-u8 write-u8)
             (define %paal-raw-read read)
             (define %paal-raw-read-char read-char)
             (define %paal-raw-peek-char peek-char)
             (define %paal-raw-read-line read-line)
             (define %paal-raw-read-string read-string)
             (define %paal-raw-read-u8 read-u8)
             (define %paal-raw-peek-u8 peek-u8)
             (define %paal-raw-char-ready? char-ready?)
             (define %paal-raw-u8-ready? u8-ready?)
             (define %paal-raw-flush flush-output-port)
             (define current-input-port  (make-parameter %paal-init-in))
             (define current-output-port (make-parameter %paal-init-out))
             (define current-error-port  (make-parameter %paal-init-err))
             (define (display x . p)
               (%paal-raw-display x (if (null? p) (current-output-port) (car p))))
             (define (write x . p)
               (%paal-raw-write x (if (null? p) (current-output-port) (car p))))
             (define (write-shared x . p)
               (%paal-raw-write-shared
                 x (if (null? p) (current-output-port) (car p))))
             (define (write-simple x . p)
               (%paal-raw-write-simple
                 x (if (null? p) (current-output-port) (car p))))
             (define (newline . p)
               (%paal-raw-newline (if (null? p) (current-output-port) (car p))))
             (define (write-char c . p)
               (%paal-raw-write-char
                 c (if (null? p) (current-output-port) (car p))))
             (define (write-string s . rest)
               (if (null? rest)
                   (%paal-raw-write-string s (current-output-port))
                   (apply %paal-raw-write-string s rest)))
             (define (write-u8 b . p)
               (%paal-raw-write-u8 b (if (null? p) (current-output-port) (car p))))
             (define (read . p)
               (%paal-raw-read (if (null? p) (current-input-port) (car p))))
             (define (read-char . p)
               (%paal-raw-read-char (if (null? p) (current-input-port) (car p))))
             (define (peek-char . p)
               (%paal-raw-peek-char (if (null? p) (current-input-port) (car p))))
             (define (read-line . p)
               (%paal-raw-read-line (if (null? p) (current-input-port) (car p))))
             (define (read-string k . p)
               (%paal-raw-read-string
                 k (if (null? p) (current-input-port) (car p))))
             (define (read-u8 . p)
               (%paal-raw-read-u8 (if (null? p) (current-input-port) (car p))))
             (define (peek-u8 . p)
               (%paal-raw-peek-u8 (if (null? p) (current-input-port) (car p))))
             (define (char-ready? . p)
               (%paal-raw-char-ready?
                 (if (null? p) (current-input-port) (car p))))
             (define (u8-ready? . p)
               (%paal-raw-u8-ready? (if (null? p) (current-input-port) (car p))))
             (define (flush-output-port . p)
               (%paal-raw-flush (if (null? p) (current-output-port) (car p))))
             ; Paal-side, so the rebinding is this table's parameters, not
             ; the host dynamic state nothing here reads any more.
             (define (with-input-from-file path thunk)
               (let ((port (open-input-file path)))
                 (let ((r (parameterize ((current-input-port port)) (thunk))))
                   (close-input-port port)
                   r)))
             (define (with-output-to-file path thunk)
               (let ((port (open-output-file path)))
                 (let ((r (parameterize ((current-output-port port)) (thunk))))
                   (close-output-port port)
                   r)))")
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

    ;; --- Bytecode cache for user programs ---
    ;;
    ;; Opt-in, via `paal --cache file.scm`.  Off by default because the cache
    ;; file lands beside the source: R7RS has no way to create a directory, so
    ;; there is nowhere else to put it, and writing into a user's tree without
    ;; being asked is not something a run of their program should do.
    ;;
    ;; The hash goes in the *name*, so a hit is an existence check and a source
    ;; edit simply misses rather than needing the stale entry detected.  Old
    ;; entries accumulate; `paal --cache` never deletes, since it cannot tell
    ;; its own leavings from a .pbc the user compiled on purpose.

    (define (%paal-source-hash text)
      ;; djb2 over the characters, reduced mod a prime that fits a fixnum.
      (let loop ((i 0) (h 5381))
        (if (= i (string-length text))
            h
            (loop (+ i 1)
                  (modulo (+ (* h 33) (char->integer (string-ref text i)))
                          1000000007)))))

    ;; Exported: paal never deletes cache entries -- it cannot tell its own
    ;; leavings from a .pbc the user compiled on purpose -- so anything that
    ;; wants to clean up needs to be able to name them.
    (define (pkaappi-cache-path path)
      (%paal-cache-path path (%paal-read-whole-file path)))

    (define (%paal-cache-path path text)
      (string-append path "." (number->string (%paal-source-hash text)) ".pbc"))

    ;; Returns the program's value.  A cache miss compiles, writes, and runs;
    ;; a hit skips the reader, expander, analyzer and emitter entirely.
    (define (pkaappi-run-file-cached path . opts)
      (let* ((text  (%paal-read-whole-file path))
             (cache (%paal-cache-path path text))
             (args  (if (null? opts) '() (car opts))))
        (if (file-exists? cache)
            (paal-run-bc (paal-read-bc-file cache) (pkaappi-make-globals args))
            (let ((fn (pkaappi-compile text)))
              ;; Written before running, so a program that fails partway still
              ;; leaves a usable cache entry -- compilation is what succeeded.
              (paal-write-bc-file fn cache)
              (paal-run-bc fn (pkaappi-make-globals args))))))

    (define (%paal-read-whole-file path)
      (let ((port (open-input-file path)))
        (let loop ((acc ""))
          (let ((chunk (read-string 4096 port)))
            (if (eof-object? chunk)
                (begin (close-input-port port) acc)
                (loop (string-append acc chunk)))))))

    ;; --- cache inspection: paal cache status|clear ---
    ;;
    ;; The user-program entries are the <file>.<hash>.pbc files
    ;; pkaappi-run-file-cached writes beside sources.  The hash is in the
    ;; name, so a source edit strands the old entry, and the note above says
    ;; a *run* can never clean them up — it cannot tell its own leavings from
    ;; a .pbc the user compiled on purpose.  An explicit `cache` subcommand
    ;; can: the naming scheme (base, a dot, decimal digits, ".pbc") is this
    ;; file's own, so anything matching it beside the source is paal's.
    ;; Finding them takes the one operation R7RS lacks, directory listing,
    ;; which the host's (srfi 170) supplies; this library is HOST-side API
    ;; and is never compiled by paal itself, so the import is safe.

    ;; The directory and basename halves of a path.
    ;; "a/b/c.scm" -> ("a/b" . "c.scm"); a bare name lists ".".
    (define (%paal-path-split path)
      (let loop ((i (- (string-length path) 1)))
        (cond ((< i 0) (cons "." path))
              ((char=? (string-ref path i) #\/)
               (cons (if (= i 0) "/" (substring path 0 i))
                     (substring path (+ i 1) (string-length path))))
              (else (loop (- i 1))))))

    (define (%paal-all-digits? s start end)
      (and (> end start)
           (let loop ((i start))
             (or (= i end)
                 (and (char<=? #\0 (string-ref s i))
                      (char<=? (string-ref s i) #\9)
                      (loop (+ i 1)))))))

    ;; #t exactly for <base>.<digits>.pbc — the shape %paal-cache-path writes.
    (define (%paal-cache-entry-name? name base)
      (let ((nl (string-length name)) (bl (string-length base)))
        (and (> nl (+ bl 5))
             (string=? (substring name 0 bl) base)
             (char=? (string-ref name bl) #\.)
             (string=? (substring name (- nl 4) nl) ".pbc")
             (%paal-all-digits? name (+ bl 1) (- nl 4)))))

    ;; Every cache entry beside `path`, as (entry-path . current?).  current?
    ;; marks the entry the present source text hits; the rest are stale.  A
    ;; missing source has no current hash, so everything found reads stale.
    ;; Compared by *name*: the current path carries the caller's spelling of
    ;; the directory ("./f.scm" vs "f.scm"), the listing does not.
    (define (pkaappi-cache-entries path)
      (let* ((split   (%paal-path-split path))
             (dir     (car split))
             (base    (cdr split))
             (current (and (file-exists? path)
                           (cdr (%paal-path-split (pkaappi-cache-path path)))))
             (names   (guard (e (#t '())) (directory-files dir))))
        (map (lambda (name)
               (cons (if (string=? dir ".")
                         name
                         (string-append dir "/" name))
                     (and current (string=? name current) #t)))
             (filter (lambda (n) (%paal-cache-entry-name? n base)) names))))

    ;; Delete every entry for `path`, current included — a clear that kept
    ;; the current entry would not be a clear.  Answers the deleted paths so
    ;; the caller can say what happened.
    (define (pkaappi-cache-clear! path)
      (let ((entries (map car (pkaappi-cache-entries path))))
        (for-each delete-file entries)
        entries))

    ;; The pipeline cache under cache/, one (path . exists?) per stage file.
    ;; make pbc-pipeline is what builds it; this is the status a user can get
    ;; without reading the Makefile.
    (define (paal-pipeline-cache-status)
      (map (lambda (f) (cons f (file-exists? f)))
           (append %paal-cache-files (list %paal-serializer-cache))))

    ;; --- capability report: paal features ---
    ;;
    ;; The facts as data, apart from the two renderings, so the suite can
    ;; assert on the report without parsing either.

    (define paal-version "0.1.0")

    (define (paal-features)
      `((name . "paal")
        (version . ,paal-version)
        (features . ,(paal-feature-list))
        (embedded-libraries . ,(paal-embedded-names))
        (pipeline-cache . ,(paal-pipeline-cache-status))))

    (define (%paal-count-true alist)
      (length (filter cdr alist)))

    (define (paal-features-text)
      (let* ((report  (paal-features))
             (cache   (cdr (assq 'pipeline-cache report)))
             (present (%paal-count-true cache))
             (out     (open-output-string)))
        (display "paal " out)
        (display (cdr (assq 'version report)) out)
        (newline out)
        (display "\nFeatures (cond-expand / (features) identifiers):\n " out)
        (for-each (lambda (f) (display " " out) (display f out))
                  (cdr (assq 'features report)))
        (newline out)
        (display "\nEmbedded libraries (" out)
        (display (length (cdr (assq 'embedded-libraries report))) out)
        (display "):\n " out)
        (for-each (lambda (n) (display " " out) (write n out))
                  (cdr (assq 'embedded-libraries report)))
        (newline out)
        (display "\nPipeline cache: " out)
        (display present out)
        (display "/" out)
        (display (length cache) out)
        (display (if (= present (length cache))
                     " (complete; self-hosted run and compile use it)"
                     " (incomplete; runs fall back to .sld sources -- run `make pbc-pipeline`)")
                 out)
        (newline out)
        (get-output-string out)))

    ;; JSON by hand: the report's strings are paths and identifiers, but the
    ;; escaper is complete anyway — a path with a quote in it should bend the
    ;; output, not break it.
    (define (%paal-json-string s)
      (let ((out (open-output-string)))
        (display "\"" out)
        (string-for-each
          (lambda (c)
            (cond ((char=? c #\")       (display "\\\"" out))
                  ((char=? c #\\)       (display "\\\\" out))
                  ((char=? c #\newline) (display "\\n" out))
                  ((char=? c #\tab)     (display "\\t" out))
                  ((char=? c #\return)  (display "\\r" out))
                  (else (write-char c out))))
          s)
        (display "\"" out)
        (get-output-string out)))

    ;; Symbols and library names render as their written text.
    (define (%paal-json-text x)
      (if (string? x)
          x
          (let ((out (open-output-string)))
            (write x out)
            (get-output-string out))))

    (define (%paal-json-string-array items)
      (let ((out (open-output-string)))
        (display "[" out)
        (let loop ((is items) (first #t))
          (unless (null? is)
            (unless first (display ", " out))
            (display (%paal-json-string (%paal-json-text (car is))) out)
            (loop (cdr is) #f)))
        (display "]" out)
        (get-output-string out)))

    (define (paal-features-json)
      (let* ((report  (paal-features))
             (cache   (cdr (assq 'pipeline-cache report)))
             (present (%paal-count-true cache))
             (out     (open-output-string)))
        (display "{\n" out)
        (display "  \"name\": \"paal\",\n" out)
        (display "  \"version\": " out)
        (display (%paal-json-string (cdr (assq 'version report))) out)
        (display ",\n  \"features\": " out)
        (display (%paal-json-string-array (cdr (assq 'features report))) out)
        (display ",\n  \"embedded_libraries\": " out)
        (display (%paal-json-string-array
                   (cdr (assq 'embedded-libraries report))) out)
        (display ",\n  \"pipeline_cache\": {\n    \"complete\": " out)
        (display (if (= present (length cache)) "true" "false") out)
        (display ",\n    \"files\": {\n" out)
        (let loop ((cs cache))
          (unless (null? cs)
            (display "      " out)
            (display (%paal-json-string (car (car cs))) out)
            (display ": " out)
            (display (if (cdr (car cs)) "true" "false") out)
            (display (if (null? (cdr cs)) "\n" ",\n") out)
            (loop (cdr cs))))
        (display "    }\n  }\n}\n" out)
        (get-output-string out)))

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
                %paal-cache-files)
      (%finish-pipeline-load! g))

    ; The .sld route, for a checkout with no cache built yet.
    (define (pkaappi-load-source-pipeline g)
      (for-each (lambda (p) (pkaappi-load-file p g)) %paal-lib-files)
      (%finish-pipeline-load! g))

    ;; Everything a freshly loaded pipeline needs that the pipeline cannot
    ;; supply for itself.  Called from both routes, so no entry point can get
    ;; one and not the other — three of the six load sites used to be missing
    ;; the lib-path replay.
    (define (%finish-pipeline-load! g)
      ;; The loaded expander resolves every non-builtin import through
      ;; paal-embedded-source, which lives in (kaappi paal embedded) — a
      ;; library that is not part of the pipeline, so it is in neither the
      ;; cache nor %paal-lib-files.  Without this, `paal file.scm` in a
      ;; checkout with a built cache failed on *any* user-library import,
      ;; (srfi 1) included, with `unbound variable paal-embedded-source`.
      ;;
      ;; Installing the HOST procedure is enough, and is what the boundary
      ;; allows: it takes a library name and returns source text, both plain
      ;; data, exactly like the HOST `command-line` already in the table.
      ;; Loading the library itself would push 1300 lines of embedded SRFI
      ;; source through the pipeline on every run to reach one procedure.
      (%globals-put! g 'paal-embedded-source paal-embedded-source)
      ;; --lib-path was consumed by the HOST expander; the loaded copy has its
      ;; own %paal-lib-paths and has never heard of it.
      (%propagate-lib-paths! g))

    ;; Names paal-initial-env binds whose HOST values cannot work on the
    ;; bytecode path.
    ;;
    ;; Only `call/cc` and its long spelling, and only because they are HOST
    ;; procedures taking a procedure argument: a paal closure there is a tagged
    ;; vector the host cannot enter, so calling one raised
    ;; `type error in 'call/cc': expected procedure, got #<vector>`.
    ;;
    ;; The names are no longer unbound, though: %make-globals-table strips the
    ;; HOST procedures here and binds both spellings to %paal-callcc-marker,
    ;; the VM's own capture/invoke in do-call! (see vm-bc.sld).  The VM now
    ;; knows about continuations — the re-entrant design an earlier note here
    ;; called out of scope — which is also what dissolved the reason the
    ;; escape-only replacement was reverted: its escapes had to pass through
    ;; %paal-guard-catch, which could not tell them from its own.  Capture and
    ;; invoke living in the dispatch loop never meet a guard's clauses at all;
    ;; the one escape the design still uses, %paal-vm-cont-invoke, is
    ;; recognized and passed through by run-guard! itself.  The tree-walking
    ;; path keeps the HOST pair, which genuinely work there — closures on that
    ;; path are HOST procedures.
    (define %paal-host-only-names
      '(call/cc call-with-current-continuation))

    (define (%without-host-only alist)
      (let loop ((as alist) (acc '()))
        (cond ((null? as) (reverse acc))
              ((memq (car (car as)) %paal-host-only-names) (loop (cdr as) acc))
              (else (loop (cdr as) (cons (car as) acc))))))

    ;; Add a HOST value to an already-built globals table.  pkaappi-make-globals
    ;; cannot do this: the pipeline is loaded into g after it returns.
    (define (%globals-put! g name value)
      (let ((hit (assq name (vector-ref g 0))))
        (if hit
            (set-cdr! hit value)
            (vector-set! g 0 (cons (cons name value) (vector-ref g 0))))))

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
             (pkaappi-load-source-pipeline g)
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
           (pkaappi-load-source-pipeline g)
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
    ;; The loaded pipeline is a second copy of the expander with its own
    ;; %paal-lib-paths, so --lib-path has to be replayed into it.  Without this
    ;; a self-hosted import searched the default path alone: bundled SRFIs
    ;; resolved, because "lib" is a default, and every user library did not.
    (define (%propagate-lib-paths! g)
      (for-each
        (lambda (dir)
          (pkaappi-run-string-in g
            (string-append "(paal-lib-path-add! \"" dir "\")")))
        (paal-lib-paths-list)))

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
                                      define-library define-syntax import)))")))
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
           (pkaappi-load-source-pipeline g)
           (%run-repl g)))
        ;; Neither the cache nor paal's sources are on disk -- which is the
        ;; normal case for a bundled binary run outside the repo.  The HOST
        ;; pipeline is compiled into the binary regardless, so a REPL is still
        ;; possible; it just is not the self-hosted one.  Erroring here left
        ;; the standalone binary with no REPL at all.
        (else (%run-host-repl))))

    ;; A REPL over the HOST pipeline.  Definitions accumulate in one globals
    ;; table, so `(define x 1)` is visible to the next expression, and each
    ;; input is guarded so a raise ends that expression rather than the
    ;; session.
    ;; Whether a REPL should echo the result.  A definition's value in paal is
    ;; the thing defined, not the unspecified value, so a REPL that suppresses
    ;; only the unspecified value answers `9` to `(define q 9)`.  Both REPLs
    ;; decide from the form; this is the same list %run-repl tests inside its
    ;; own globals, which is where the fallback had drifted from it.
    (define (%definition-form? form)
      (and (pair? form)
           (memq (car form)
                 '(define define-values define-record-type define-library
                   define-syntax import))
           #t))

    (define (%run-host-repl)
      (let ((g (pkaappi-make-globals)))
        (let loop ()
          (display "paal> ")
          (flush-output-port (current-output-port))
          (let ((form (paal-read (current-input-port))))
            (if (eof-object? form)
                (newline)
                (begin
                  (guard (e (#t (display "error: ")
                                (%display-condition e (current-output-port))
                                (newline)))
                    (let ((result (paal-run-bc (pkaappi-compile-forms (list form)) g)))
                      (unless (or (%definition-form? form)
                                  (eq? result (if #f #f)))
                        (write result)
                        (newline))))
                  (loop)))))))))
