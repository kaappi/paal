;;; (kaappi paal serializer) — Bytecode serializer/deserializer
;;;
;;; Converts bytecode-function objects to/from a text S-expression format (.pbc).
;;;
;;; Format: (pbc <arity> <variadic?> <upvalue-count> <name> (<instr> ...))
;;;
;;; All instructions pass through as plain S-expressions except (closure dst fn specs),
;;; where fn is a bytecode-function record that must be serialized recursively.

(define-library (kaappi paal serializer)
  (import (scheme base)
          (scheme file)
          (scheme write)
          (scheme read)
          (kaappi paal bytecode))
  (export paal-write-bc paal-read-bc
          paal-write-bc-file paal-read-bc-file)
  (begin

    ;; ---------------------------------------------------------------
    ;; bytecode-function → S-expression
    ;; ---------------------------------------------------------------

    (define (bf->sexp fn)
      (list 'pbc
            (bytecode-function-arity fn)
            (bytecode-function-variadic? fn)
            (bytecode-function-upvalue-count fn)
            (bytecode-function-name fn)
            (let loop ((i 0) (acc '()))
              (let ((code (bytecode-function-code fn)))
                (if (= i (vector-length code))
                    (reverse acc)
                    (loop (+ i 1)
                          (cons (instr->sexp (vector-ref code i)) acc)))))))

    (define (instr->sexp instr)
      ; (closure dst fn specs) — fn is a bytecode-function record, must recurse.
      ; Everything else is already a plain S-expression.
      (if (and (pair? instr) (eq? (car instr) 'closure))
          (list 'closure (cadr instr) (bf->sexp (caddr instr)) (cadddr instr))
          instr))

    ;; ---------------------------------------------------------------
    ;; S-expression → bytecode-function
    ;; ---------------------------------------------------------------

    (define (sexp->bf sexp)
      ; sexp = (pbc arity variadic? upvalue-count name (instr ...))
      (make-bytecode-function
        (map sexp->instr (list-ref sexp 5))
        (list-ref sexp 1)
        (list-ref sexp 2)
        (list-ref sexp 3)
        (list-ref sexp 4)))

    (define (sexp->instr instr)
      (if (and (pair? instr) (eq? (car instr) 'closure))
          (list 'closure (cadr instr) (sexp->bf (caddr instr)) (cadddr instr))
          instr))

    ;; ---------------------------------------------------------------
    ;; Public API
    ;; ---------------------------------------------------------------

    (define (paal-write-bc fn port)
      (write (bf->sexp fn) port))

    (define (paal-read-bc port)
      (sexp->bf (read port)))

    (define (paal-write-bc-file fn path)
      (call-with-port (open-output-file path)
        (lambda (p) (paal-write-bc fn p))))

    (define (paal-read-bc-file path)
      (call-with-port (open-input-file path)
        (lambda (p) (paal-read-bc p))))))
