;;; pkaappi — Paal Kaappi command-line driver
;;;
;;; Bootstrap invocation:
;;;   kaappi --lib-path <lib> src/main.scm <command> [args]

(import (scheme base)
        (scheme write)
        (scheme process-context)
        (kaappi paal))

(define (usage)
  (display "Usage: pkaappi <command> [args]\n")
  (display "\nCommands:\n")
  (display "  run <file>     Run a Scheme file\n")
  (display "  eval <expr>    Evaluate an expression\n")
  (display "  version        Print version\n"))

(define (main args)
  (cond
    ((null? args) (usage))
    ((or (string=? (car args) "--help") (string=? (car args) "-h"))
     (usage))
    ((string=? (car args) "version")
     (display "pkaappi 0.1.0") (newline))
    ((string=? (car args) "run")
     (if (null? (cdr args))
         (begin (display "error: run: missing file\n") (exit 1))
         (pkaappi-run-bc-file (cadr args))))
    ((string=? (car args) "eval")
     (if (null? (cdr args))
         (begin (display "error: eval: missing expression\n") (exit 1))
         (let ((result (pkaappi-run-bc-string (cadr args))))
           (write result) (newline))))
    (else
     (display "error: unknown command: ") (display (car args)) (newline)
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
