;;; SRFI 48 — Intermediate Format Strings
;;;
;;; Adds ~d ~b ~o ~x (radix), ~c (character), ~y (pretty-print, here the same
;;; as write since paal has no pretty printer), ~? / ~k (recursive format),
;;; ~_ (space) and ~t (tab) to SRFI 28's set.  Column-aligned numeric
;;; directives (~w,dF) are not implemented.
;;;
;;; Like SRFI 28's, `format` here takes the format string first.  SRFI 48 also
;;; allows a leading port or #f/#t argument; that form is supported.
(define-library (srfi 48)
  (import (scheme base) (scheme write))
  (export format)
  (begin
    (define (%format-to out fmt args)
      (let loop ((i 0) (args args))
        (if (>= i (string-length fmt))
            #t
            (let ((c (string-ref fmt i)))
              (if (and (char=? c #\~) (< (+ i 1) (string-length fmt)))
                  (let ((d (char-downcase (string-ref fmt (+ i 1)))))
                    (cond
                      ((char=? d #\a) (display (car args) out) (loop (+ i 2) (cdr args)))
                      ((char=? d #\s) (write (car args) out) (loop (+ i 2) (cdr args)))
                      ((char=? d #\y) (write (car args) out) (loop (+ i 2) (cdr args)))
                      ((char=? d #\d) (display (number->string (car args) 10) out)
                                      (loop (+ i 2) (cdr args)))
                      ((char=? d #\b) (display (number->string (car args) 2) out)
                                      (loop (+ i 2) (cdr args)))
                      ((char=? d #\o) (display (number->string (car args) 8) out)
                                      (loop (+ i 2) (cdr args)))
                      ((char=? d #\x) (display (number->string (car args) 16) out)
                                      (loop (+ i 2) (cdr args)))
                      ((char=? d #\c) (write-char (car args) out) (loop (+ i 2) (cdr args)))
                      ((or (char=? d #\?) (char=? d #\k))
                       (%format-to out (car args) (cadr args))
                       (loop (+ i 2) (cddr args)))
                      ((char=? d #\%) (newline out) (loop (+ i 2) args))
                      ((char=? d #\n) (newline out) (loop (+ i 2) args))
                      ((char=? d #\_) (write-char #\space out) (loop (+ i 2) args))
                      ((char=? d #\t) (write-char #\tab out) (loop (+ i 2) args))
                      ((char=? d #\~) (write-char #\~ out) (loop (+ i 2) args))
                      (else (error "format: unknown directive" d))))
                  (begin (write-char c out) (loop (+ i 1) args)))))))

    ;; (format fmt arg ...) -> string
    ;; (format #f fmt arg ...) -> string
    ;; (format #t fmt arg ...) -> writes to current output, returns unspecified
    ;; (format port fmt arg ...) -> writes to port
    (define (format first . rest)
      (cond
        ((string? first)
         (let ((out (open-output-string)))
           (%format-to out first rest)
           (get-output-string out)))
        ((eq? first #f)
         (let ((out (open-output-string)))
           (%format-to out (car rest) (cdr rest))
           (get-output-string out)))
        ((eq? first #t)
         (%format-to (current-output-port) (car rest) (cdr rest))
         (if #f #f))
        (else
         (%format-to first (car rest) (cdr rest))
         (if #f #f))))))
