;;; (kaappi paal disassembler) — bytecode listings for humans
;;;
;;; Renders a <bytecode-function> as numbered instructions, one per line.
;;; Instructions are tagged lists already, so each line is the instruction
;;; written verbatim — the same shapes bytecode.sld's ISA header documents —
;;; with one rewrite: a (closure dst fn specs) embeds a whole function, which
;;; would print as pages of nested vectors, so the embedded function is
;;; replaced by a label (fn1, fn2, …) and listed under that label afterwards.
;;; Labels are assigned breadth-first in encounter order; the entry function
;;; is always fn0.
;;;
;;; Used by `paal dis <file>` and by the `disassemble` binding the bytecode
;;; runtime installs (see paal.sld).  Deliberately not a pipeline stage:
;;; nothing here is needed to compile or run code, so it stays outside the
;;; cached stages and a change to it invalidates nothing.

(define-library (kaappi paal disassembler)
  (import (scheme base)
          (scheme write)
          (kaappi paal bytecode))
  (export paal-disassemble)
  (begin

    (define (%pad4 n)
      (let ((s (number->string n)))
        (string-append (make-string (max 0 (- 4 (string-length s))) #\0) s)))

    (define (%header label fn port)
      (display "; " port)
      (display label port)
      (display ": " port)
      (display (let ((name (bytecode-function-name fn)))
                 (if name name "<lambda>"))
               port)
      (display "  arity " port)
      (display (bytecode-function-arity fn) port)
      (when (bytecode-function-variadic? fn) (display "+" port))
      (let ((ups (bytecode-function-upvalue-count fn)))
        (unless (zero? ups)
          (display "  upvalues " port)
          (display ups port)))
      (newline port))

    ;; One function's listing.  Answers the nested functions encountered, as
    ;; (label . fn) in instruction order, for the caller to list next.  The
    ;; label counter starts at `next` and every child claims one, so the
    ;; caller advances by how many came back.
    (define (%list-one label fn next port)
      (%header label fn port)
      (let ((code (bytecode-function-code fn)))
        (let loop ((i 0) (next next) (children '()))
          (if (= i (vector-length code))
              (reverse children)
              (let ((instr (vector-ref code i)))
                (display "  " port)
                (display (%pad4 i) port)
                (display "  " port)
                (if (and (pair? instr) (eq? (car instr) 'closure))
                    (let ((child (string->symbol
                                   (string-append
                                     "fn" (number->string next)))))
                      (write (list 'closure (cadr instr) child
                                   (cadddr instr))
                             port)
                      (newline port)
                      (loop (+ i 1) (+ next 1)
                            (cons (cons child (caddr instr)) children)))
                    (begin
                      (write instr port)
                      (newline port)
                      (loop (+ i 1) next children))))))))

    ;; Takes the function to list and an optional port (default: the current
    ;; output port).  `paal dis` hands it a compiled program; the runtime
    ;; `disassemble` binding unwraps a closure to its function first.
    (define (paal-disassemble fn . opt)
      (let ((port (if (null? opt) (current-output-port) (car opt))))
        (let loop ((queue (list (cons 'fn0 fn))) (next 1))
          (unless (null? queue)
            (let* ((children (%list-one (car (car queue)) (cdr (car queue))
                                        next port))
                   (rest     (append (cdr queue) children)))
              (unless (null? rest) (newline port))
              (loop rest (+ next (length children))))))))))
