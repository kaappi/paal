;;; paal — Paal Kaappi command-line driver
;;;
;;; Bootstrap invocation:
;;;   kaappi --lib-path <lib> src/main.scm [args...]

(import (scheme base)
        (scheme write)
        (scheme file)
        (scheme process-context)
        (kaappi paal))

(define (usage)
  (display "Paal Kaappi v0.1.0\n")
  (display "\nUsage: paal [file] [args...]\n")
  (display "       paal check <file>...\n")
  (display "       paal compile <file.scm> -o <output.pbc>\n")
  (display "       paal <subcommand> [args...]\n")
  (display "\nWith no arguments, starts an interactive REPL.\n")
  (display "\nSubcommands:\n")
  (display "  check <file>...         Compile without running; report errors\n")
  (display "  debug <file> [args...]  Run under the stepping debugger\n")
  (display "  fmt [--check] <file>... Reprint with canonical 2-space indentation\n")
  (display "  compile <f> -o <out>    Compile to .pbc bytecode\n")
  (display "  expand <file>           Print expanded forms\n")
  (display "  ir <file>               Print IR nodes\n")
  (display "  repl                    Start interactive REPL\n")
  (display "  eval <expr>             Evaluate an expression\n")
  (display "\nOptions:\n")
  (display "  --lib-path <dir>        Add a directory to the library search path\n")
  (display "  --cache                 Cache compiled bytecode beside the source\n")
  (display "  --profile               Count calls per procedure; report on exit\n")
  (display "  --coverage              Report which procedures were never called\n")
  (display "  -h, --help              Show this help\n")
  (display "  --version               Show version\n"))

;; Run a file, forwarding extra-args to (command-line) inside the user program.
(define (run-file path . extra-args)
  (let ((len (string-length path)))
    (if (and (>= len 4) (string=? (substring path (- len 4) len) ".pbc"))
        (pkaappi-run-pbc-file path)  ; .pbc: no command-line forwarding yet
        (cond
          ;; --profile runs on the HOST pipeline deliberately.  The
          ;; self-hosted path executes the user's program through the
          ;; paal-compiled copy of the VM, which has its own %profiling? flag
          ;; that setting this one does not reach -- the same two-copies
          ;; problem as %paal-lib-paths.  Profiling there also buries the
          ;; user's procedures under the pipeline's own map/filter traffic,
          ;; which is not what anyone asked for.
          ;; Both run on the HOST pipeline, for the reason given below.
          (%coverage (report-coverage! (pkaappi-run-bc-string-covered
                                         (read-source path))))
          (%profile (pkaappi-run-bc-file path))
          (%use-cache (pkaappi-run-file-cached path (cons path extra-args)))
          (else (apply pkaappi-self-run-file path extra-args))))))

