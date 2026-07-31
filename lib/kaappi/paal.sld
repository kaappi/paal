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
    paal-expand paal-expand-all
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
    pkaappi-compile-to-file pkaappi-run-pbc-file)
  (begin

    ;; --- Tree-walking pipeline ---

    (define (pkaappi-run-string src)
      (paal-eval-program
        (paal-analyze-all
          (paal-expand-all
            (paal-read-string src)))))

    (define (pkaappi-run-file path)
      (paal-eval-program
        (paal-analyze-all
          (paal-expand-all
            (paal-read-file path)))))

    ;; --- Bytecode pipeline ---

    (define (pkaappi-compile-forms forms)
      (paal-emit-program (paal-analyze-all (paal-expand-all forms))))

    (define (pkaappi-compile src)
      (pkaappi-compile-forms (paal-read-string src)))

    (define (pkaappi-run-bc-string src)
      ;; Use pkaappi-make-globals so paal-compiled HOF (values, apply, map, etc.)
      ;; are available — HOST versions cannot call paal closures.
      (paal-run-bc (pkaappi-compile src) (pkaappi-make-globals)))

    (define (pkaappi-run-bc-file path)
      (paal-run-bc (pkaappi-compile-forms (paal-read-file path)) (pkaappi-make-globals)))

    ;; --- Multi-file sequential loading ---

    ;; Create a fresh globals table seeded with kaappi primitives.
    ;; The returned object can be passed to pkaappi-load-file repeatedly;
    ;; each call accumulates the loaded file's definitions in place.
    ;;
    ;; Optional: pass a list of strings as the first argument to pre-set
    ;; (command-line) for user programs.  Example: (pkaappi-make-globals '("f.scm" "a"))
    (define (pkaappi-make-globals . opts)
      (let* ((cmd-args  (if (null? opts) '() (car opts)))
             ; cmd-cell is a HOST mutable pair; (car cmd-cell) = current command-line list.
             ; command-line is a HOST lambda closing over cmd-cell — safe to call from
             ; any pipeline (HOST or self-hosted) without closure-tag mismatch.
             (cmd-cell    (list cmd-args))
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
                      ; raise wraps the value so any paal datum survives the trip
                      ; through the HOST condition system; paal-vm-condition unwraps.
                      (raise                      . ,paal-vm-raise-escape!)
                      ; No restart support yet: a handler can never resume, so
                      ; raise-continuable behaves exactly like raise.
                      (raise-continuable          . ,paal-vm-raise-escape!)
                      (error                      . ,(lambda (msg . irritants)
                                                       (paal-vm-raise-escape!
                                                         (make-host-error msg irritants))))
                      ; Target of the expander's `guard` desugaring.  Only a marker:
                      ; do-call! implements the operation, so whichever copy of the
                      ; VM is running supplies the catch and the closure callbacks
                      ; (see vm-bc.sld).
                      (%paal-guard-run            . ,%paal-guard-run-marker))
                    base-alist))))
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
        ; apply: limited to 16 args (uses list-ref for clarity); extend if needed.
        ; values/call-with-values: MVR-tagged encoding, up to 4 return values.
        ; map, for-each, filter: 1-or-2-list version covering paal's own usage.
        ; vector-map, vector-for-each, string-map, string-for-each: 1-vector/string.
        (paal-run-bc
          (pkaappi-compile
            "(define (apply f . args)
               (define (spread a)
                 (if (null? (cdr a)) (car a) (cons (car a) (spread (cdr a)))))
               (let ((flat (if (null? args) '() (spread args))))
                 (let ((n (length flat)))
                   (cond
                     ((= n 0) (f))
                     ((= n 1) (f (list-ref flat 0)))
                     ((= n 2) (f (list-ref flat 0) (list-ref flat 1)))
                     ((= n 3) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)))
                     ((= n 4) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)
                                  (list-ref flat 3)))
                     ((= n 5) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)
                                  (list-ref flat 3) (list-ref flat 4)))
                     ((= n 6) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)
                                  (list-ref flat 3) (list-ref flat 4) (list-ref flat 5)))
                     ((= n 7) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)
                                  (list-ref flat 3) (list-ref flat 4) (list-ref flat 5)
                                  (list-ref flat 6)))
                     ((= n 8) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)
                                  (list-ref flat 3) (list-ref flat 4) (list-ref flat 5)
                                  (list-ref flat 6) (list-ref flat 7)))
                     ((= n 9) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)
                                  (list-ref flat 3) (list-ref flat 4) (list-ref flat 5)
                                  (list-ref flat 6) (list-ref flat 7) (list-ref flat 8)))
                     ((= n 10) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)
                                   (list-ref flat 3) (list-ref flat 4) (list-ref flat 5)
                                   (list-ref flat 6) (list-ref flat 7) (list-ref flat 8)
                                   (list-ref flat 9)))
                     ((= n 11) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)
                                   (list-ref flat 3) (list-ref flat 4) (list-ref flat 5)
                                   (list-ref flat 6) (list-ref flat 7) (list-ref flat 8)
                                   (list-ref flat 9) (list-ref flat 10)))
                     ((= n 12) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)
                                   (list-ref flat 3) (list-ref flat 4) (list-ref flat 5)
                                   (list-ref flat 6) (list-ref flat 7) (list-ref flat 8)
                                   (list-ref flat 9) (list-ref flat 10) (list-ref flat 11)))
                     ((= n 13) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)
                                   (list-ref flat 3) (list-ref flat 4) (list-ref flat 5)
                                   (list-ref flat 6) (list-ref flat 7) (list-ref flat 8)
                                   (list-ref flat 9) (list-ref flat 10) (list-ref flat 11)
                                   (list-ref flat 12)))
                     ((= n 14) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)
                                   (list-ref flat 3) (list-ref flat 4) (list-ref flat 5)
                                   (list-ref flat 6) (list-ref flat 7) (list-ref flat 8)
                                   (list-ref flat 9) (list-ref flat 10) (list-ref flat 11)
                                   (list-ref flat 12) (list-ref flat 13)))
                     ((= n 15) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)
                                   (list-ref flat 3) (list-ref flat 4) (list-ref flat 5)
                                   (list-ref flat 6) (list-ref flat 7) (list-ref flat 8)
                                   (list-ref flat 9) (list-ref flat 10) (list-ref flat 11)
                                   (list-ref flat 12) (list-ref flat 13) (list-ref flat 14)))
                     ((= n 16) (f (list-ref flat 0) (list-ref flat 1) (list-ref flat 2)
                                   (list-ref flat 3) (list-ref flat 4) (list-ref flat 5)
                                   (list-ref flat 6) (list-ref flat 7) (list-ref flat 8)
                                   (list-ref flat 9) (list-ref flat 10) (list-ref flat 11)
                                   (list-ref flat 12) (list-ref flat 13) (list-ref flat 14)
                                   (list-ref flat 15)))
                     (else (error \"apply: too many arguments (max 16)\" n))))))
             (define %paal-mvr-tag (list 'paal-mvr))
             (define (values . vals) (cons %paal-mvr-tag vals))
             (define (call-with-values producer consumer)
               (let ((r (producer)))
                 (if (and (pair? r) (eq? (car r) %paal-mvr-tag))
                     (let ((v (cdr r)))
                       (let ((n (length v)))
                         (cond
                           ((= n 0) (consumer))
                           ((= n 1) (consumer (car v)))
                           ((= n 2) (consumer (car v) (cadr v)))
                           ((= n 3) (consumer (car v) (cadr v) (caddr v)))
                           ((= n 4) (consumer (car v) (cadr v) (caddr v) (cadddr v)))
                           (else (error \"call-with-values: too many values\" n)))))
                     (consumer r))))
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

    (define (pkaappi-run-pbc-file path)
      (let* ((fn      (paal-read-bc-file path))
             (globals (paal-make-globals
                        (map (lambda (pair)
                               (cons (car pair) (vector-ref (cdr pair) 0)))
                             (paal-initial-env)))))
        (paal-run-bc fn globals)))

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
        (display "pkaappi> ")
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
