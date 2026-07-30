;;; pkaappi — Paal Kaappi command-line driver
;;;
;;; Bootstrap invocation:
;;;   kaappi --lib-path <lib> src/main.scm [args...]

(import (scheme base)
        (scheme write)
        (scheme process-context)
        (kaappi paal))

(define (usage)
  (display "Paal Kaappi v0.1.0\n")
  (display "\nUsage: pkaappi [file] [args...]\n")
  (display "       pkaappi compile <file.scm> -o <output.pbc>\n")
  (display "       pkaappi <subcommand> [args...]\n")
  (display "\nWith no arguments, starts an interactive REPL.\n")
  (display "\nSubcommands:\n")
  (display "  compile <f> -o <out>    Compile to .pbc bytecode\n")
  (display "  expand <file>           Print expanded forms\n")
  (display "  ir <file>               Print IR nodes\n")
  (display "  repl                    Start interactive REPL\n")
  (display "  eval <expr>             Evaluate an expression\n")
  (display "\nOptions:\n")
  (display "  -h, --help              Show this help\n")
  (display "  --version               Show version\n"))

(define (run-file path)
  (let ((len (string-length path)))
    (if (and (>= len 4) (string=? (substring path (- len 4) len) ".pbc"))
        (pkaappi-run-pbc-file path)
        (pkaappi-self-run-file path))))

(define (main args)
  (cond
    ; No args → REPL (matches kaappi's behavior)
    ((null? args)
     (pkaappi-self-repl))
    ; Help
    ((or (string=? (car args) "--help") (string=? (car args) "-h"))
     (usage))
    ; Version
    ((or (string=? (car args) "--version") (string=? (car args) "version"))
     (display "pkaappi 0.1.0") (newline))
    ; run <file> — explicit subcommand (kept for compatibility)
    ((string=? (car args) "run")
     (if (null? (cdr args))
         (begin (display "error: run: missing file\n") (exit 1))
         (run-file (cadr args))))
    ; repl — explicit subcommand
    ((string=? (car args) "repl")
     (pkaappi-self-repl))
    ; compile <input> -o <output>
    ((string=? (car args) "compile")
     (cond
       ((or (null? (cdr args))
            (null? (cddr args))
            (not (string=? (caddr args) "-o"))
            (null? (cdddr args)))
        (display "error: compile: usage: pkaappi compile <input.scm> -o <output.pbc>\n")
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
    ; Positional file: first arg doesn't start with '-'
    ((and (positive? (string-length (car args)))
          (not (char=? (string-ref (car args) 0) #\-)))
     (run-file (car args)))
    ; Unknown flag
    (else
     (display "error: unknown option: ") (display (car args)) (newline)
     (exit 1))))

; In bootstrap mode (kaappi src/main.scm args...), command-line includes
; the script path as the first element — strip it.
; In standalone mode (./pkaappi args...), the binary name is already absent.
(define (prog-args)
  (let ((args (command-line)))
    (if (and (pair? args)
             (let* ((a (car args)) (n (string-length a)))
               (and (>= n 4) (string=? (substring a (- n 4) n) ".scm"))))
        (cdr args)
        args)))

(main (prog-args))