;; --lib-path <dir> may appear any number of times, before the subcommand.
;; Directories are searched in the order given, after the default ".".
;; --cache turns on the opt-in bytecode cache; see pkaappi-run-file-cached.
(define %use-cache #f)

;; Drop one entry by identity, so the report can select repeatedly without
;; needing a total order on procedure names.
(define (%without lst entry)
  (let loop ((l lst) (acc '()))
    (cond ((null? l) (reverse acc))
          ((eq? (car l) entry) (loop (cdr l) acc))
          (else (loop (cdr l) (cons (car l) acc))))))

;; --profile counts calls per procedure and prints a report on exit.
(define %profile #f)
;; --coverage reports which of the program's procedures were ever called.
(define %coverage #f)

(define (strip-lib-paths args)
  (let loop ((as args))
    (if (and (pair? as) (string=? (car as) "--coverage"))
        (begin (set! %coverage #t) (loop (cdr as)))
    (if (and (pair? as) (string=? (car as) "--profile"))
        (begin (set! %profile #t) (paal-profile-start!) (loop (cdr as)))
    (if (and (pair? as) (string=? (car as) "--cache"))
        (begin (set! %use-cache #t) (loop (cdr as)))
    (if (and (pair? as) (string=? (car as) "--lib-path"))
        (if (null? (cdr as))
            (begin (display "error: --lib-path: missing directory\n") (exit 1))
            (begin (paal-lib-path-add! (cadr as)) (loop (cddr as))))
        as))))))

(define (read-source path)
  (let ((port (open-input-file path)))
    (let loop ((acc ""))
      (let ((chunk (read-string 4096 port)))
        (if (eof-object? chunk)
            (begin (close-input-port port) acc)
            (loop (string-append acc chunk)))))))

;; (covered total uncalled) from paal-coverage-report.
(define (report-coverage! result)
  (let ((covered (car result)) (total (cadr result)) (uncalled (caddr result)))
    (newline)
    (display "Coverage: ")
    (display covered) (display "/") (display total)
    (display " procedures called")
    (newline)
    (unless (null? uncalled)
      (display "  uncalled:")
      (for-each (lambda (n) (display " ") (display n)) uncalled)
      (newline))))

(define (main raw-args)
  (define args (strip-lib-paths raw-args))
  (cond
    ; No args → REPL (matches kaappi's behavior)
    ((null? args)
     (pkaappi-self-repl))
    ; Help
    ((or (string=? (car args) "--help") (string=? (car args) "-h"))
     (usage))
    ; Version
    ((or (string=? (car args) "--version") (string=? (car args) "version"))
     (display "paal 0.1.0") (newline))
    ; run <file> [args...] — explicit subcommand (kept for compatibility)
    ((string=? (car args) "run")
     (if (null? (cdr args))
         (begin (display "error: run: missing file\n") (exit 1))
         (apply run-file (cadr args) (cddr args))))
    ; repl — explicit subcommand
    ((string=? (car args) "repl")
     (pkaappi-self-repl))
    ; check <file>... — compile only, run nothing; exit 1 if anything failed
    ((string=? (car args) "check")
     (if (null? (cdr args))
         (begin (display "error: check: missing file\n") (exit 1))
         (if (pkaappi-check-files (cdr args)) (exit 0) (exit 1))))
    ; debug <file> [args...] — run under the stepping debugger
    ((string=? (car args) "debug")
     (if (null? (cdr args))
         (begin (display "error: debug: missing file\n") (exit 1))
         (apply pkaappi-debug-file (cadr args) (cddr args))))
    ; fmt [--check] <file>... — reprint with canonical indentation
    ((string=? (car args) "fmt")
     (let* ((check? (and (pair? (cdr args)) (string=? (cadr args) "--check")))
            (files  (if check? (cddr args) (cdr args))))
       (if (null? files)
           (begin (display "error: fmt: missing file\n") (exit 1))
           (let loop ((fs files) (dirty '()))
             (cond
               ((null? fs)
                (if (null? dirty)
                    (exit 0)
                    (begin
                      (for-each (lambda (f)
                                  (display "not formatted: " (current-error-port))
                                  (display f (current-error-port))
                                  (newline (current-error-port)))
                                (reverse dirty))
                      (exit 1))))
               (check?
                (loop (cdr fs)
                      (if (paal-format-check-file (car fs))
                          dirty
                          (cons (car fs) dirty))))
               (else
                (paal-format-file! (car fs))
                (loop (cdr fs) dirty)))))))
    ; compile <input> -o <output>
    ((string=? (car args) "compile")
     (cond
       ((or (null? (cdr args))
            (null? (cddr args))
            (not (string=? (caddr args) "-o"))
            (null? (cdddr args)))
        (display "error: compile: usage: paal compile <input.scm> -o <output.pbc>\n")
        (exit 1))
       (else
        (pkaappi-self-compile-to-file (cadr args) (cadddr args)))))
    ; eval <expr>
    ((string=? (car args) "eval")
     (if (null? (cdr args))
         (begin (display "error: eval: missing expression\n") (exit 1))
         (let ((result (pkaappi-run-bc-string (cadr args))))
           (write result) (newline))))
    ; expand <file> — print expanded forms (diagnostic)
    ((string=? (car args) "expand")
     (if (null? (cdr args))
         (begin (display "error: expand: missing file\n") (exit 1))
         (for-each (lambda (form) (write form) (newline))
                   (paal-expand-all (paal-read-file (cadr args))))))
    ; ir <file> — print IR nodes (diagnostic)
    ((string=? (car args) "ir")
     (if (null? (cdr args))
         (begin (display "error: ir: missing file\n") (exit 1))
         (for-each (lambda (node) (write node) (newline))
                   (paal-analyze-all
                     (paal-expand-all
                       (paal-read-file (cadr args)))))))
    ; Positional file [args...]: first arg doesn't start with '-'
    ; Remaining args are forwarded to (command-line) inside the user program.
    ((and (positive? (string-length (car args)))
          (not (char=? (string-ref (car args) 0) #\-)))
     (apply run-file (car args) (cdr args)))
    ; Unknown flag
    (else
     (display "error: unknown option: ") (display (car args)) (newline)
     (exit 1))))

; In bootstrap mode (kaappi src/main.scm args...), command-line includes this
; script's path as the first element — strip it.  In standalone mode
; (./paal args...) the binary name is already absent, so there is nothing to
; strip and the first argument is the user's.
;
; The test is for main.scm specifically, not for any .scm.  Matching any .scm
; meant a bundled binary stripped the user's own file: `paal p.scm` came
; through as ("p.scm"), lost it, and started the REPL instead — the standalone
; binary could not run a program at all.
(define (ends-with? s suffix)
  (let ((n (string-length s)) (m (string-length suffix)))
    (and (>= n m) (string=? (substring s (- n m) n) suffix))))

(define (prog-args)
  (let ((args (command-line)))
    (if (and (pair? args)
             (or (string=? (car args) "main.scm")
                 (ends-with? (car args) "/main.scm")))
        (cdr args)
        args)))

(main (prog-args))

;; Printed after the program has run.  Descending by count, so the procedures
;; worth looking at come first; ties keep whatever order the VM recorded.
(when %profile
  (let ((counts (paal-profile-report)))
    (newline)
    (display "Profile (calls):")
    (newline)
    (let loop ((remaining counts))
      (unless (null? remaining)
        (let pick ((rest (cdr remaining)) (best (car remaining)))
          (cond
            ((null? rest)
             (display "  ")
             (display (cdr best))
             (display "  ")
             (display (if (car best) (car best) "<anonymous>"))
             (newline)
             (loop (%without remaining best)))
            ((> (cdr (car rest)) (cdr best)) (pick (cdr rest) (car rest)))
            (else (pick (cdr rest) best))))))))
