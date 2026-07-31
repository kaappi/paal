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
      ; Use explicit open/close — call-with-port can't invoke paal closures
      ; as its thunk (kaappi's apply doesn't understand paal <closure> records).
      (let ((port (open-output-file path)))
        (paal-write-bc fn port)
        (close-output-port port)))

    ;; Read the whole file into a string up front.
    ;;
    ;; Deliberately not (read file-port): kaappi's file-port reader parses in
    ;; 4096-byte chunks and mis-handles a dotted pair straddling a boundary — a
    ;; truncated prefix reports UnexpectedChar rather than UnexpectedEof, which
    ;; the incremental loop treats as fatal instead of reading the next chunk
    ;; (kaappi/kaappi#1920).  .pbc files carry (#t . N) upvalue specs
    ;; throughout, so a large enough one eventually puts a dot on a boundary;
    ;; that is what made cache/paal-vm-bc.pbc unreadable and broke
    ;; `make pbc-pipeline`.  A string port hands the reader the whole datum at
    ;; once, so there is no boundary to straddle.
    ;;
    ;; Accumulating with string-append rather than collecting chunks and
    ;; calling (apply string-append chunks): paal's own apply caps at 16
    ;; arguments, and this file is compiled by paal for the self-hosted path,
    ;; where any .pbc over ~64 KB would exceed that.
    (define (read-file-as-string path)
      (let ((port (open-input-file path)))
        (let loop ((acc ""))
          (let ((chunk (read-string 4096 port)))
            (if (eof-object? chunk)
                (begin (close-input-port port) acc)
                (loop (string-append acc chunk)))))))

    (define (paal-read-bc-file path)
      (let* ((port   (open-input-string (read-file-as-string path)))
             (result (paal-read-bc port)))
        (close-input-port port)
        result))))
