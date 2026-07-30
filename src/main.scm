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
  (display "Commands:\n")
  (display "  run <file>     Compile and run a Scheme file\n")
  (display "  eval <expr>    Compile and evaluate an expression\n")
  (display "  version        Print version\n"))

(define (main args)
  (cond
    ((null? args) (usage))
    ((string=? (car args) "version")
     (display "pkaappi 0.1.0") (newline))
    ((string=? (car args) "run")
     (if (null? (cdr args))
         (begin (display "error: missing file\n") (exit 1))
         (pkaappi-run-file (cadr args))))
    ((string=? (car args) "eval")
     (if (null? (cdr args))
         (begin (display "error: missing expression\n") (exit 1))
         (let ((result (pkaappi-run-string (cadr args))))
           (write result) (newline))))
    (else
     (display "error: unknown command: ") (display (car args)) (newline)
     (exit 1))))

(main (command-line-arguments))
